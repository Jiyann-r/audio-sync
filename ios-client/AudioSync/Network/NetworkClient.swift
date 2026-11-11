import Combine
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 8-Byte UDP Wire Framing Protocol (Byte-for-Byte Parity with desktop/src-tauri/src/protocol.rs)

/// Exact size in bytes of the custom UDP framing header:
/// `[PacketType (1B) | StreamID (1B) | SequenceNum (2B) | Timestamp (4B)]`
public let kPacketHeaderSize: Int = 8

/// Maximum safe UDP datagram payload size (standard MTU 1500 - IP 20B - UDP 8B).
public let kMaxUdpDatagramSize: Int = 1472

/// Default Windows PC IP address and UDP port.
public let kDefaultPcHost: String = "192.168.1.13"
public let kDefaultUdpPort: UInt16 = 54321

/// mDNS / Bonjour service type broadcast by the Windows companion app (`_audiosync._udp.local.`).
public let kMdnsServiceType: String = "_audiosync._udp"
public let kMdnsDomain: String = "local."

/// 1-Byte PacketType field (offset 0).
public enum PacketType: UInt8, Codable, Sendable {
    /// Opus-encoded audio frame payload.
    case audioOpus = 0x01
    /// Latency measurement request (echoed back via `.pong`).
    case ping      = 0x02
    /// Latency measurement response echoing sender's `sequenceNum` & `timestamp`.
    case pong      = 0x03
    /// Control signaling message (JSON-encoded `ControlMessage`).
    case control   = 0x04
}

/// 1-Byte StreamID field (offset 1).
public enum StreamId: UInt8, Codable, Sendable {
    /// Control / Ping-Pong / Signaling stream.
    case control   = 0x00
    /// PC Desktop WASAPI Loopback -> iPhone Speaker/Headphones (48kHz Stereo Opus).
    case pcToPhone = 0x01
    /// iPhone Microphone -> PC VB-CABLE Virtual Microphone (48kHz Mono Opus).
    case phoneToPc = 0x02

    /// Matches Rust `#[derive(Serialize, Deserialize)] pub enum StreamId` variant names in JSON control payloads.
    public var rustVariantName: String {
        switch self {
        case .control:   return "Control"
        case .pcToPhone: return "PcToPhone"
        case .phoneToPc: return "PhoneToPc"
        }
    }

    public static func fromRustVariantName(_ name: String) -> StreamId? {
        switch name {
        case "Control":   return .control
        case "PcToPhone": return .pcToPhone
        case "PhoneToPc": return .phoneToPc
        default:          return nil
        }
    }
}

/// 8-byte big-endian wire header:
/// ```
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |  PacketType   |   StreamID    |          SequenceNum          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Timestamp                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
public struct PacketHeader: Equatable, Sendable {
    public let packetType: PacketType
    public let streamId: StreamId
    public let sequenceNum: UInt16
    public let timestamp: UInt32

    public init(
        packetType: PacketType,
        streamId: StreamId,
        sequenceNum: UInt16,
        timestamp: UInt32
    ) {
        self.packetType = packetType
        self.streamId = streamId
        self.sequenceNum = sequenceNum
        self.timestamp = timestamp
    }

    /// Serializes the header into an 8-byte network-order (big-endian) byte array.
    @inlinable
    public func toBytes() -> [UInt8] {
        return [
            packetType.rawValue,
            streamId.rawValue,
            UInt8((sequenceNum >> 8) & 0xFF),
            UInt8(sequenceNum & 0xFF),
            UInt8((timestamp >> 24) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF)
        ]
    }

    /// Parses an 8-byte network-order (big-endian) `Data` slice into a `PacketHeader`.
    @inlinable
    public static func fromData(_ data: Data) -> PacketHeader? {
        guard data.count >= kPacketHeaderSize else { return nil }
        let start = data.startIndex
        let b0 = data[start]
        let b1 = data[start + 1]
        let b2 = data[start + 2]
        let b3 = data[start + 3]
        let b4 = data[start + 4]
        let b5 = data[start + 5]
        let b6 = data[start + 6]
        let b7 = data[start + 7]

        guard let packetType = PacketType(rawValue: b0),
              let streamId = StreamId(rawValue: b1) else {
            return nil
        }

        let seq = (UInt16(b2) << 8) | UInt16(b3)
        let ts = (UInt32(b4) << 24) | (UInt32(b5) << 16) | (UInt32(b6) << 8) | UInt32(b7)

        return PacketHeader(
            packetType: packetType,
            streamId: streamId,
            sequenceNum: seq,
            timestamp: ts
        )
    }
}

