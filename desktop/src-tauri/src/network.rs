use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use mdns_sd::{ServiceDaemon, ServiceInfo};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

use crate::audio_engine::AudioConfig;
pub use crate::protocol::{
    sequence_diff, ControlMessage, FramedPacket, PacketHeader, PacketType, ProtocolError, StreamId,
    HEADER_SIZE, MAX_UDP_DATAGRAM_SIZE,
};

/// Default UDP port for bi-directional Opus audio & control packets.
pub const DEFAULT_UDP_PORT: u16 = 54321;

/// mDNS / Bonjour service type discovered by the iPhone client (`NWBrowser`).
pub const MDNS_SERVICE_TYPE: &str = "_audiosync._udp.local.";

#[derive(Debug, Error)]
pub enum NetworkError {
    #[error("Failed to bind UDP socket on port {port}: {source}")]
    BindError {
        port: u16,
        #[source]
        source: std::io::Error,
    },
    #[error("mDNS daemon error: {0}")]
    MdnsError(String),
    #[error("Protocol error: {0}")]
    Protocol(#[from] ProtocolError),
}

/// Snapshot of network connection status, peer metadata, and latency telemetry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkStatus {
    pub local_ip: String,
    pub udp_port: u16,
    pub mdns_active: bool,
    pub connected: bool,
    pub peer_address: Option<String>,
    pub peer_device_name: Option<String>,
    pub rtt_ms: f32,
    pub packets_sent: u64,
    pub packets_received: u64,
    pub packets_lost: u64,
}

/// Lock-free / shared network state updated by the UDP socket loop.
pub struct SharedNetworkState {
    pub local_ip: Mutex<String>,
    pub udp_port: AtomicU32,
    pub mdns_active: AtomicBool,
    pub connected: AtomicBool,
    pub peer_addr: Mutex<Option<SocketAddr>>,
    pub peer_device_name: Mutex<Option<String>>,
    pub last_peer_seen: Mutex<Option<Instant>>,
    pub rtt_micros: AtomicU32,
    pub packets_sent: AtomicU64,
    pub packets_received: AtomicU64,
    pub packets_lost: AtomicU64,
}

impl Default for SharedNetworkState {
    fn default() -> Self {
        Self {
            local_ip: Mutex::new(detect_local_ipv4().to_string()),
            udp_port: AtomicU32::new(DEFAULT_UDP_PORT as u32),
            mdns_active: AtomicBool::new(false),
            connected: AtomicBool::new(false),
            peer_addr: Mutex::new(None),
            peer_device_name: Mutex::new(None),
            last_peer_seen: Mutex::new(None),
            rtt_micros: AtomicU32::new(0),
            packets_sent: AtomicU64::new(0),
            packets_received: AtomicU64::new(0),
            packets_lost: AtomicU64::new(0),
        }
    }
}

impl SharedNetworkState {
    pub fn snapshot(&self) -> NetworkStatus {
        let rtt_ms = self.rtt_micros.load(Ordering::Relaxed) as f32 / 1000.0;
        NetworkStatus {
            local_ip: self.local_ip.lock().clone(),
            udp_port: self.udp_port.load(Ordering::Relaxed) as u16,
            mdns_active: self.mdns_active.load(Ordering::Relaxed),
            connected: self.connected.load(Ordering::Relaxed),
            peer_address: self.peer_addr.lock().map(|a| a.to_string()),
            peer_device_name: self.peer_device_name.lock().clone(),
            rtt_ms,
            packets_sent: self.packets_sent.load(Ordering::Relaxed),
            packets_received: self.packets_received.load(Ordering::Relaxed),
            packets_lost: self.packets_lost.load(Ordering::Relaxed),
        }
    }

    /// Manually sets the target iPhone IP & port (for manual IP fallback in the UI).
    pub fn set_manual_peer(&self, addr: SocketAddr) {
        *self.peer_addr.lock() = Some(addr);
        *self.last_peer_seen.lock() = Some(Instant::now());
        self.connected.store(true, Ordering::Relaxed);
    }
}

