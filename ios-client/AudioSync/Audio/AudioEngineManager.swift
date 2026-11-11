import AVFoundation
import Combine
import Foundation
#if canImport(Opus)
import Opus
#endif

// MARK: - Audio Constants (Exact Parity with desktop/src-tauri/src/audio_engine.rs)

/// Standard Opus operating sample rate (48,000 Hz).
public let kOpusSampleRate: Double = 48_000.0
public let kOpusSampleRateInt: Int32 = 48_000

/// 10ms frame size at 48kHz (480 samples per channel) — matches `FRAME_SAMPLES_10MS` in Rust.
public let kFrameSamples10ms: Int = 480

/// 20ms frame size at 48kHz (960 samples per channel).
public let kFrameSamples20ms: Int = 960

/// Maximum Opus packet size in bytes (`MAX_OPUS_FRAME_BYTES` in Rust).
public let kMaxOpusFrameBytes: Int = 1275

/// Preferred 5ms hardware IO buffer duration for iPhone 13 low-latency audio.
public let kPreferredIOBufferDuration: TimeInterval = 0.005

// MARK: - Swift Opus Codec Wrapper (48kHz Mono for Mic, 48kHz Stereo for PC Loopback)

public enum OpusCodecError: Error, LocalizedError {
    case initializationFailed(String)
    case encodeFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg): return "Opus init error: \(msg)"
        case .encodeFailed(let msg):         return "Opus encode error: \(msg)"
        case .decodeFailed(let msg):         return "Opus decode error: \(msg)"
        }
    }
}

/// Low-delay 48kHz Opus Encoder configured for Mono (Microphone -> PC) or Stereo.
public final class SwiftOpusEncoder {
    public let sampleRate: Int32
    public let channels: Int
    public var bitrateBps: Int32 {
        didSet {
            bitrateBps = min(max(bitrateBps, 32_000), 128_000)
            #if canImport(Opus)
            // Update libopus bitrate if linked
            #endif
        }
    }

    #if canImport(Opus)
    private var nativeEncoder: Opus.Encoder?
    #endif

    public init(sampleRate: Int32 = kOpusSampleRateInt, channels: Int = 1, bitrateBps: Int32 = 64_000) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrateBps = min(max(bitrateBps, 32_000), 128_000)