/// Complete framed UDP packet consisting of the 8-byte `PacketHeader` and variable payload.
public struct FramedPacket: Equatable, Sendable {
    public let header: PacketHeader
    public let payload: Data

    public init(
        packetType: PacketType,
        streamId: StreamId,
        sequenceNum: UInt16,
        timestamp: UInt32,
        payload: Data = Data()
    ) {
        self.header = PacketHeader(
            packetType: packetType,
            streamId: streamId,
            sequenceNum: sequenceNum,
            timestamp: timestamp
        )
        self.payload = payload
    }

    public init(header: PacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public static func ping(sequenceNum: UInt16, timestamp: UInt32) -> FramedPacket {
        FramedPacket(
            packetType: .ping,
            streamId: .control,
            sequenceNum: sequenceNum,
            timestamp: timestamp
        )
    }

    public static func pong(sequenceNum: UInt16, timestamp: UInt32) -> FramedPacket {
        FramedPacket(
            packetType: .pong,
            streamId: .control,
            sequenceNum: sequenceNum,
            timestamp: timestamp
        )
    }

    /// Encodes the 8-byte header + payload into a single contiguous UDP datagram `Data`.
    @inlinable
    public func encode() -> Data {
        var out = Data(capacity: kPacketHeaderSize + payload.count)
        out.append(contentsOf: header.toBytes())
        out.append(payload)
        return out
    }

    /// Decodes a raw UDP datagram `Data` into a `FramedPacket`.
    @inlinable
    public static func decode(_ datagram: Data) -> FramedPacket? {
        guard let header = PacketHeader.fromData(datagram) else { return nil }
        let payloadStart = datagram.startIndex + kPacketHeaderSize
        let payload = datagram.count > kPacketHeaderSize
            ? Data(datagram[payloadStart..<datagram.endIndex])
            : Data()
        return FramedPacket(header: header, payload: payload)
    }
}

/// Returns signed 16-bit wrapping sequence difference `a - b`, identical to Rust `sequence_diff`.
@inlinable
public func sequenceDiff(_ a: UInt16, _ b: UInt16) -> Int16 {
    return Int16(bitPattern: a &- b)
}

// MARK: - Control Signaling Messages (Matches Rust `#[serde(tag = "type", rename_all = "snake_case")]`)

public enum ControlMessage: Sendable {
    case handshake(deviceName: String, protocolVersion: UInt8, sampleRate: UInt32, channels: UInt8)
    case handshakeAck(serverName: String, pcToPhoneEnabled: Bool, phoneToPcEnabled: Bool, opusBitrate: Int32)
    case muteState(streamId: StreamId, muted: Bool)
    case streamConfig(opusBitrate: Int32, frameDurationMs: UInt8, jitterCapacity: Int, noiseSuppressionEnabled: Bool, gainDb: Float)
    case disconnect(reason: String)

    public func toJSONData() -> Data? {
        var dict: [String: Any] = [:]
        switch self {
        case let .handshake(deviceName, protocolVersion, sampleRate, channels):
            dict = [
                "type": "handshake",
                "device_name": deviceName,
                "protocol_version": protocolVersion,
                "sample_rate": sampleRate,
                "channels": channels
            ]
        case let .handshakeAck(serverName, pcToPhoneEnabled, phoneToPcEnabled, opusBitrate):
            dict = [
                "type": "handshake_ack",
                "server_name": serverName,
                "pc_to_phone_enabled": pcToPhoneEnabled,
                "phone_to_pc_enabled": phoneToPcEnabled,
                "opus_bitrate": opusBitrate
            ]
        case let .muteState(streamId, muted):
            dict = [
                "type": "mute_state",
                "stream_id": streamId.rustVariantName,
                "muted": muted
            ]
        case let .streamConfig(opusBitrate, frameDurationMs, jitterCapacity, noiseSuppressionEnabled, gainDb):
            dict = [
                "type": "stream_config",
                "opus_bitrate": opusBitrate,
                "frame_duration_ms": frameDurationMs,
                "jitter_capacity": jitterCapacity,
                "noise_suppression_enabled": noiseSuppressionEnabled,
                "gain_db": gainDb
            ]
        case let .disconnect(reason):
            dict = [
                "type": "disconnect",
                "reason": reason
            ]
        }
        return try? JSONSerialization.data(withJSONObject: dict, options: [])
    }