/// Detects the primary LAN IPv4 address of the Windows machine without sending any network traffic.
pub fn detect_local_ipv4() -> Ipv4Addr {
    if let Ok(sock) = StdUdpSocket::bind("0.0.0.0:0") {
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(local_addr) = sock.local_addr() {
                if let IpAddr::V4(ipv4) = local_addr.ip() {
                    if !ipv4.is_loopback() {
                        return ipv4;
                    }
                }
            }
        }
    }
    Ipv4Addr::new(127, 0, 0, 1)
}

/// Active mDNS responder guard that broadcasts `_audiosync._udp.local.` on the local Wi-Fi network.
pub struct MdnsResponder {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsResponder {
    pub fn start(port: u16, state: &SharedNetworkState) -> Result<Self, NetworkError> {
        let daemon =
            ServiceDaemon::new().map_err(|e| NetworkError::MdnsError(e.to_string()))?;

        let ipv4 = detect_local_ipv4();
        *state.local_ip.lock() = ipv4.to_string();

        let host_label = std::env::var("COMPUTERNAME")
            .unwrap_or_else(|_| "AudioSync-PC".to_string())
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect::<String>();

        let instance_name = if host_label.is_empty() {
            "AudioSync-PC".to_string()
        } else {
            format!("AudioSync-{host_label}")
        };
        let host_fqdn = format!("{instance_name}.local.");

        let properties = [
            ("version", "1.0"),
            ("codec", "opus"),
            ("sample_rate", "48000"),
            ("channels", "2"),
            ("duplex", "full"),
        ];

        let service_info = ServiceInfo::new(
            MDNS_SERVICE_TYPE,
            &instance_name,
            &host_fqdn,
            IpAddr::V4(ipv4),
            port,
            &properties[..],
        )
        .map_err(|e| NetworkError::MdnsError(e.to_string()))?;

        let fullname = service_info.get_fullname().to_string();
        daemon
            .register(service_info)
            .map_err(|e| NetworkError::MdnsError(e.to_string()))?;

        state.mdns_active.store(true, Ordering::Relaxed);
        log::info!(
            "mDNS responder broadcasting {} at {}:{}",
            fullname,
            ipv4,
            port
        );

        Ok(Self { daemon, fullname })
    }

    pub fn shutdown(self, state: &SharedNetworkState) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
        state.mdns_active.store(false, Ordering::Relaxed);
    }
}

/// Manages the non-blocking Tokio UDP socket loop and mDNS responder.
pub struct NetworkEngine {
    pub state: Arc<SharedNetworkState>,
    audio_config: Arc<Mutex<AudioConfig>>,
    running: Arc<AtomicBool>,
}

