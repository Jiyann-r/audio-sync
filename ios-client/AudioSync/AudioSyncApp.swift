import SwiftUI

@main
struct AudioSyncApp: App {
    @StateObject private var networkClient: NetworkClient
    @StateObject private var audioManager: AudioEngineManager

    init() {
        let net = NetworkClient()
        let audio = AudioEngineManager(networkClient: net)
        _networkClient = StateObject(wrappedValue: net)
        _audioManager = StateObject(wrappedValue: audio)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                networkClient: networkClient,
                audioManager: audioManager
            )
            .preferredColorScheme(.dark)
            .onAppear {
                networkClient.startDiscovery()
                audioManager.start()
            }
        }
    }
}
