use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, Device, SampleFormat, StreamConfig};
use nnnoiseless::DenoiseState;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::mpsc;

use crate::protocol::{sequence_diff, FramedPacket};

/// Standard audio operating sample rate (48,000 Hz).
pub const OPUS_SAMPLE_RATE: u32 = 48_000;

/// 5ms stereo frame size at 48kHz (240 samples per channel = 480 interleaved samples = 960 bytes PCM16).
pub const FRAME_SAMPLES_5MS: usize = 240;

/// 10ms frame size at 48kHz (480 samples per channel) — matches RNNoise `DenoiseState::FRAME_SIZE`.
pub const FRAME_SAMPLES_10MS: usize = DenoiseState::FRAME_SIZE; // 480

/// Maximum UDP audio frame bytes (960 bytes for 5ms Stereo 16-bit PCM, well below 1472 MTU).
pub const MAX_AUDIO_FRAME_BYTES: usize = 1400;

#[derive(Debug, Error)]
pub enum AudioEngineError {
    #[error("No default output audio device found for WASAPI loopback capture")]
    NoLoopbackDevice,
    #[error("VB-CABLE Input device not found and fallback output unavailable")]
    NoOutputDevice,
    #[error("Audio device config error: {0}")]
    DeviceConfigError(String),
    #[error("Failed to build audio stream: {0}")]
    BuildStreamError(String),
    #[error("Failed to start audio stream: {0}")]
    PlayStreamError(String),
    #[error("Opus codec error: {0}")]
    OpusError(String),
}

/// Live audio runtime configuration shared between Tauri UI, Global Hotkeys, and DSP threads.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioConfig {
    /// Stream PC desktop loopback audio to iPhone.
    pub pc_to_phone_enabled: bool,
    /// Stream iPhone microphone audio to PC VB-CABLE.
    pub phone_to_pc_enabled: bool,
    /// Mute outgoing PC audio.
    pub pc_muted: bool,
    /// Mute incoming iPhone microphone.
    pub mic_muted: bool,
    /// Enable Push-to-Talk mode for the iPhone mic.
    pub push_to_talk_enabled: bool,
    /// Current state of the Push-to-Talk key/button.
    pub push_to_talk_active: bool,
    /// Enable AI noise suppression (RNNoise) on iPhone microphone stream.
    pub rnnoise_enabled: bool,
    /// Voice Activity Detection (VAD) gate threshold (0.0 = disabled, up to 0.95).
    pub vad_gate_threshold: f32,
    /// Microphone gain boost in dB (-12.0 dB to +24.0 dB).
    pub mic_gain_db: f32,
    /// PC loopback volume multiplier (0.0 to 2.0).
    pub pc_volume: f32,
    /// Target Opus bitrate in bits per second (32_000 to 128_000).
    pub opus_bitrate_bps: i32,
    /// Frame duration in milliseconds (10 or 20).
    pub frame_duration_ms: u8,
    /// Jitter buffer target depth in packets (1 to 10).
    pub jitter_buffer_packets: usize,
    /// Preferred virtual mic output device name substring (defaults to "CABLE Input").
    pub virtual_mic_device_hint: String,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            pc_to_phone_enabled: true,
            phone_to_pc_enabled: true,
            pc_muted: false,
            mic_muted: false,
            push_to_talk_enabled: false,
            push_to_talk_active: false,
            rnnoise_enabled: true,
            vad_gate_threshold: 0.15,
            mic_gain_db: 0.0,
            pc_volume: 1.0,
            opus_bitrate_bps: 64_000,
            frame_duration_ms: 10,
            jitter_buffer_packets: 2,
            virtual_mic_device_hint: "CABLE Input".to_string(),
        }
    }
}

/// Real-time VU meter & DSP telemetry snapshot.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct AudioLevels {
    pub pc_peak: f32,
    pub pc_rms: f32,
    pub mic_peak: f32,
    pub mic_rms: f32,
    pub vad_probability: f32,
}

/// Atomic telemetry storage for lock-free reads from the UI / network loop.
#[derive(Default)]
pub struct AtomicAudioTelemetry {
    pc_peak_bits: AtomicU32,
    pc_rms_bits: AtomicU32,
    mic_peak_bits: AtomicU32,
    mic_rms_bits: AtomicU32,
    vad_prob_bits: AtomicU32,
}

impl AtomicAudioTelemetry {
    pub fn store_pc_levels(&self, peak: f32, rms: f32) {
        self.pc_peak_bits.store(peak.to_bits(), Ordering::Relaxed);
        self.pc_rms_bits.store(rms.to_bits(), Ordering::Relaxed);
    }

