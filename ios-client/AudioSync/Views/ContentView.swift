import AVKit
import SwiftUI

// MARK: - Native iOS System AirPlay / Bluetooth Route Picker Wrapper

struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.systemCyan
        picker.activeTintColor = UIColor.systemPurple
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 24-Segment Animated LED VU Meter View

struct AnimatedVuMeterView: View {
    let title: String
    let subtitle: String
    let peak: Float
    let rms: Float
    let isMuted: Bool
    let accentColor: Color
    private let segmentCount: Int = 24

    private var effectivePeak: Float {
        isMuted ? 0.0 : min(max(peak, 0.0), 1.2)
    }

    private var effectiveRms: Float {
        isMuted ? 0.0 : min(max(rms, 0.0), 1.0)
    }

    private var dbString: String {
        if isMuted { return "MUTED" }
        guard effectivePeak > 0.0001 else { return "-∞ dB" }
        return String(format: "%+.1f dB", 20.0 * log10(effectivePeak))
    }

    private func segmentColor(for index: Int) -> Color {
        let ratio = Double(index) / Double(segmentCount)
        if ratio > 0.86 {
            return Color(red: 244 / 255, green: 63 / 255, blue: 94 / 255) // Rose clip zone
        } else if ratio > 0.70 {
            return Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255) // Amber headroom zone
        }
        return accentColor
    }

    var body: some View {
        let activePeakSegments = Int((min(effectivePeak, 1.0) * Float(segmentCount)).rounded())
        let activeRmsSegments = Int((effectiveRms * Float(segmentCount)).rounded())

        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text("(\(subtitle))")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.5))

                Spacer()

                Text(dbString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(isMuted ? .red : accentColor)
            }

            HStack(spacing: 3) {
                ForEach(0..<segmentCount, id: \.self) { idx in
                    let isPeakLit = !isMuted && idx < activePeakSegments
                    let isRmsLit = !isMuted && idx < activeRmsSegments

                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(isPeakLit ? segmentColor(for: idx) : Color.white.opacity(0.07))
                        .opacity(isRmsLit ? 1.0 : (isPeakLit ? 0.82 : 0.38))
                        .frame(height: 12)
                }
            }
            .padding(5)
            .background(Color.black.opacity(0.45))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
    }
}

// MARK: - Main ContentView

struct ContentView: View {
    @ObservedObject var networkClient: NetworkClient
    @ObservedObject var audioManager: AudioEngineManager

    /// Continuous transmission is the inverse of `pushToTalkEnabled`.
    private var continuousTransmissionBinding: Binding<Bool> {
        Binding<Bool>(
            get: { !audioManager.pushToTalkEnabled },
            set: { continuous in
                audioManager.pushToTalkEnabled = !continuous
                if continuous {
                    audioManager.pushToTalkActive = false
                }
            }
        )
    }

    private var packetLossPercentage: Double {
        let total = networkClient.packetsReceived + networkClient.packetsLost
        guard total > 0 else { return 0.0 }
        return (Double(networkClient.packetsLost) / Double(total)) * 100.0
    }