    public static func fromJSONData(_ data: Data) -> ControlMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }

        switch type {
        case "handshake_ack":
            let serverName = (obj["server_name"] as? String) ?? "AudioSync-PC"
            let pcToPhone = (obj["pc_to_phone_enabled"] as? Bool) ?? true
            let phoneToPc = (obj["phone_to_pc_enabled"] as? Bool) ?? true
            let bitrate = (obj["opus_bitrate"] as? NSNumber)?.int32Value ?? 64_000
            return .handshakeAck(
                serverName: serverName,
                pcToPhoneEnabled: pcToPhone,
                phoneToPcEnabled: phoneToPc,
                opusBitrate: bitrate
            )
        case "mute_state":
            let muted = (obj["muted"] as? Bool) ?? false
            if let streamStr = obj["stream_id"] as? String,
               let streamId = StreamId.fromRustVariantName(streamStr) {
                return .muteState(streamId: streamId, muted: muted)
            } else if let streamRaw = (obj["stream_id"] as? NSNumber)?.uint8Value,
                      let streamId = StreamId(rawValue: streamRaw) {
                return .muteState(streamId: streamId, muted: muted)
            }
            return nil
        case "stream_config":
            let bitrate = (obj["opus_bitrate"] as? NSNumber)?.int32Value ?? 64_000
            let frameMs = (obj["frame_duration_ms"] as? NSNumber)?.uint8Value ?? 10
            let jitter = (obj["jitter_capacity"] as? NSNumber)?.intValue ?? 2
            let rnnoise = (obj["noise_suppression_enabled"] as? Bool) ?? true
            let gain = (obj["gain_db"] as? NSNumber)?.floatValue ?? 0.0
            return .streamConfig(
                opusBitrate: bitrate,
                frameDurationMs: frameMs,
                jitterCapacity: jitter,
                noiseSuppressionEnabled: rnnoise,
                gainDb: gain
            )
        case "disconnect":
            let reason = (obj["reason"] as? String) ?? "Server closed connection"
            return .disconnect(reason: reason)
        default:
            return nil
        }
    }
}

// MARK: - Discovered mDNS Host Model

public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    public let version: String
    public let sampleRate: Int
}

// MARK: - NetworkClient (NWBrowser + NWConnection + Background/Foreground Recovery)

public final class NetworkClient: ObservableObject {
    // Published UI telemetry (updated on MainQueue)
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectionStateText: String = "Searching for PC..."
    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []
    @Published public private(set) var connectedServerName: String = "Not Connected"
    @Published public private(set) var activeEndpointDescription: String = "\(kDefaultPcHost):\(kDefaultUdpPort)"
    @Published public private(set) var rttMilliseconds: Double = 0.0
    @Published public private(set) var packetsSent: UInt64 = 0
    @Published public private(set) var packetsReceived: UInt64 = 0
    @Published public private(set) var packetsLost: UInt64 = 0

    // Editable manual IP / Port fallback (defaults to 192.168.1.13:54321 per specification)
    @Published public var manualHost: String = kDefaultPcHost
    @Published public var manualPort: String = String(kDefaultUdpPort)
    @Published public var autoReconnectEnabled: Bool = true

    /// Callback invoked on the high-priority network queue whenever a `PcToPhone` (`0x01`) Opus packet arrives.
    public var onInboundPcAudioPacket: ((FramedPacket) -> Void)?

    /// Callback invoked when the PC sends a `ControlMessage` (such as `HandshakeAck`, `MuteState`, or `StreamConfig`).
    public var onControlMessage: ((ControlMessage) -> Void)?