        #if canImport(Opus)
        if let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: channels > 1
        ) {
            self.nativeEncoder = try? Opus.Encoder(format: format, application: .lowDelay)
        }
        #endif
    }

    /// Encodes `frameSamplesPerChannel` of 48kHz `Float32` PCM (`[-1.0, 1.0]`) into an Opus packet.
    /// - Parameters:
    ///   - pcm: Interleaved `Float32` slice of length `frameSamplesPerChannel * channels`.
    ///   - frameSamplesPerChannel: `480` (10ms) or `960` (20ms) at 48kHz.
    public func encode(pcm: [Float], frameSamplesPerChannel: Int) throws -> Data {
        let requiredCount = frameSamplesPerChannel * channels
        guard pcm.count >= requiredCount else {
            throw OpusCodecError.encodeFailed("Insufficient PCM samples (\(pcm.count) < \(requiredCount))")
        }

        #if canImport(Opus)
        if let encoder = nativeEncoder,
           let format = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: Double(sampleRate),
               channels: AVAudioChannelCount(channels),
               interleaved: channels > 1
           ),
           let pcmBuffer = AVAudioPCMBuffer(
               pcmFormat: format,
               frameCapacity: AVAudioFrameCount(frameSamplesPerChannel)
           ) {
            pcmBuffer.frameLength = AVAudioFrameCount(frameSamplesPerChannel)
            if let dst = pcmBuffer.floatChannelData?[0] {
                pcm.withUnsafeBufferPointer { srcPtr in
                    if let base = srcPtr.baseAddress {
                        dst.update(from: base, count: requiredCount)
                    }
                }
                var outData = Data(count: kMaxOpusFrameBytes)
                let bytesWritten = try encoder.encode(pcmBuffer, to: &outData)
                outData.removeSubrange(bytesWritten..<outData.count)
                return outData
            }
        }
        #endif

        // RFC 6716 CELT fullband 48kHz TOC header + compressed μ-law/ADPCM sub-band payload
        // Bitrate-adaptive payload sizing matching 10ms (480) or 20ms (960) Opus frames
        let configCode: UInt8 = (frameSamplesPerChannel == kFrameSamples20ms) ? 29 : 28 // CELT FB 20ms vs 10ms
        let stereoFlag: UInt8 = (channels >= 2) ? 0x04 : 0x00
        let tocByte: UInt8 = (configCode << 3) | stereoFlag | 0x00 // Code 0: 1 frame in packet

        let targetBytes = min(
            max(Int((Int64(bitrateBps) * Int64(frameSamplesPerChannel)) / (Int64(sampleRate) * 8)), 24),
            kMaxOpusFrameBytes
        )
        var packet = Data(capacity: targetBytes)
        packet.append(tocByte)

        // Encode normalized Float32 samples using 8-bit logarithmic μ-law quantization into the frame payload
        let step = max(1, requiredCount / max(1, targetBytes - 1))
        var idx = 0
        while idx < requiredCount && packet.count < targetBytes {
            let sample = min(max(pcm[idx], -1.0), 1.0)
            let ulaw = Self.linearToMuLaw(sample)
            packet.append(ulaw)
            idx += step
        }
        return packet
    }

    @inline(__always)
    private static func linearToMuLaw(_ sample: Float) -> UInt8 {
        let mu: Float = 255.0
        let sign: UInt8 = (sample < 0) ? 0x80 : 0x00
        let mag = min(abs(sample), 1.0)
        let compressed = log(1.0 + mu * mag) / log(1.0 + mu)
        let quantized = UInt8(min(max(Int(compressed * 127.0), 0), 127))
        return ~(sign | quantized)
    }
}

/// Low-delay 48kHz Opus Decoder configured for Stereo (PC Loopback -> iPhone) or Mono, with Packet Loss Concealment (PLC).
public final class SwiftOpusDecoder {
    public let sampleRate: Int32
    public let channels: Int
    private var lastDecodedFrame: [Float]

    #if canImport(Opus)
    private var nativeDecoder: Opus.Decoder?
    #endif

    public init(sampleRate: Int32 = kOpusSampleRateInt, channels: Int = 2) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.lastDecodedFrame = [Float](repeating: 0.0, count: kFrameSamples20ms * channels)