impl NetworkEngine {
    pub fn new(audio_config: Arc<Mutex<AudioConfig>>) -> Self {
        Self {
            state: Arc::new(SharedNetworkState::default()),
            audio_config,
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    /// Starts the mDNS responder and spawns the non-blocking bi-directional UDP streaming task.
    pub async fn start(
        &self,
        port: u16,
        mut outbound_opus_rx: mpsc::Receiver<Vec<u8>>,
        inbound_mic_tx: mpsc::Sender<FramedPacket>,
    ) -> Result<(), NetworkError> {
        if self.running.swap(true, Ordering::SeqCst) {
            return Ok(());
        }

        self.state.udp_port.store(port as u32, Ordering::Relaxed);

        let bind_addr = SocketAddr::from(([0, 0, 0, 0], port));
        let socket = UdpSocket::bind(bind_addr)
            .await
            .map_err(|source| NetworkError::BindError { port, source })?;

        let mdns = match MdnsResponder::start(port, &self.state) {
            Ok(responder) => Some(responder),
            Err(err) => {
                log::warn!("mDNS responder failed to start (manual IP still available): {err}");
                None
            }
        };

        let running = Arc::clone(&self.running);
        let state = Arc::clone(&self.state);
        let audio_config = Arc::clone(&self.audio_config);

        tokio::spawn(async move {
            let start_instant = Instant::now();
            let mut recv_buf = vec![0u8; MAX_UDP_DATAGRAM_SIZE];
            let mut send_buf = vec![0u8; MAX_UDP_DATAGRAM_SIZE];

            let mut outbound_seq: u16 = 0;
            let mut ping_seq: u16 = 0;
            let mut last_inbound_mic_seq: Option<u16> = None;

            let mut ping_interval = tokio::time::interval(Duration::from_secs(1));
            ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            while running.load(Ordering::Relaxed) {
                tokio::select! {
                    // 1. Non-blocking inbound UDP datagram handler
                    recv_res = socket.recv_from(&mut recv_buf) => {
                        match recv_res {
                            Ok((len, src_addr)) => {
                                if len < HEADER_SIZE {
                                    continue;
                                }
                                let Ok(packet) = FramedPacket::decode(&recv_buf[..len]) else {
                                    continue;
                                };

                                // Update active peer address & timestamp
                                *state.peer_addr.lock() = Some(src_addr);
                                *state.last_peer_seen.lock() = Some(Instant::now());
                                state.connected.store(true, Ordering::Relaxed);
                                state.packets_received.fetch_add(1, Ordering::Relaxed);

                                match packet.header.packet_type {
                                    PacketType::AudioOpus => {
                                        if packet.header.stream_id == StreamId::PhoneToPc {
                                            if let Some(prev_seq) = last_inbound_mic_seq {
                                                let diff = sequence_diff(packet.header.sequence_num, prev_seq);
                                                if diff > 1 {
                                                    state.packets_lost.fetch_add((diff - 1) as u64, Ordering::Relaxed);
                                                }
                                            }
                                            last_inbound_mic_seq = Some(packet.header.sequence_num);
                                            let _ = inbound_mic_tx.try_send(packet);
                                        }
                                    }
                                    PacketType::Ping => {
                                        // Echo Pong immediately with identical sequence_num & timestamp
                                        let pong = FramedPacket::pong(
                                            packet.header.sequence_num,
                                            packet.header.timestamp,
                                        );
                                        if let Ok(encoded_len) = pong.encode_into(&mut send_buf) {
                                            let _ = socket.send_to(&send_buf[..encoded_len], src_addr).await;
                                        }
                                    }
                                    PacketType::Pong => {
                                        let now_micros = (start_instant.elapsed().as_micros() & 0xFFFF_FFFF) as u32;
                                        let rtt_us = now_micros.wrapping_sub(packet.header.timestamp);
                                        state.rtt_micros.store(rtt_us, Ordering::Relaxed);
                                    }
                                    PacketType::Control => {
                                        if let Ok(ctrl_msg) = serde_json::from_slice::<ControlMessage>(&packet.payload) {
                                            handle_control_message(
                                                ctrl_msg,
                                                src_addr,
                                                &socket,
                                                &state,
                                                &audio_config,
                                                &start_instant,
                                                &mut send_buf,
                                            ).await;
                                        }
                                    }
                                }
                            }
                            Err(err) => {
                                log::debug!("UDP recv_from transient error: {err}");
                            }
                        }
                    }

                    // 2. Non-blocking outbound PC-to-iPhone Opus audio frame transmitter
                    Some(opus_payload) = outbound_opus_rx.recv() => {
                        let maybe_peer = *state.peer_addr.lock();
                        if let Some(peer_addr) = maybe_peer {
                            let ts_micros = (start_instant.elapsed().as_micros() & 0xFFFF_FFFF) as u32;
                            let pkt = FramedPacket::new(
                                PacketType::AudioOpus,
                                StreamId::PcToPhone,
                                outbound_seq,
                                ts_micros,
                                opus_payload,
                            );
                            outbound_seq = outbound_seq.wrapping_add(1);

                            if let Ok(encoded_len) = pkt.encode_into(&mut send_buf) {
                                if socket.send_to(&send_buf[..encoded_len], peer_addr).await.is_ok() {
                                    state.packets_sent.fetch_add(1, Ordering::Relaxed);
                                }
                            }
                        }
                    }

                    // 3. Periodic Ping latency probe & peer timeout watchdog
                    _ = ping_interval.tick() => {
                        let timed_out = {
                            let last_seen = *state.last_peer_seen.lock();
                            match last_seen {
                                Some(instant) => instant.elapsed() > Duration::from_secs(8),
                                None => false,
                            }
                        };

                        if timed_out {
                            state.connected.store(false, Ordering::Relaxed);
                        }

                        let maybe_peer = *state.peer_addr.lock();
                        if let Some(peer_addr) = maybe_peer {
                            if state.connected.load(Ordering::Relaxed) {
                                let ts_micros = (start_instant.elapsed().as_micros() & 0xFFFF_FFFF) as u32;
                                let ping = FramedPacket::ping(ping_seq, ts_micros);
                                ping_seq = ping_seq.wrapping_add(1);

                                if let Ok(encoded_len) = ping.encode_into(&mut send_buf) {
                                    let _ = socket.send_to(&send_buf[..encoded_len], peer_addr).await;
                                }
                            }
                        }
                    }
                }
            }

            if let Some(responder) = mdns {
                responder.shutdown(&state);
            }
        });

        Ok(())
    }
}

async fn handle_control_message(
    msg: ControlMessage,
    src_addr: SocketAddr,
    socket: &UdpSocket,
    state: &SharedNetworkState,
    audio_config: &Mutex<AudioConfig>,
    start_instant: &Instant,
    send_buf: &mut [u8],
) {
    match msg {
        ControlMessage::Handshake { device_name, .. } => {
            *state.peer_device_name.lock() = Some(device_name);
            let cfg = audio_config.lock().clone();
            let server_name =
                std::env::var("COMPUTERNAME").unwrap_or_else(|_| "AudioSync-PC".to_string());
            let ack = ControlMessage::HandshakeAck {
                server_name,
                pc_to_phone_enabled: cfg.pc_to_phone_enabled,
                phone_to_pc_enabled: cfg.phone_to_pc_enabled,
                opus_bitrate: cfg.opus_bitrate_bps,
            };
            let ts = (start_instant.elapsed().as_micros() & 0xFFFF_FFFF) as u32;
            if let Ok(pkt) = FramedPacket::control(0, ts, &ack) {
                if let Ok(len) = pkt.encode_into(send_buf) {
                    let _ = socket.send_to(&send_buf[..len], src_addr).await;
                }
            }
        }
        ControlMessage::MuteState { stream_id, muted } => {
            let mut cfg = audio_config.lock();
            match stream_id {
                StreamId::PcToPhone => cfg.pc_muted = muted,
                StreamId::PhoneToPc => cfg.mic_muted = muted,
                StreamId::Control => {}
            }
        }
        ControlMessage::StreamConfig {
            opus_bitrate,
            frame_duration_ms,
            jitter_capacity,
            noise_suppression_enabled,
            gain_db,
        } => {
            let mut cfg = audio_config.lock();
            cfg.opus_bitrate_bps = opus_bitrate.clamp(32_000, 128_000);
            cfg.frame_duration_ms = if frame_duration_ms == 20 { 20 } else { 10 };
            cfg.jitter_buffer_packets = jitter_capacity.clamp(1, 16);
            cfg.rnnoise_enabled = noise_suppression_enabled;
            cfg.mic_gain_db = gain_db.clamp(-12.0, 24.0);
        }
        ControlMessage::Disconnect { .. } => {
            state.connected.store(false, Ordering::Relaxed);
            *state.peer_addr.lock() = None;
        }
        ControlMessage::HandshakeAck { .. } => {}
    }
}