    pub fn store_mic_levels(&self, peak: f32, rms: f32, vad: f32) {
        self.mic_peak_bits.store(peak.to_bits(), Ordering::Relaxed);
        self.mic_rms_bits.store(rms.to_bits(), Ordering::Relaxed);
        self.vad_prob_bits.store(vad.to_bits(), Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> AudioLevels {
        AudioLevels {
            pc_peak: f32::from_bits(self.pc_peak_bits.load(Ordering::Relaxed)),
            pc_rms: f32::from_bits(self.pc_rms_bits.load(Ordering::Relaxed)),
            mic_peak: f32::from_bits(self.mic_peak_bits.load(Ordering::Relaxed)),
            mic_rms: f32::from_bits(self.mic_rms_bits.load(Ordering::Relaxed)),
            vad_probability: f32::from_bits(self.vad_prob_bits.load(Ordering::Relaxed)),
        }
    }
}

/// Adaptive UDP Jitter Buffer for incoming Opus microphone packets (`StreamId::PhoneToPc`).
pub struct AdaptiveJitterBuffer {
    packets: BTreeMap<u16, Vec<u8>>,
    next_expected_seq: Option<u16>,
    target_depth: usize,
    max_capacity: usize,
    primed: bool,
}

/// Outcome when popping the next frame from `AdaptiveJitterBuffer`.
pub enum JitterPopResult {
    /// Buffer is still priming or empty prior to stream start.
    NotReady,
    /// Contiguous Opus packet ready for decoding.
    Frame(Vec<u8>),
    /// Sequence gap detected — caller should invoke Opus Packet Loss Concealment (PLC).
    LostPacket,
}

impl AdaptiveJitterBuffer {
    pub fn new(target_depth: usize) -> Self {
        let target_depth = target_depth.clamp(1, 16);
        Self {
            packets: BTreeMap::new(),
            next_expected_seq: None,
            target_depth,
            max_capacity: target_depth * 6,
            primed: false,
        }
    }

    pub fn set_target_depth(&mut self, depth: usize) {
        self.target_depth = depth.clamp(1, 16);
        self.max_capacity = self.target_depth * 6;
    }

    pub fn push(&mut self, seq: u16, opus_payload: Vec<u8>) {
        if let Some(expected) = self.next_expected_seq {
            let diff = sequence_diff(seq, expected);
            if diff < -32 {
                crate::diag::inc(&crate::diag::JB_RESETS); // DIAG
                // Stream likely restarted on the iPhone client; reset sequence tracking.
                self.packets.clear();
                self.next_expected_seq = Some(seq);
                self.primed = false;
            } else if diff < 0 {
                crate::diag::inc(&crate::diag::JB_LATE_DROPS); // DIAG
                // Late packet that has already been concealed/played; drop it.
                return;
            }
        } else {
            self.next_expected_seq = Some(seq);
        }

        self.packets.insert(seq, opus_payload);

        // Bound maximum jitter buffer memory if a burst arrives.
        while self.packets.len() > self.max_capacity {
            crate::diag::inc(&crate::diag::JB_OVERFLOW_DROPS); // DIAG
            if let Some(expected) = self.next_expected_seq {
                self.packets.remove(&expected);
                self.next_expected_seq = Some(expected.wrapping_add(1));
            } else if let Some((&first_key, _)) = self.packets.iter().next() {
                self.packets.remove(&first_key);
            }
        }

        crate::diag::set_max(&crate::diag::JB_DEPTH_MAX, self.packets.len() as u64); // DIAG
        if self.packets.len() >= self.target_depth {
            self.primed = true;
        }
    }

    pub fn pop_next(&mut self) -> JitterPopResult {
        if !self.primed {
            return JitterPopResult::NotReady;
        }

        let Some(expected) = self.next_expected_seq else {
            self.primed = false;
            return JitterPopResult::NotReady;
        };

        if let Some(payload) = self.packets.remove(&expected) {
            self.next_expected_seq = Some(expected.wrapping_add(1));
            // Note: Do NOT un-prime if queue is empty; transient empty queue during normal packet flow
            // should not stall playback for an entire target_depth refill cycle!
            return JitterPopResult::Frame(payload);
        }

        // If the expected packet is missing, check if newer packets have already arrived.
        if !self.packets.is_empty() {
            self.next_expected_seq = Some(expected.wrapping_add(1));
            return JitterPopResult::LostPacket;
        }

        // Buffer is temporarily starved of future packets
        JitterPopResult::NotReady
    }
}

/// Stateful DSP processor combining Opus decoding, RNNoise AI denoising, VAD gate, and Gain boost.
pub struct MicDspPipeline {
    rnnoise: Box<DenoiseState<'static>>,
    jitter: AdaptiveJitterBuffer,
    rnnoise_input_fifo: VecDeque<f32>,
}

impl MicDspPipeline {
    pub fn new(jitter_depth: usize) -> Result<Self, AudioEngineError> {
        Ok(Self {
            rnnoise: DenoiseState::new(),
            jitter: AdaptiveJitterBuffer::new(jitter_depth),
            rnnoise_input_fifo: VecDeque::with_capacity(FRAME_SAMPLES_10MS * 4),
        })
    }

    /// Pushes an incoming UDP `PhoneToPc` packet into the jitter buffer.
    pub fn ingest_packet(&mut self, packet: FramedPacket, target_jitter_depth: usize) {
        self.jitter.set_target_depth(target_jitter_depth);
        self.jitter
            .push(packet.header.sequence_num, packet.payload);
    }

    /// Ingests available jitter-buffered packets (16-bit PCM Mono), runs RNNoise + Gain Boost, and pushes 48kHz mono
    /// samples into `output_ring`.
    pub fn process_available(
        &mut self,
        config: &AudioConfig,
        telemetry: &AtomicAudioTelemetry,
        output_ring: &Mutex<VecDeque<f32>>,
    ) {
        loop {
            match self.jitter.pop_next() {
                JitterPopResult::NotReady => break,
                JitterPopResult::Frame(pcm16_bytes) => {
                    crate::diag::inc(&crate::diag::JB_FRAMES); // DIAG
                    for chunk in pcm16_bytes.chunks_exact(2) {
                        let s16 = i16::from_le_bytes([chunk[0], chunk[1]]);
                        self.rnnoise_input_fifo.push_back(s16 as f32 / 32768.0);
                    }
                }
                JitterPopResult::LostPacket => {
                    crate::diag::inc(&crate::diag::JB_LOST); // DIAG
                    // Conceal 10ms (480 samples) of zero-fill
                    for _ in 0..FRAME_SAMPLES_10MS {
                        self.rnnoise_input_fifo.push_back(0.0);
                    }
                }
            }
        }

        // Check mute / Push-to-Talk state
        let is_active = config.phone_to_pc_enabled
            && !config.mic_muted
            && (!config.push_to_talk_enabled || config.push_to_talk_active);

        let gain_linear = 10.0_f32.powf(config.mic_gain_db / 20.0);

        // Process in exact 480-sample (10ms) frames required by RNNoise
        while self.rnnoise_input_fifo.len() >= FRAME_SAMPLES_10MS {
            let mut raw_frame = [0.0f32; FRAME_SAMPLES_10MS];
            for slot in &mut raw_frame {
                *slot = self.rnnoise_input_fifo.pop_front().unwrap_or(0.0);
            }

            if !is_active {
                telemetry.store_mic_levels(0.0, 0.0, 0.0);
                let mut ring = output_ring.lock();
                for _ in 0..FRAME_SAMPLES_10MS {
                    if ring.len() < OPUS_SAMPLE_RATE as usize {
                        ring.push_back(0.0);
                    }
                }
                continue;
            }

            let mut processed_frame = [0.0f32; FRAME_SAMPLES_10MS];
            let vad_prob = if config.rnnoise_enabled {
                // `nnnoiseless` operates on 16-bit PCM amplitude scale (-32768.0..32767.0)
                let mut scaled_in = [0.0f32; FRAME_SAMPLES_10MS];
                let mut scaled_out = [0.0f32; FRAME_SAMPLES_10MS];
                for i in 0..FRAME_SAMPLES_10MS {
                    scaled_in[i] = (raw_frame[i] * 32768.0).clamp(-32768.0, 32767.0);
                }
                let vad = self.rnnoise.process_frame(&mut scaled_out, &scaled_in);
                let gate_factor = if vad < config.vad_gate_threshold {
                    (vad / config.vad_gate_threshold.max(0.01)).powi(2)
                } else {
                    1.0
                };
                let diag_gated = gate_factor < 0.5; // DIAG
                if diag_gated {
                    crate::diag::inc(&crate::diag::VAD_GATED_FRAMES);
                } // DIAG
                if crate::diag::PREV_GATED.swap(diag_gated, Ordering::Relaxed) != diag_gated {
                    crate::diag::inc(&crate::diag::VAD_GATE_TOGGLES); // DIAG
                }
                for i in 0..FRAME_SAMPLES_10MS {
                    processed_frame[i] = (scaled_out[i] / 32768.0) * gate_factor;
                }
                vad
            } else {
                processed_frame.copy_from_slice(&raw_frame);
                1.0
            };

            // Apply Gain Boost with smooth tanh soft-clipping and compute VU metrics
            let mut peak = 0.0f32;
            let mut sum_sq = 0.0f32;
            for sample in &mut processed_frame {
                let boosted = (*sample * gain_linear).tanh();
                let abs = boosted.abs();
                if abs > peak {
                    peak = abs;
                }
                sum_sq += boosted * boosted;
                *sample = boosted;
            }
            let rms = (sum_sq / FRAME_SAMPLES_10MS as f32).sqrt();
            telemetry.store_mic_levels(peak, rms, vad_prob);

            crate::diag::dump_dsp(&processed_frame); // DIAG (outside lock)
            let mut ring = output_ring.lock();
            // Bound ring buffer latency to 120ms max (~5760 samples at 48kHz)
            let max_ring_samples = (OPUS_SAMPLE_RATE as usize * 12) / 100;
            while ring.len() + FRAME_SAMPLES_10MS > max_ring_samples {
                ring.pop_front();
                crate::diag::inc(&crate::diag::RING_TRIM_SAMPLES); // DIAG
            }
            ring.extend(processed_frame);
            crate::diag::set_max(&crate::diag::RING_HIGH_WATER, ring.len() as u64); // DIAG
            crate::diag::inc(&crate::diag::DSP_FRAMES); // DIAG
        }
    }
}

/// Calculates Peak and RMS values for an interleaved stereo or mono slice.
#[inline]
pub fn compute_peak_and_rms(samples: &[f32]) -> (f32, f32) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mut peak = 0.0f32;
    let mut sum_sq = 0.0f32;
    for &s in samples {
        let a = s.abs();
        if a > peak {
            peak = a;
        }
        sum_sq += s * s;
    }
    let rms = (sum_sq / samples.len() as f32).sqrt();
    (peak, rms)
}

/// Finds the VB-CABLE Virtual Audio Device (`"CABLE Input"`) or falls back to default output.
pub fn find_vbcable_output_device(hint: &str) -> Result<(Device, String, bool), AudioEngineError> {
    let host = cpal::default_host();
    let search_hint = if hint.trim().is_empty() {
        "CABLE Input"
    } else {
        hint.trim()
    };
    let search_lower = search_hint.to_lowercase();

    if let Ok(devices) = host.output_devices() {
        for dev in devices {
            if let Ok(name) = dev.name() {
                let name_lower = name.to_lowercase();
                if name_lower.contains(&search_lower)
                    || name_lower.contains("vb-audio")
                    || name_lower.contains("cable input")
                {
                    return Ok((dev, name, true));
                }
            }
        }
    }

    // Fallback to default output device if VB-CABLE is not installed yet
    let fallback = host
        .default_output_device()
        .ok_or(AudioEngineError::NoOutputDevice)?;
    let name = fallback
        .name()
        .unwrap_or_else(|_| "Default Output Device".to_string());
    Ok((fallback, name, false))
}

/// Lists all available output audio devices on Windows (for UI selector & diagnostics).
pub fn list_output_devices() -> Vec<String> {
    let host = cpal::default_host();
    let mut names = Vec::new();
    if let Ok(devices) = host.output_devices() {
        for dev in devices {
            if let Ok(name) = dev.name() {
                names.push(name);
            }
        }
    }
    names
}

/// High-level AudioEngine controller managing WASAPI loopback capture, Mic DSP, and VB-CABLE output.
pub struct AudioEngine {
    pub config: Arc<Mutex<AudioConfig>>,
    pub telemetry: Arc<AtomicAudioTelemetry>,
    running: Arc<AtomicBool>,
    vbcable_device_name: Arc<Mutex<String>>,
    vbcable_detected: Arc<AtomicBool>,
}

impl AudioEngine {
    pub fn new(config: Arc<Mutex<AudioConfig>>) -> Self {
        Self {
            config,
            telemetry: Arc::new(AtomicAudioTelemetry::default()),
            running: Arc::new(AtomicBool::new(false)),
            vbcable_device_name: Arc::new(Mutex::new(String::from("Not initialized"))),
            vbcable_detected: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::Relaxed)
    }