    private let netQueue = DispatchQueue(label: "com.audiosync.ios.network", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pathMonitor: NWPathMonitor?
    private var keepaliveTimer: DispatchSourceTimer?

    private var currentTargetEndpoint: NWEndpoint?
    private var isUserInitiatedDisconnect: Bool = false
    @usableFromInline internal let startTimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds

    private var outboundMicSeq: UInt16 = 0
    private var pingSeq: UInt16 = 0
    private var lastInboundPcSeq: UInt16?
    private var lastPacketReceivedAt: DispatchTime = .now()

    // Internal counters to prevent saturating the main thread with 100-200 dispatches/sec
    private var internalPacketsSent: UInt64 = 0
    private var internalPacketsReceived: UInt64 = 0
    private var internalPacketsLost: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?

    public init() {
        setupPathMonitor()
        setupLifecycleObservers()
    }

    deinit {
        stopAll()
    }

    // MARK: - Monotonic Microsecond Timestamp (Matches Rust `start_instant.elapsed().as_micros() & 0xFFFF_FFFF`)

    @inlinable
    public func currentTimestampMicros() -> UInt32 {
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- startTimeNanoseconds
        let elapsedMicros = elapsedNanos / 1_000
        return UInt32(truncatingIfNeeded: elapsedMicros)
    }

    // MARK: - mDNS / Bonjour Discovery (`_audiosync._udp.local.`)

    public func startDiscovery() {
        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopBrowserOnQueue()

            let params = NWParameters()
            params.includePeerToPeer = true

            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: kMdnsServiceType,
                domain: kMdnsDomain
            )
            let nwBrowser = NWBrowser(for: descriptor, using: params)

            nwBrowser.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.publishStatus("Browsing mDNS (_audiosync._udp.local.)")
                case .failed(let error):
                    self.publishStatus("mDNS error (\(error.localizedDescription)); using \(self.manualHost):\(self.manualPort)")
                    // Restart browser after brief backoff
                    self.netQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.startDiscovery()
                    }
                default:
                    break
                }
            }

            nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                var hosts: [DiscoveredHost] = []

                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        var version = "1.0"
                        var rate = 48_000
                        if case let .bonjour(txtRecord) = result.metadata {
                            if let v = txtRecord["version"] { version = v }
                            if let r = txtRecord["sample_rate"], let parsed = Int(r) { rate = parsed }
                        }
                        let id = "\(name).\(type).\(domain)"
                        hosts.append(
                            DiscoveredHost(
                                id: id,
                                name: name,
                                endpoint: result.endpoint,
                                version: version,
                                sampleRate: rate
                            )
                        )
                    }
                }

                DispatchQueue.main.async {
                    self.discoveredHosts = hosts
                }

                // Auto-connect to the first discovered AudioSync PC if not already connected
                if !self.isConnected,
                   !self.isUserInitiatedDisconnect,
                   let firstHost = hosts.first {
                    self.connectToEndpointOnQueue(firstHost.endpoint, displayName: firstHost.name)
                }
            }

            nwBrowser.start(queue: self.netQueue)
            self.browser = nwBrowser
        }
    }

    // MARK: - Connection Management (mDNS Endpoint or Manual IP 192.168.1.13:54321)

    /// Connects to a discovered Bonjour `DiscoveredHost`.
    public func connect(to host: DiscoveredHost) {
        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.isUserInitiatedDisconnect = false
            self.connectToEndpointOnQueue(host.endpoint, displayName: host.name)
        }
    }

    /// Connects directly to the configured manual IP and UDP port (default `192.168.1.13:54321`).
    public func connectToManualEndpoint() {
        let hostStr = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portVal = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? kDefaultUdpPort

        guard !hostStr.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: portVal) else {
            publishStatus("Invalid IP or UDP Port")
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(hostStr),
            port: nwPort
        )

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.isUserInitiatedDisconnect = false
            self.connectToEndpointOnQueue(endpoint, displayName: "\(hostStr):\(portVal)")
        }
    }

    public func disconnect() {
        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.isUserInitiatedDisconnect = true
            self.reconnectWorkItem?.cancel()
            self.sendControlOnQueue(.disconnect(reason: "User disconnected"))
            self.teardownConnectionOnQueue()
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectionStateText = "Disconnected"
            }
        }
    }

    public func stopAll() {
        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem?.cancel()
            self.stopBrowserOnQueue()
            self.teardownConnectionOnQueue()
            self.pathMonitor?.cancel()
        }
    }

    private func connectToEndpointOnQueue(_ endpoint: NWEndpoint, displayName: String) {
        reconnectWorkItem?.cancel()
        teardownConnectionOnQueue()

        currentTargetEndpoint = endpoint

        let udpOptions = NWProtocolUDP.Options()
        let params = NWParameters(dtls: nil, udp: udpOptions)
        // Interactive Voice QoS (DSCP EF) minimizes Wi-Fi WMM queueing delay
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        DispatchQueue.main.async {
            self.activeEndpointDescription = displayName
            self.connectionStateText = "Connecting to \(displayName)..."
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.lastInboundPcSeq = nil
                DispatchQueue.main.async {
                    self.connectionStateText = "Socket ready, reaching \(displayName)..."
                }
                self.startReceiveLoopOnQueue(for: conn)
                self.startKeepaliveTimerOnQueue()
                self.sendHandshakeOnQueue()
                self.sendPingOnQueue()

            case .waiting(let error):
                self.publishStatus("Waiting for network (\(error.localizedDescription))...")
                self.scheduleReconnectOnQueue(delay: 1.5)

            case .failed(let error):
                self.publishStatus("Socket failed (\(error.localizedDescription)) — recovering...")
                DispatchQueue.main.async {
                    self.isConnected = false
                }
                self.scheduleReconnectOnQueue(delay: 1.0)

            case .cancelled:
                DispatchQueue.main.async {
                    self.isConnected = false
                }

            default:
                break
            }
        }

        conn.start(queue: netQueue)
    }

    private func teardownConnectionOnQueue() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
        }
    }

    private func stopBrowserOnQueue() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func scheduleReconnectOnQueue(delay: TimeInterval) {
        guard autoReconnectEnabled, !isUserInitiatedDisconnect else { return }
        reconnectWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.autoReconnectEnabled,
                  !self.isUserInitiatedDisconnect else { return }

            if let target = self.currentTargetEndpoint {
                self.connectToEndpointOnQueue(target, displayName: self.activeEndpointDescription)
            } else {
                // Fallback to manual IP (192.168.1.13:54321) while mDNS continues browsing
                let portVal = UInt16(self.manualPort) ?? kDefaultUdpPort
                if let nwPort = NWEndpoint.Port(rawValue: portVal) {
                    let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(self.manualHost), port: nwPort)
                    self.connectToEndpointOnQueue(ep, displayName: "\(self.manualHost):\(portVal)")
                }
            }
        }
        reconnectWorkItem = item
        netQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Non-Blocking UDP Receive Loop

    private func startReceiveLoopOnQueue(for conn: NWConnection) {
        conn.receiveMessage { [weak self] content, _, _, error in
            guard let self = self else { return }

            if let data = content, data.count >= kPacketHeaderSize,
               let packet = FramedPacket.decode(data) {
                self.handleInboundPacketOnQueue(packet)
            }

            if let error = error {
                if case .posix(let code) = error, code == .ECANCELED {
                    return
                }
                // Transient UDP error (e.g. ICMP port unreachable while PC app starts)
                self.scheduleReconnectOnQueue(delay: 1.0)
                return
            }

            if self.connection === conn {
                self.startReceiveLoopOnQueue(for: conn)
            }
        }
    }

    private func handleInboundPacketOnQueue(_ packet: FramedPacket) {
        lastPacketReceivedAt = .now()
        internalPacketsReceived &+= 1
        if !isConnected {
            DispatchQueue.main.async {
                self.isConnected = true
            }
        }

        switch packet.header.packetType {
        case .audioOpus:
            guard packet.header.streamId == .pcToPhone else { return }
            if let prevSeq = lastInboundPcSeq {
                let diff = sequenceDiff(packet.header.sequenceNum, prevSeq)
                if diff > 1 {
                    let lostCount = UInt64(diff - 1)
                    internalPacketsLost &+= lostCount
                }
            }
            lastInboundPcSeq = packet.header.sequenceNum
            onInboundPcAudioPacket?(packet)

        case .ping:
            // Immediately echo Pong with identical sequenceNum & timestamp
            let pong = FramedPacket.pong(
                sequenceNum: packet.header.sequenceNum,
                timestamp: packet.header.timestamp
            )
            sendRawFramedPacketOnQueue(pong)

        case .pong:
            let nowMicros = currentTimestampMicros()
            let rttMicros = nowMicros &- packet.header.timestamp
            let rttMs = Double(rttMicros) / 1_000.0
            if rttMs >= 0.0 && rttMs < 5_000.0 {
                DispatchQueue.main.async {
                    self.rttMilliseconds = rttMs
                }
            }

        case .control:
            guard let msg = ControlMessage.fromJSONData(packet.payload) else { return }
            if case let .handshakeAck(serverName, _, _, _) = msg {
                DispatchQueue.main.async {
                    self.connectedServerName = serverName
                    self.connectionStateText = "Connected to \(serverName)"
                }
            }
            onControlMessage?(msg)
        }
    }

    // MARK: - Outbound Audio & Control Transmission

    /// Sends an encoded 48kHz mono Opus microphone frame to the Windows PC (`StreamId.phoneToPc = 0x02`).
    public func sendMicrophoneOpusFrame(_ opusData: Data) {
        netQueue.async { [weak self] in
            guard let self = self else { return }
            let seq = self.outboundMicSeq
            self.outboundMicSeq &+= 1
            let ts = self.currentTimestampMicros()

            let pkt = FramedPacket(
                packetType: .audioOpus,
                streamId: .phoneToPc,
                sequenceNum: seq,
                timestamp: ts,
                payload: opusData
            )
            self.sendRawFramedPacketOnQueue(pkt)
        }
    }

    /// Sends a control message (e.g. MuteState or StreamConfig) to the Windows PC.
    public func sendControlMessage(_ message: ControlMessage) {
        netQueue.async { [weak self] in
            self?.sendControlOnQueue(message)
        }
    }

    private func sendHandshakeOnQueue() {
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = "iPhone 13"
        #endif
        sendControlOnQueue(
            .handshake(
                deviceName: deviceName,
                protocolVersion: 1,
                sampleRate: 48_000,
                channels: 1
            )
        )
    }

    private func sendControlOnQueue(_ message: ControlMessage) {
        guard let payload = message.toJSONData() else { return }
        let pkt = FramedPacket(
            packetType: .control,
            streamId: .control,
            sequenceNum: 0,
            timestamp: currentTimestampMicros(),
            payload: payload
        )
        sendRawFramedPacketOnQueue(pkt)
    }

    private func sendPingOnQueue() {
        let seq = pingSeq
        pingSeq &+= 1
        let ping = FramedPacket.ping(sequenceNum: seq, timestamp: currentTimestampMicros())
        sendRawFramedPacketOnQueue(ping)
    }

    private func sendRawFramedPacketOnQueue(_ packet: FramedPacket) {
        guard let conn = connection else { return }
        let wireData = packet.encode()
        conn.send(content: wireData, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error == nil {
                self.internalPacketsSent &+= 1
            }
        })
    }

    // MARK: - Keepalive & Background/Foreground Socket Recovery

    private func startKeepaliveTimerOnQueue() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.sendPingOnQueue()

            // Synchronize telemetry counters once per second on MainQueue
            let sent = self.internalPacketsSent
            let received = self.internalPacketsReceived
            let lost = self.internalPacketsLost
            DispatchQueue.main.async {
                self.packetsSent = sent
                self.packetsReceived = received
                self.packetsLost = lost
            }

            let elapsedSinceRecv = Double(
                DispatchTime.now().uptimeNanoseconds &- self.lastPacketReceivedAt.uptimeNanoseconds
            ) / 1_000_000_000.0

            if elapsedSinceRecv > 3.0 {
                DispatchQueue.main.async {
                    if self.isConnected {
                        self.isConnected = false
                        self.connectionStateText = "Searching for PC..."
                    }
                }
                // Re-send handshake and trigger socket recovery if peer stopped responding
                self.sendHandshakeOnQueue()
                if elapsedSinceRecv > 8.0 {
                    self.scheduleReconnectOnQueue(delay: 0.5)
                }
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func setupPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                self.startDiscovery()
                if !self.isUserInitiatedDisconnect && !self.isConnected {
                    self.scheduleReconnectOnQueue(delay: 0.5)
                }
            } else {
                self.publishStatus("Waiting for Wi-Fi connection...")
            }
        }
        monitor.start(queue: netQueue)
        self.pathMonitor = monitor
    }

    private func setupLifecycleObservers() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            // Keep UDP socket alive in background (UIBackgroundModes: audio + voip)
            self.netQueue.async {
                self.sendPingOnQueue()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.netQueue.async {
                // Verify socket health upon returning to foreground; recover immediately if stale
                let staleSeconds = Double(
                    DispatchTime.now().uptimeNanoseconds &- self.lastPacketReceivedAt.uptimeNanoseconds
                ) / 1_000_000_000.0

                if !self.isUserInitiatedDisconnect && (!self.isConnected || staleSeconds > 4.0) {
                    self.startDiscovery()
                    self.scheduleReconnectOnQueue(delay: 0.1)
                } else {
                    self.sendHandshakeOnQueue()
                    self.sendPingOnQueue()
                }
            }
        }
        #endif
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async {
            self.connectionStateText = message
        }
    }
}