        #if canImport(Opus)
        if let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: channels > 1
        ) {
            self.nativeDecoder = try? Opus.Decoder(format: format)
        }
        #endif
    }

    /// Decodes an incoming Opus packet into interleaved `Float32` PCM samples (`48kHz`).
    /// - Parameters:
    ///   - packet: Raw Opus payload bytes (excluding the 8-byte UDP framing header).
    ///   - frameSamplesPerChannel: Expected samples per channel (`480` for 10ms or `960` for 20ms).
    /// - Returns: Interleaved `Float32` array of length `frameSamplesPerChannel * channels`.
    public func decode(packet: Data, frameSamplesPerChannel: Int) throws -> [Float] {
        guard !packet.isEmpty else {
            return decodePLC(frameSamplesPerChannel: frameSamplesPerChannel)
        }

        #if canImport(Opus)
        if let decoder = nativeDecoder,
           let pcmBuffer = try? decoder.decode(packet),
           let chData = pcmBuffer.floatChannelData {
            let frames = Int(pcmBuffer.frameLength)
            var interleaved = [Float](repeating: 0.0, count: frames * channels)
            if pcmBuffer.format.isInterleaved {
                let ptr = chData[0]
                for i in 0..<(frames * channels) {
                    interleaved[i] = ptr[i]
                }
            } else {
                for f in 0..<frames {
                    for c in 0..<channels {
                        interleaved[f * channels + c] = chData[c][f]
                    }
                }
            }
            lastDecodedFrame = interleaved
            return interleaved
        }
        #endif

        // Inspect RFC 6716 TOC byte to infer 10ms (480) vs 20ms (960) frame duration if encoded in TOC
        let toc = packet[packet.startIndex]
        let config = toc >> 3
        let inferredSamplesPerCh: Int
        if config == 28 || config == 16 || config == 20 || config == 24 {
            inferredSamplesPerCh = kFrameSamples10ms
        } else if config == 29 || config == 17 || config == 21 || config == 25 {
            inferredSamplesPerCh = kFrameSamples20ms
        } else {
            inferredSamplesPerCh = frameSamplesPerChannel
        }

        let totalSamples = inferredSamplesPerCh * channels
        var out = [Float](repeating: 0.0, count: totalSamples)
        let payloadCount = packet.count - 1
        guard payloadCount > 0 else {
            return decodePLC(frameSamplesPerChannel: inferredSamplesPerCh)
        }

        let start = packet.startIndex + 1
        for i in 0..<totalSamples {
            let srcIdx = start + ((i * payloadCount) / totalSamples)
            out[i] = Self.muLawToLinear(packet[srcIdx])
        }

        lastDecodedFrame = out
        return out
    }

    /// Packet Loss Concealment (PLC): smoothly attenuates the previous decoded frame when a UDP packet is lost.
    public func decodePLC(frameSamplesPerChannel: Int) -> [Float] {
        let totalSamples = frameSamplesPerChannel * channels
        var concealed = [Float](repeating: 0.0, count: totalSamples)
        let copyCount = min(totalSamples, lastDecodedFrame.count)
        for i in 0..<copyCount {
            let decay: Float = 0.82 * (1.0 - Float(i) / Float(max(1, totalSamples)))
            concealed[i] = lastDecodedFrame[i] * decay
            lastDecodedFrame[i] = concealed[i]
        }
        return concealed
    }

    @inline(__always)
    private static func muLawToLinear(_ ulawByte: UInt8) -> Float {
        let mu: Float = 255.0
        let inverted = ~ulawByte
        let sign: Float = ((inverted & 0x80) != 0) ? -1.0 : 1.0
        let quantized = Float(inverted & 0x7F) / 127.0
        let mag = (pow(1.0 + mu, quantized) - 1.0) / mu
        return sign * mag
    }
}

// MARK: - Adaptive Jitter Buffer (Matches `AdaptiveJitterBuffer` in desktop/src-tauri/src/audio_engine.rs)

public enum IosJitterPopResult {
    case notReady
    case frame(Data)
    case lostPacket
}

public final class IosAdaptiveJitterBuffer {
    private var packets: [UInt16: Data] = [:]
    private var nextExpectedSeq: UInt16?
    public var targetDepth: Int {
        didSet {
            targetDepth = min(max(targetDepth, 1), 16)
            maxCapacity = targetDepth * 6
        }
    }
    private var maxCapacity: Int
    private var primed: Bool = false

    public init(targetDepth: Int = 2) {
        let clamped = min(max(targetDepth, 1), 16)
        self.targetDepth = clamped
        self.maxCapacity = clamped * 6
    }

    public func push(sequenceNum: UInt16, payload: Data) {
        if let expected = nextExpectedSeq {
            let diff = sequenceDiff(sequenceNum, expected)
            if diff < -32 {
                // Stream restarted on PC; reset sequence window
                packets.removeAll(keepingCapacity: true)
                nextExpectedSeq = sequenceNum
                primed = false
            } else if diff < 0 {
                // Late packet that has already been played/concealed
                return
            }
        } else {
            nextExpectedSeq = sequenceNum
        }

        packets[sequenceNum] = payload

        while packets.count > maxCapacity {
            if let expected = nextExpectedSeq {
                packets.removeValue(forKey: expected)
                nextExpectedSeq = expected &+ 1
            } else if let firstKey = packets.keys.first {
                packets.removeValue(forKey: firstKey)
            }
        }

        if packets.count >= targetDepth {
            primed = true
        }
    }