    pub fn vbcable_status(&self) -> (String, bool) {
        (
            self.vbcable_device_name.lock().clone(),
            self.vbcable_detected.load(Ordering::Relaxed),
        )
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    /// Starts both the WASAPI desktop loopback capture thread (`PcToPhone`) and the
    /// incoming microphone DSP + VB-CABLE output thread (`PhoneToPc`).
    pub fn start(
        &self,
        outbound_opus_tx: mpsc::Sender<Vec<u8>>,
        mut inbound_mic_rx: mpsc::Receiver<FramedPacket>,
    ) -> Result<(), AudioEngineError> {
        if self.running.swap(true, Ordering::SeqCst) {
            return Ok(());
        }

        let running_loopback = Arc::clone(&self.running);
        let config_loopback = Arc::clone(&self.config);
        let telemetry_loopback = Arc::clone(&self.telemetry);

        // 1. Spawn WASAPI Loopback Capture + Stereo Opus Encoder thread (PC -> iPhone)
        std::thread::Builder::new()
            .name("wasapi-loopback-opus".to_string())
            .spawn(move || {
                if let Err(err) = run_wasapi_loopback_worker(
                    running_loopback,
                    config_loopback,
                    telemetry_loopback,
                    outbound_opus_tx,
                ) {
                    log::error!("WASAPI loopback worker exited with error: {err}");
                }
            })
            .map_err(|e| AudioEngineError::BuildStreamError(e.to_string()))?;

        // 2. Spawn Incoming Mic DSP (Opus Decode + RNNoise + Gain) & VB-CABLE Output thread
        let running_mic = Arc::clone(&self.running);
        let config_mic = Arc::clone(&self.config);
        let telemetry_mic = Arc::clone(&self.telemetry);
        let vbcable_name_slot = Arc::clone(&self.vbcable_device_name);
        let vbcable_flag_slot = Arc::clone(&self.vbcable_detected);

        std::thread::Builder::new()
            .name("vbcable-mic-dsp".to_string())
            .spawn(move || {
                if let Err(err) = run_vbcable_mic_worker(
                    running_mic,
                    config_mic,
                    telemetry_mic,
                    vbcable_name_slot,
                    vbcable_flag_slot,
                    &mut inbound_mic_rx,
                ) {
                    log::error!("VB-CABLE mic worker exited with error: {err}");
                }
            })
            .map_err(|e| AudioEngineError::BuildStreamError(e.to_string()))?;

        Ok(())
    }
}

/// Dedicated worker thread that opens Windows WASAPI loopback on the default output device,
/// resamples/downmixes to 48kHz stereo, encodes low-delay Opus frames, and sends them to the UDP task.
fn run_wasapi_loopback_worker(
    running: Arc<AtomicBool>,
    config: Arc<Mutex<AudioConfig>>,
    telemetry: Arc<AtomicAudioTelemetry>,
    outbound_opus_tx: mpsc::Sender<Vec<u8>>,
) -> Result<(), AudioEngineError> {
    let host = cpal::default_host();
    // On Windows WASAPI, building an *input* stream on an *output* device opens it in Loopback mode!
    let loopback_device = host
        .default_output_device()
        .ok_or(AudioEngineError::NoLoopbackDevice)?;

    let supported_cfg = loopback_device
        .default_output_config()
        .map_err(|e| AudioEngineError::DeviceConfigError(e.to_string()))?;

    let sample_format = supported_cfg.sample_format();
    let device_rate = supported_cfg.sample_rate().0;
    let device_channels = supported_cfg.channels() as usize;

    // Request a low-latency 5ms buffer (e.g. 240 frames at 48kHz) with automatic fallback
    let preferred_frames = (device_rate / 200).max(128);
    let low_latency_cfg = StreamConfig {
        channels: supported_cfg.channels(),
        sample_rate: supported_cfg.sample_rate(),
        buffer_size: BufferSize::Fixed(preferred_frames),
    };
    let default_cfg: StreamConfig = supported_cfg.into();

    let (pcm_tx, pcm_rx) = std::sync::mpsc::sync_channel::<Vec<f32>>(64);

    let err_fn = |err| {
        log::warn!("WASAPI loopback stream error: {err}");
    };

    let build_loopback = |stream_cfg: &StreamConfig| -> Result<cpal::Stream, cpal::BuildStreamError> {
        match sample_format {
            SampleFormat::F32 => {
                let tx = pcm_tx.clone();
                loopback_device.build_input_stream(
                    stream_cfg,
                    move |data: &[f32], _| {
                        let _ = tx.try_send(data.to_vec());
                    },
                    err_fn,
                    None,
                )
            }
            SampleFormat::I16 => {
                let tx = pcm_tx.clone();
                loopback_device.build_input_stream(
                    stream_cfg,
                    move |data: &[i16], _| {
                        let converted: Vec<f32> =
                            data.iter().map(|&s| s as f32 / 32768.0).collect();
                        let _ = tx.try_send(converted);
                    },
                    err_fn,
                    None,
                )
            }
            SampleFormat::U16 => {
                let tx = pcm_tx.clone();
                loopback_device.build_input_stream(
                    stream_cfg,
                    move |data: &[u16], _| {
                        let converted: Vec<f32> = data
                            .iter()
                            .map(|&s| (s as f32 - 32768.0) / 32768.0)
                            .collect();
                        let _ = tx.try_send(converted);
                    },
                    err_fn,
                    None,
                )
            }
            _ => Err(cpal::BuildStreamError::StreamConfigNotSupported),
        }
    };

    let stream = build_loopback(&low_latency_cfg)
        .or_else(|_| build_loopback(&default_cfg))
        .map_err(|e| AudioEngineError::BuildStreamError(e.to_string()))?;

    stream
        .play()
        .map_err(|e| AudioEngineError::PlayStreamError(e.to_string()))?;

    let mut stereo_48k_fifo: VecDeque<f32> = VecDeque::with_capacity(OPUS_SAMPLE_RATE as usize * 2);

    while running.load(Ordering::Relaxed) {
        match pcm_rx.recv_timeout(std::time::Duration::from_millis(25)) {
            Ok(raw_interleaved) => {
                let cfg_snapshot = config.lock().clone();
                if !cfg_snapshot.pc_to_phone_enabled || cfg_snapshot.pc_muted {
                    telemetry.store_pc_levels(0.0, 0.0);
                    stereo_48k_fifo.clear();
                    continue;
                }

                // Convert arbitrary channel count & sample rate to 48kHz Stereo interleaved
                convert_to_48k_stereo(
                    &raw_interleaved,
                    device_channels,
                    device_rate,
                    cfg_snapshot.pc_volume,
                    &mut stereo_48k_fifo,
                );

                // 5ms = 240 stereo frames (480 interleaved f32 = 960 bytes PCM16)
                let frame_samples_per_ch = FRAME_SAMPLES_5MS;
                let interleaved_frame_len = frame_samples_per_ch * 2;

                while stereo_48k_fifo.len() >= interleaved_frame_len {
                    let mut pcm_frame = vec![0.0f32; interleaved_frame_len];
                    for slot in &mut pcm_frame {
                        *slot = stereo_48k_fifo.pop_front().unwrap_or(0.0);
                    }

                    let (peak, rms) = compute_peak_and_rms(&pcm_frame);
                    telemetry.store_pc_levels(peak, rms);

                    // Pack into pristine 16-bit Little-Endian PCM (480 samples * 2 = 960 bytes, zero codec mismatch)
                    let mut pcm16_bytes = Vec::with_capacity(interleaved_frame_len * 2);
                    for &s in &pcm_frame {
                        let clamped = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
                        pcm16_bytes.extend_from_slice(&clamped.to_le_bytes());
                    }
                    let _ = outbound_opus_tx.try_send(pcm16_bytes);
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                telemetry.store_pc_levels(0.0, 0.0);
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    Ok(())
}

/// Dedicated worker thread that receives incoming iPhone mic Opus packets, runs RNNoise + Gain DSP,
/// and streams the audio into the VB-CABLE Virtual Audio Device.
fn run_vbcable_mic_worker(
    running: Arc<AtomicBool>,
    config: Arc<Mutex<AudioConfig>>,
    telemetry: Arc<AtomicAudioTelemetry>,
    vbcable_name_slot: Arc<Mutex<String>>,
    vbcable_flag_slot: Arc<AtomicBool>,
    inbound_mic_rx: &mut mpsc::Receiver<FramedPacket>,
) -> Result<(), AudioEngineError> {
    let hint = config.lock().virtual_mic_device_hint.clone();
    let (output_device, dev_name, is_vbcable) = find_vbcable_output_device(&hint)?;
    *vbcable_name_slot.lock() = dev_name;
    vbcable_flag_slot.store(is_vbcable, Ordering::Relaxed);

    let supported_cfg = output_device
        .default_output_config()
        .map_err(|e| AudioEngineError::DeviceConfigError(e.to_string()))?;

    let out_format = supported_cfg.sample_format();
    let out_rate = supported_cfg.sample_rate().0;
    let out_channels = supported_cfg.channels() as usize;

    crate::diag::emit(format!(
        "[DIAG CFG] out_device='{}' is_vbcable={} default_fmt={:?} rate={} ch={} buf_range={:?} requested=Fixed({})",
        vbcable_name_slot.lock(),
        is_vbcable,
        out_format,
        out_rate,
        out_channels,
        supported_cfg.buffer_size(),
        (out_rate / 200).max(128)
    ));
    if let Ok(cfgs) = output_device.supported_output_configs() {
        for c in cfgs {
            crate::diag::emit(format!("[DIAG CFG]   supported: {:?}", c));
        }
    }

    let preferred_frames = (out_rate / 200).max(128);
    let low_latency_cfg = StreamConfig {
        channels: supported_cfg.channels(),
        sample_rate: supported_cfg.sample_rate(),
        buffer_size: BufferSize::Fixed(preferred_frames),
    };
    let default_cfg: StreamConfig = supported_cfg.into();

    // Shared 48kHz mono PCM ring buffer between DSP processor and VB-CABLE output callback
    let output_ring: Arc<Mutex<VecDeque<f32>>> =
        Arc::new(Mutex::new(VecDeque::with_capacity(OPUS_SAMPLE_RATE as usize)));

    let err_fn = |err| {
        log::warn!("VB-CABLE output stream error: {err}");
        crate::diag::emit(format!("[DIAG ERR] VB-CABLE output stream error: {err}")); // DIAG
    };

    let build_output = |stream_cfg: &StreamConfig| -> Result<cpal::Stream, cpal::BuildStreamError> {
        let ring = Arc::clone(&output_ring);
        match out_format {
            SampleFormat::F32 => output_device.build_output_stream(
                stream_cfg,
                move |data: &mut [f32], _| {
                    if !is_vbcable {
                        // Safety silence: never blast mic into main PC speakers to prevent feedback loop
                        data.fill(0.0);
                    } else {
                        fill_output_buffer_f32(data, out_channels, out_rate, &ring);
                    }
                },
                err_fn,
                None,
            ),
            SampleFormat::I16 => output_device.build_output_stream(
                stream_cfg,
                move |data: &mut [i16], _| {
                    if !is_vbcable {
                        data.fill(0);
                    } else {
                        let mut temp = vec![0.0f32; data.len()];
                        fill_output_buffer_f32(&mut temp, out_channels, out_rate, &ring);
                        for (dst, &src) in data.iter_mut().zip(temp.iter()) {
                            *dst = (src * 32767.0).clamp(-32768.0, 32767.0) as i16;
                        }
                    }
                },
                err_fn,
                None,
            ),
            SampleFormat::U16 => output_device.build_output_stream(
                stream_cfg,
                move |data: &mut [u16], _| {
                    if !is_vbcable {
                        data.fill(32768);
                    } else {
                        let mut temp = vec![0.0f32; data.len()];
                        fill_output_buffer_f32(&mut temp, out_channels, out_rate, &ring);
                        for (dst, &src) in data.iter_mut().zip(temp.iter()) {
                            *dst = ((src * 32767.0) + 32768.0).clamp(0.0, 65535.0) as u16;
                        }
                    }
                },
                err_fn,
                None,
            ),
            _ => Err(cpal::BuildStreamError::StreamConfigNotSupported),
        }
    };

    let stream = match build_output(&low_latency_cfg) {
        Ok(s) => {
            crate::diag::emit(format!(
                "[DIAG CFG] opened LOW-LATENCY cfg {:?}",
                low_latency_cfg
            ));
            s
        }
        Err(e) => {
            crate::diag::emit(format!(
                "[DIAG CFG] low-latency rejected ({e}); using DEFAULT cfg {:?}",
                default_cfg
            ));
            build_output(&default_cfg)
                .map_err(|e| AudioEngineError::BuildStreamError(e.to_string()))?
        }
    };

    stream
        .play()
        .map_err(|e| AudioEngineError::PlayStreamError(e.to_string()))?;

    let initial_jitter = config.lock().jitter_buffer_packets.max(3);
    let mut dsp = MicDspPipeline::new(initial_jitter)?;

    while running.load(Ordering::Relaxed) {
        match inbound_mic_rx.try_recv() {
            Ok(pkt) => {
                let cfg_snapshot = config.lock().clone();
                dsp.ingest_packet(pkt, cfg_snapshot.jitter_buffer_packets.max(3));
                // Drain any immediately queued packets before running DSP
                while let Ok(more_pkt) = inbound_mic_rx.try_recv() {
                    dsp.ingest_packet(more_pkt, cfg_snapshot.jitter_buffer_packets.max(3));
                }
                dsp.process_available(&cfg_snapshot, &telemetry, &output_ring);
            }
            Err(mpsc::error::TryRecvError::Empty) => {
                let diag_t = crate::diag::now_us(); // DIAG
                std::thread::sleep(std::time::Duration::from_millis(1));
                let diag_slept = crate::diag::now_us() - diag_t; // DIAG
                crate::diag::inc(&crate::diag::WORKER_SLEEP_N); // DIAG
                crate::diag::add(&crate::diag::WORKER_SLEEP_SUM_US, diag_slept); // DIAG
                crate::diag::set_max(&crate::diag::WORKER_SLEEP_MAX_US, diag_slept); // DIAG
            }
            Err(mpsc::error::TryRecvError::Disconnected) => break,
        }
    }

    Ok(())
}

/// Converts interleaved multi-channel input at `src_rate` into 48kHz stereo interleaved samples.
fn convert_to_48k_stereo(
    input: &[f32],
    channels: usize,
    src_rate: u32,
    volume: f32,
    out_fifo: &mut VecDeque<f32>,
) {
    if channels == 0 || input.is_empty() {
        return;
    }
    let in_frames = input.len() / channels;
    if in_frames == 0 {
        return;
    }

    if src_rate == OPUS_SAMPLE_RATE {
        for frame_idx in 0..in_frames {
            let base = frame_idx * channels;
            let l = (input[base] * volume).clamp(-1.0, 1.0);
            let r = if channels >= 2 {
                (input[base + 1] * volume).clamp(-1.0, 1.0)
            } else {
                l
            };
            out_fifo.push_back(l);
            out_fifo.push_back(r);
        }
    } else {
        // Linear resampling to 48kHz
        let ratio = src_rate as f64 / OPUS_SAMPLE_RATE as f64;
        let out_frames = ((in_frames as f64) / ratio).floor() as usize;
        for out_idx in 0..out_frames {
            let src_pos = out_idx as f64 * ratio;
            let idx0 = (src_pos.floor() as usize).min(in_frames - 1);
            let idx1 = (idx0 + 1).min(in_frames - 1);
            let frac = (src_pos - idx0 as f64) as f32;

            let base0 = idx0 * channels;
            let base1 = idx1 * channels;

            let l0 = input[base0];
            let l1 = input[base1];
            let l = ((l0 + (l1 - l0) * frac) * volume).clamp(-1.0, 1.0);

            let r = if channels >= 2 {
                let r0 = input[base0 + 1];
                let r1 = input[base1 + 1];
                ((r0 + (r1 - r0) * frac) * volume).clamp(-1.0, 1.0)
            } else {
                l
            };

            out_fifo.push_back(l);
            out_fifo.push_back(r);
        }
    }
}

/// Fills the VB-CABLE output slice from the 48kHz mono ring buffer, duplicating across output channels
/// and adjusting for device sample rate if needed.
fn fill_output_buffer_f32(
    out: &mut [f32],
    out_channels: usize,
    out_rate: u32,
    ring: &Mutex<VecDeque<f32>>,
) {
    if out_channels == 0 || out.is_empty() {
        return;
    }
    let out_frames = out.len() / out_channels;
    let diag_t_enter = crate::diag::now_us(); // DIAG
    let mut guard = ring.lock();
    let diag_t_locked = crate::diag::now_us(); // DIAG
    let diag_ring_before = guard.len(); // DIAG

    if out_rate == OPUS_SAMPLE_RATE {
        for frame_idx in 0..out_frames {
            let sample = guard.pop_front().unwrap_or(0.0);
            let base = frame_idx * out_channels;
            for ch in 0..out_channels {
                out[base + ch] = sample;
            }
        }
    } else {
        // Simple step conversion from 48kHz mono ring to `out_rate`
        let step = OPUS_SAMPLE_RATE as f32 / out_rate as f32;
        let mut accum = 0.0f32;
        let mut current = guard.front().copied().unwrap_or(0.0);
        for frame_idx in 0..out_frames {
            accum += step;
            while accum >= 1.0 {
                current = guard.pop_front().unwrap_or(0.0);
                accum -= 1.0;
            }
            let base = frame_idx * out_channels;
            for ch in 0..out_channels {
                out[base + ch] = current;
            }
        }
    }
    crate::diag::on_output_callback(
        diag_t_enter,
        diag_t_locked,
        out_frames,
        out_rate,
        diag_ring_before,
    ); // DIAG
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{PacketType, StreamId};

    #[test]
    fn test_pcm16_ingest_and_rnnoise_pipeline() {
        // Generate 10ms 440Hz sine wave at 48kHz (480 samples)
        let mut pcm16_bytes = Vec::with_capacity(FRAME_SAMPLES_10MS * 2);
        for i in 0..FRAME_SAMPLES_10MS {
            let t = i as f32 / OPUS_SAMPLE_RATE as f32;
            let sample = (2.0 * std::f32::consts::PI * 440.0 * t).sin() * 0.5;
            let s16 = (sample * 32767.0) as i16;
            pcm16_bytes.extend_from_slice(&s16.to_le_bytes());
        }

        let mut dsp = MicDspPipeline::new(1).expect("DSP pipeline init");
        let pkt = FramedPacket::new(
            PacketType::AudioOpus,
            StreamId::PhoneToPc,
            1,
            100,
            pcm16_bytes,
        );

        let cfg = AudioConfig::default();
        let telemetry = AtomicAudioTelemetry::default();
        let output_ring = Mutex::new(VecDeque::new());

        dsp.ingest_packet(pkt, 1);
        dsp.process_available(&cfg, &telemetry, &output_ring);

        assert_eq!(output_ring.lock().len(), FRAME_SAMPLES_10MS);
    }
}