    var body: some View {
        ZStack {
            // Pitch black base canvas (#040508)
            Color(red: 4 / 255, green: 5 / 255, blue: 8 / 255)
                .ignoresSafeArea()

            // Ambient lighting waves matching desktop Stitch Dark Glassmorphism
            Circle()
                .fill(Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255).opacity(0.24))
                .frame(width: 340, height: 340)
                .blur(radius: 85)
                .offset(x: -110, y: -270)

            Circle()
                .fill(Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255).opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: 130, y: 200)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    headerBar
                    liveConnectionStatusCard
                    audioRoutePickerCard
                    dualVuMetersCard
                    transmissionAndMuteControlsCard
                    latencyAndCodecTuningCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - 1. Top Header Bar

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("AudioSync Pro")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("iPhone 13")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }

                Text(audioManager.audioStatusMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.55))
            }

            Spacer()

            Button(action: {
                if audioManager.isEngineRunning {
                    audioManager.stop()
                } else {
                    audioManager.start()
                }
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(audioManager.isEngineRunning ? Color.black : Color.cyan)
                        .frame(width: 6, height: 6)
                    Text(audioManager.isEngineRunning ? "Engine Active" : "Start Engine")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(audioManager.isEngineRunning ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(audioManager.isEngineRunning ? Color.cyan : Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }

    // MARK: - 2. Live Connection Status Card (PC IP, State, RTT ms, Packet Loss Stats)

    private var liveConnectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(networkClient.isConnected ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                        .shadow(color: networkClient.isConnected ? .green : .orange, radius: 4)

                    Text(networkClient.isConnected ? "CONNECTED" : "DISCOVERING PC")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(networkClient.isConnected ? .green : .orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                Spacer()

                // Real-time RTT Latency Pill
                HStack(spacing: 5) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                    Text(String(format: "%.1f ms RTT", networkClient.rttMilliseconds))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.cyan.opacity(0.12))
                .clipShape(Capsule())
            }

            Text(networkClient.connectionStateText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
                .lineLimit(1)

            // 4-Column Telemetry Grid: PC IP, UDP Port, Packets TX/RX, Packet Loss
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                telemetryTile(
                    label: "PC IP ADDRESS",
                    value: "\(networkClient.manualHost):\(networkClient.manualPort)"
                )
                telemetryTile(
                    label: "RTT LATENCY",
                    value: String(format: "%.1f ms", networkClient.rttMilliseconds)
                )
                telemetryTile(
                    label: "PACKETS TX / RX",
                    value: "\(networkClient.packetsSent) / \(networkClient.packetsReceived)"
                )
                telemetryTile(
                    label: "PACKET LOSS (PLC)",
                    value: String(format: "%llu (%.1f%%)", networkClient.packetsLost, packetLossPercentage),
                    highlightWarning: networkClient.packetsLost > 0
                )
            }

            // Discovered mDNS Bonjour Hosts (`_audiosync._udp.local.`)
            if !networkClient.discoveredHosts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUTO-DISCOVERED ON WI-FI (_audiosync._udp.local.)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.45))

                    ForEach(networkClient.discoveredHosts) { host in
                        Button(action: {
                            networkClient.connect(to: host)
                        }) {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundColor(.cyan)
                                Text(host.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Spacer()
                                Text("Connect")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.cyan)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)
                        }
                    }
                }
            }

            // Manual IP & Port Entry (Defaults to 192.168.1.13:54321)
            HStack(spacing: 8) {
                TextField("192.168.1.13", text: $networkClient.manualHost)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(12)
                    .keyboardType(.numbersAndPunctuation)

                TextField("54321", text: $networkClient.manualPort)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 74)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(12)
                    .keyboardType(.numberPad)

                Button(action: {
                    if networkClient.isConnected {
                        networkClient.disconnect()
                    } else {
                        networkClient.connectToManualEndpoint()
                    }
                }) {
                    Text(networkClient.isConnected ? "Disconnect" : "Pair PC")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(networkClient.isConnected ? Color.orange : Color.cyan)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(18)
        .background(glassBackground)
    }

    // MARK: - 3. Audio Route Picker Card (Speaker / Earpiece / Bluetooth Headset)

    private var audioRoutePickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "airpodspro")
                    .foregroundColor(.cyan)
                Text("Audio Output Route")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                SystemAudioRoutePicker()
                    .frame(width: 28, height: 28)
            }

            HStack(spacing: 8) {
                ForEach(AudioOutputRoute.allCases) { route in
                    let isSelected = (audioManager.selectedOutputRoute == route)
                    let isAvailable = (route != .bluetooth || audioManager.isBluetoothConnected)

                    Button(action: {
                        guard isAvailable else { return }
                        audioManager.selectedOutputRoute = route
                    }) {
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: iconName(for: route))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(route.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            if route == .bluetooth && !audioManager.isBluetoothConnected {
                                Text("No Device")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color.white.opacity(0.4))
                            }
                        }
                        .foregroundColor(
                            !isAvailable
                                ? Color.white.opacity(0.35)
                                : (isSelected ? .black : .white)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, route == .bluetooth && !audioManager.isBluetoothConnected ? 7 : 10)
                        .background(
                            !isAvailable
                                ? Color.white.opacity(0.03)
                                : (isSelected ? Color.cyan : Color.white.opacity(0.07))
                        )
                        .clipShape(Capsule())
                    }
                    .disabled(!isAvailable)
                }
            }
        }
        .padding(18)
        .background(glassBackground)
    }

    // MARK: - 4. Dual Animated VU Meters Card (Incoming PC Audio & Outgoing Mic Level)

    private var dualVuMetersCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("LIVE FULL-DUPLEX AUDIO LEVELS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.5))
                Spacer()
                Text("48 kHz PCM (5ms)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            // Incoming PC Audio VU Meter
            AnimatedVuMeterView(
                title: "Incoming PC Audio",
                subtitle: "Stereo Loopback",
                peak: audioManager.pcPeakLevel,
                rms: audioManager.pcRmsLevel,
                isMuted: audioManager.isSpeakerMuted || !audioManager.pcToPhoneEnabled,
                accentColor: .cyan
            )

            // Outgoing iPhone Mic VU Meter
            AnimatedVuMeterView(
                title: "Outgoing iPhone Mic",
                subtitle: "Mono → VB-CABLE",
                peak: audioManager.micPeakLevel,
                rms: audioManager.micRmsLevel,
                isMuted: audioManager.isMicMuted
                    || !audioManager.phoneToPcEnabled
                    || (audioManager.pushToTalkEnabled && !audioManager.pushToTalkActive),
                accentColor: .purple
            )
        }
        .padding(18)
        .background(glassBackground)
    }

    // MARK: - 5. Push-to-Talk, Continuous Transmission Toggle & Mute Buttons Card

    private var transmissionAndMuteControlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Stream Direction Toggles
            HStack(spacing: 12) {
                Toggle("PC → iPhone", isOn: $audioManager.pcToPhoneEnabled)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .tint(.cyan)

                Toggle("iPhone Mic → PC", isOn: $audioManager.phoneToPcEnabled)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .tint(.purple)
            }

            Divider().background(Color.white.opacity(0.1))

            // Continuous Transmission Toggle vs Push-to-Talk Mode
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continuous Mic Transmission")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(
                        audioManager.pushToTalkEnabled
                            ? "Push-to-Talk Mode active — hold button below to transmit"
                            : "Hands-free continuous streaming (works when screen is locked)"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.5))
                }
                Spacer()
                Toggle("", isOn: continuousTransmissionBinding)
                    .labelsHidden()
                    .tint(.purple)
            }

            // Large Tactile Push-to-Talk Hold Button
            HStack(spacing: 10) {
                Image(systemName: audioManager.pushToTalkActive ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                Text(
                    audioManager.pushToTalkEnabled
                        ? (audioManager.pushToTalkActive ? "TRANSMITTING VOICE (PTT ACTIVE)" : "HOLD TO TALK (PUSH-TO-TALK)")
                        : "CONTINUOUS MIC ACTIVE (TAP TO HOLD PTT)"
                )
                .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                audioManager.pushToTalkActive
                    ? Color.purple
                    : Color.purple.opacity(audioManager.pushToTalkEnabled ? 0.32 : 0.16)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        audioManager.pushToTalkActive ? Color.white.opacity(0.6) : Color.purple.opacity(0.45),
                        lineWidth: 1.5
                    )
            )
            .scaleEffect(audioManager.pushToTalkActive ? 0.97 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: audioManager.pushToTalkActive)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !audioManager.pushToTalkActive {
                            audioManager.pushToTalkActive = true
                        }
                    }
                    .onEnded { _ in
                        audioManager.pushToTalkActive = false
                    }
            )

            // Dual Mute Buttons (Mic Mute & PC Audio Mute)
            HStack(spacing: 10) {
                Button(action: {
                    audioManager.isMicMuted.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: audioManager.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        Text(audioManager.isMicMuted ? "Mic Muted" : "Mute Mic")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(audioManager.isMicMuted ? Color.red.opacity(0.55) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }

                Button(action: {
                    audioManager.isSpeakerMuted.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: audioManager.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        Text(audioManager.isSpeakerMuted ? "PC Muted" : "Mute PC Audio")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(audioManager.isSpeakerMuted ? Color.red.opacity(0.55) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(18)
        .background(glassBackground)
    }

    // MARK: - 6. Buffer Latency Selector (10ms / 20ms), Volume, Gain & RNNoise Card

    private var latencyAndCodecTuningCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BUFFER LATENCY & AUDIO DSP")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.white.opacity(0.5))

            // 10ms / 20ms Buffer Latency Selector
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Opus Frame Buffer Latency")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(audioManager.frameDurationMs) ms (\(audioManager.frameDurationMs == 10 ? "480" : "960") samples)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                }

                HStack(spacing: 8) {
                    latencyOptionButton(ms: 10, label: "10 ms (Ultra-Low Latency)")
                    latencyOptionButton(ms: 20, label: "20 ms (High Stability)")
                }
            }

            // PC Playback Volume Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Incoming PC Audio Volume")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.75))
                    Spacer()
                    Text("\(Int(audioManager.speakerVolume * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                Slider(value: $audioManager.speakerVolume, in: 0.0...1.5, step: 0.05)
                    .tint(.cyan)
            }

            // Outgoing Mic Gain Boost Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Microphone Gain Boost")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.75))
                    Spacer()
                    Text(String(format: "%+.1f dB", audioManager.micGainDb))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.purple)
                }
                Slider(value: $audioManager.micGainDb, in: -12.0...18.0, step: 0.5)
                    .tint(.purple)
            }

            // RNNoise AI Noise Suppression Toggle & Opus Bitrate Picker
            HStack {
                Text("PC AI Noise Suppression (RNNoise)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $audioManager.rnnoiseEnabledOnPc)
                    .labelsHidden()
                    .tint(.purple)
            }

            HStack {
                Text("Opus Bitrate")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Picker("Bitrate", selection: $audioManager.opusBitrateBps) {
                    Text("32k").tag(Int32(32_000))
                    Text("64k").tag(Int32(64_000))
                    Text("96k").tag(Int32(96_000))
                    Text("128k").tag(Int32(128_000))
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        .padding(18)
        .background(glassBackground)
    }

    // MARK: - Subviews & Styling Helpers

    private func latencyOptionButton(ms: Int, label: String) -> some View {
        let isSelected = (audioManager.frameDurationMs == ms)
        return Button(action: {
            audioManager.frameDurationMs = ms
        }) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isSelected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.cyan : Color.white.opacity(0.07))
                .clipShape(Capsule())
        }
    }

    private func telemetryTile(label: String, value: String, highlightWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(highlightWarning ? .orange : .white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func iconName(for route: AudioOutputRoute) -> String {
        switch route {
        case .speaker:   return "speaker.wave.3.fill"
        case .earpiece:  return "iphone"
        case .bluetooth: return "airpodspro"
        }
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color(red: 23 / 255, green: 27 / 255, blue: 43 / 255).opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 10)
    }
}