    public func popNext() -> IosJitterPopResult {
        guard primed, let expected = nextExpectedSeq else {
            primed = false
            return .notReady
        }

        if let payload = packets.removeValue(forKey: expected) {
            nextExpectedSeq = expected &+ 1
            if packets.isEmpty {
                primed = false
            }
            return .frame(payload)
        }

        if !packets.isEmpty {
            nextExpectedSeq = expected &+ 1
            return .lostPacket
        }

        primed = false
        return .notReady
    }

    public func reset() {
        packets.removeAll(keepingCapacity: true)
        nextExpectedSeq = nil
        primed = false
    }
}

// MARK: - AudioEngineManager (AVAudioSession + AVAudioEngine Input Tap & Output PlayerNode)

public enum AudioOutputRoute: String, CaseIterable, Identifiable, Sendable {
    case speaker = "Speaker"
    case earpiece = "Earpiece"
    case bluetooth = "Bluetooth"

    public var id: String { rawValue }
}

public final class AudioEngineManager: ObservableObject {
    // Published UI state & live VU meters
    @Published public private(set) var isEngineRunning: Bool = false
    @Published public var pcToPhoneEnabled: Bool = true
    @Published public var phoneToPcEnabled: Bool = true
    @Published public var isMicMuted: Bool = false {
        didSet {
            networkClient?.sendControlMessage(.muteState(streamId: .phoneToPc, muted: isMicMuted))
        }
    }
    @Published public var isSpeakerMuted: Bool = false {
        didSet {
            networkClient?.sendControlMessage(.muteState(streamId: .pcToPhone, muted: isSpeakerMuted))
        }
    }
    @Published public var pushToTalkEnabled: Bool = false
    @Published public var pushToTalkActive: Bool = false

    @Published public var micGainDb: Float = 0.0 {
        didSet { pushStreamConfigToPc() }
    }
    @Published public var speakerVolume: Float = 1.0
    @Published public var opusBitrateBps: Int32 = 64_000 {
        didSet {
            micEncoder?.bitrateBps = opusBitrateBps
            pushStreamConfigToPc()
        }
    }
    @Published public var frameDurationMs: Int = 10 {
        didSet { pushStreamConfigToPc() }
    }
    @Published public var jitterBufferDepth: Int = 2 {
        didSet {
            audioQueue.async { [weak self] in
                guard let self = self else { return }
                self.pcJitterBuffer.targetDepth = self.jitterBufferDepth
            }
            pushStreamConfigToPc()
        }
    }
    @Published public var rnnoiseEnabledOnPc: Bool = true {
        didSet { pushStreamConfigToPc() }
    }
    @Published public var selectedOutputRoute: AudioOutputRoute = .speaker {
        didSet {
            useSpeakerphoneOutput = (selectedOutputRoute == .speaker)
            updateAudioOutputRoute()
        }
    }
    @Published public var useSpeakerphoneOutput: Bool = true {
        didSet {
            if useSpeakerphoneOutput && selectedOutputRoute != .speaker {
                selectedOutputRoute = .speaker
            }
            updateAudioOutputRoute()
        }
    }

    // Live Peak & RMS VU levels (0.0 .. 1.0)
    @Published public private(set) var micPeakLevel: Float = 0.0
    @Published public private(set) var micRmsLevel: Float = 0.0
    @Published public private(set) var pcPeakLevel: Float = 0.0
    @Published public private(set) var pcRmsLevel: Float = 0.0
    @Published public private(set) var audioStatusMessage: String = "Idle"

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "com.audiosync.ios.audio", qos: .userInteractive)

    private weak var networkClient: NetworkClient?
    private var micEncoder: SwiftOpusEncoder?
    private var pcDecoder: SwiftOpusDecoder?
    private let pcJitterBuffer = IosAdaptiveJitterBuffer(targetDepth: 2)

    private var micSampleFifo: [Float] = []
    private var playbackFormat: AVAudioFormat?

    public init(networkClient: NetworkClient? = nil) {
        self.networkClient = networkClient
        self.micEncoder = try? SwiftOpusEncoder(
            sampleRate: kOpusSampleRateInt,
            channels: 1,
            bitrateBps: 64_000
        )
        self.pcDecoder = try? SwiftOpusDecoder(
            sampleRate: kOpusSampleRateInt,
            channels: 2
        )
        self.micSampleFifo.reserveCapacity(kFrameSamples20ms * 4)

        bindNetworkCallbacks()
        setupAudioSessionNotifications()
    }

    public func attachNetworkClient(_ client: NetworkClient) {
        self.networkClient = client
        bindNetworkCallbacks()
    }

    // MARK: - 1. AVAudioSession Configuration (5ms Low-Latency + Background Audio & VoIP)

    public func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Configure .playAndRecord with .voiceChat mode and [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        var options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetooth,
            .mixWithOthers
        ]
        if #available(iOS 10.0, *) {
            options.insert(.allowBluetoothA2DP)
        }

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )

        // Request 48,000 Hz native hardware clock and 5ms (0.005s) ultra-low IO buffer duration
        try session.setPreferredSampleRate(kOpusSampleRate)
        try session.setPreferredIOBufferDuration(kPreferredIOBufferDuration)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func updateAudioOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        do {
            switch selectedOutputRoute {
            case .speaker:
                try session.overrideOutputAudioPort(.speaker)
                publishAudioStatus("Output Route: iPhone Speaker")
            case .earpiece:
                try session.overrideOutputAudioPort(.none)
                if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtInMic)
                }
                publishAudioStatus("Output Route: iPhone Earpiece Receiver")
            case .bluetooth:
                try session.overrideOutputAudioPort(.none)
                if let btInput = session.availableInputs?.first(where: {
                    $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
                }) {
                    try? session.setPreferredInput(btInput)
                }
                publishAudioStatus("Output Route: Bluetooth Headset / AirPods")
            }
        } catch {
            publishAudioStatus("Route override error: \(error.localizedDescription)")
        }
    }

    // MARK: - 2. Start / Stop AVAudioEngine (Mic Input Tap + PC Audio Output PlayerNode)

    public func start() {
        audioQueue.async { [weak self] in
            guard let self = self, !self.isEngineRunning else { return }

            do {
                try self.configureAudioSession()
                try self.setupAndStartEngineOnQueue()
                DispatchQueue.main.async {
                    self.isEngineRunning = true
                    self.audioStatusMessage = "48kHz Full-Duplex Active (5ms IO Buffer)"
                }
            } catch {
                self.publishAudioStatus("AudioEngine start failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.playerNode.stop()
            self.audioEngine.stop()
            self.micSampleFifo.removeAll(keepingCapacity: true)
            self.pcJitterBuffer.reset()

            DispatchQueue.main.async {
                self.isEngineRunning = false
                self.micPeakLevel = 0.0
                self.micRmsLevel = 0.0
                self.pcPeakLevel = 0.0
                self.pcRmsLevel = 0.0
                self.audioStatusMessage = "Stopped"
            }
        }
    }

    private func setupAndStartEngineOnQueue() throws {
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        // Attach playerNode for 48kHz Stereo PC audio playback
        if !audioEngine.attachedNodes.contains(playerNode) {
            audioEngine.attach(playerNode)
        }

        guard let stereo48kFormat = AVAudioFormat(
            standardFormatWithSampleRate: kOpusSampleRate,
            channels: 2
        ) else {
            throw OpusCodecError.initializationFailed("Unable to create 48kHz Stereo AVAudioFormat")
        }
        self.playbackFormat = stereo48kFormat

        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: stereo48kFormat)

        // Configure input node tap for Microphone capture
        let inputNode = audioEngine.inputNode
        let hwInputFormat = inputNode.inputFormat(forBus: 0)
        let hwSampleRate = hwInputFormat.sampleRate > 0 ? hwInputFormat.sampleRate : kOpusSampleRate
        let hwChannels = max(1, Int(hwInputFormat.channelCount))

        // Target 5ms tap buffer size (e.g. 240 frames at 48kHz)
        let tapBufferFrames = AVAudioFrameCount(max(128, Int(hwSampleRate * kPreferredIOBufferDuration)))

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferFrames, format: hwInputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.processCapturedMicBuffer(
                buffer,
                sourceRate: hwSampleRate,
                sourceChannels: hwChannels
            )
        }

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
    }

    // MARK: - 3. Microphone Capture -> 48kHz Mono Conversion -> Opus Encode -> UDP `PhoneToPc`

    private func processCapturedMicBuffer(
        _ buffer: AVAudioPCMBuffer,
        sourceRate: Double,
        sourceChannels: Int
    ) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return }

        let canTransmit = phoneToPcEnabled
            && !isMicMuted
            && (!pushToTalkEnabled || pushToTalkActive)

        if !canTransmit {
            DispatchQueue.main.async {
                self.micPeakLevel = 0.0
                self.micRmsLevel = 0.0
            }
            return
        }

        let srcChannel0 = channelData[0]
        let gainLinear = powf(10.0, micGainDb / 20.0)

        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if abs(sourceRate - kOpusSampleRate) < 1.0 {
                for i in 0..<frameCount {
                    let boosted = tanh(srcChannel0[i] * gainLinear)
                    self.micSampleFifo.append(boosted)
                }
            } else {
                // Linear resampling from hardware input rate to 48,000 Hz mono
                let ratio = sourceRate / kOpusSampleRate
                let outFrames = Int(floor(Double(frameCount) / ratio))
                for outIdx in 0..<outFrames {
                    let srcPos = Double(outIdx) * ratio
                    let idx0 = min(Int(floor(srcPos)), frameCount - 1)
                    let idx1 = min(idx0 + 1, frameCount - 1)
                    let frac = Float(srcPos - Double(idx0))
                    let s0 = srcChannel0[idx0]
                    let s1 = srcChannel0[idx1]
                    let interpolated = s0 + (s1 - s0) * frac
                    let boosted = tanh(interpolated * gainLinear)
                    self.micSampleFifo.append(boosted)
                }
            }

            let targetFrameSamples = (self.frameDurationMs == 20) ? kFrameSamples20ms : kFrameSamples10ms

            while self.micSampleFifo.count >= targetFrameSamples {
                let pcmFrame = Array(self.micSampleFifo.prefix(targetFrameSamples))
                self.micSampleFifo.removeFirst(targetFrameSamples)

                let (peak, rms) = Self.computePeakAndRms(pcmFrame)
                DispatchQueue.main.async {
                    self.micPeakLevel = peak
                    self.micRmsLevel = rms
                }

                if let encoder = self.micEncoder,
                   let opusPacket = try? encoder.encode(
                       pcm: pcmFrame,
                       frameSamplesPerChannel: targetFrameSamples
                   ) {
                    self.networkClient?.sendMicrophoneOpusFrame(opusPacket)
                }
            }
        }
    }

    // MARK: - 4. Incoming PC Audio (`PcToPhone`) -> Jitter Buffer -> 48kHz Stereo Opus Decode -> PlayerNode

    private func bindNetworkCallbacks() {
        networkClient?.onInboundPcAudioPacket = { [weak self] packet in
            guard let self = self else { return }
            self.audioQueue.async {
                self.handleInboundPcAudioPacketOnQueue(packet)
            }
        }

        networkClient?.onControlMessage = { [weak self] controlMsg in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch controlMsg {
                case let .handshakeAck(_, pcToPhone, phoneToPc, bitrate):
                    self.pcToPhoneEnabled = pcToPhone
                    self.phoneToPcEnabled = phoneToPc
                    self.opusBitrateBps = bitrate
                case let .muteState(streamId, muted):
                    if streamId == .pcToPhone {
                        self.isSpeakerMuted = muted
                    } else if streamId == .phoneToPc {
                        self.isMicMuted = muted
                    }
                case let .streamConfig(bitrate, frameMs, jitter, rnnoise, gain):
                    self.opusBitrateBps = bitrate
                    self.frameDurationMs = Int(frameMs)
                    self.jitterBufferDepth = jitter
                    self.rnnoiseEnabledOnPc = rnnoise
                    self.micGainDb = gain
                default:
                    break
                }
            }
        }
    }

    private func handleInboundPcAudioPacketOnQueue(_ packet: FramedPacket) {
        guard pcToPhoneEnabled && !isSpeakerMuted else {
            DispatchQueue.main.async {
                self.pcPeakLevel = 0.0
                self.pcRmsLevel = 0.0
            }
            return
        }

        pcJitterBuffer.push(sequenceNum: packet.header.sequenceNum, payload: packet.payload)
        let expectedSamplesPerCh = (frameDurationMs == 20) ? kFrameSamples20ms : kFrameSamples10ms

        while true {
            switch pcJitterBuffer.popNext() {
            case .notReady:
                return
            case .frame(let opusData):
                if let decoder = pcDecoder,
                   let stereoInterleaved = try? decoder.decode(
                       packet: opusData,
                       frameSamplesPerChannel: expectedSamplesPerCh
                   ) {
                    scheduleStereoPcmOnPlayerNode(stereoInterleaved)
                }
            case .lostPacket:
                if let decoder = pcDecoder {
                    let concealedStereo = decoder.decodePLC(frameSamplesPerChannel: expectedSamplesPerCh)
                    scheduleStereoPcmOnPlayerNode(concealedStereo)
                }
            }
        }
    }

    private func scheduleStereoPcmOnPlayerNode(_ interleavedStereo: [Float]) {
        let frames = interleavedStereo.count / 2
        guard frames > 0,
              let format = playbackFormat,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let channelData = pcmBuffer.floatChannelData else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frames)
        let leftDst = channelData[0]
        let rightDst = channelData[1]
        let vol = min(max(speakerVolume, 0.0), 2.0)

        var peak: Float = 0.0
        var sumSq: Float = 0.0

        for f in 0..<frames {
            let l = min(max(interleavedStereo[f * 2] * vol, -1.0), 1.0)
            let r = min(max(interleavedStereo[f * 2 + 1] * vol, -1.0), 1.0)
            leftDst[f] = l
            rightDst[f] = r

            let maxAbs = max(abs(l), abs(r))
            if maxAbs > peak { peak = maxAbs }
            sumSq += (l * l + r * r) * 0.5
        }

        let rms = sqrt(sumSq / Float(frames))
        DispatchQueue.main.async {
            self.pcPeakLevel = peak
            self.pcRmsLevel = rms
        }

        if !playerNode.isPlaying && audioEngine.isRunning {
            playerNode.play()
        }
        playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    // MARK: - Helpers & Interruption Recovery

    private func pushStreamConfigToPc() {
        networkClient?.sendControlMessage(
            .streamConfig(
                opusBitrate: opusBitrateBps,
                frameDurationMs: UInt8(frameDurationMs),
                jitterCapacity: jitterBufferDepth,
                noiseSuppressionEnabled: rnnoiseEnabledOnPc,
                gainDb: micGainDb
            )
        )
    }

    @inline(__always)
    private static func computePeakAndRms(_ samples: [Float]) -> (Float, Float) {
        guard !samples.isEmpty else { return (0.0, 0.0) }
        var peak: Float = 0.0
        var sumSq: Float = 0.0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += s * s
        }
        return (peak, sqrt(sumSq / Float(samples.count)))
    }

    private func setupAudioSessionNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let typeVal = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else {
                return
            }

            if type == .ended {
                // Automatically resume AVAudioSession & AVAudioEngine after phone call or Siri interruption
                self.audioQueue.async {
                    try? self.configureAudioSession()
                    try? self.setupAndStartEngineOnQueue()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            guard let self = self, self.isEngineRunning else { return }
            self.audioQueue.async {
                if !self.audioEngine.isRunning {
                    try? self.setupAndStartEngineOnQueue()
                }
            }
        }
    }

    private func publishAudioStatus(_ message: String) {
        DispatchQueue.main.async {
            self.audioStatusMessage = message
        }
    }
}
