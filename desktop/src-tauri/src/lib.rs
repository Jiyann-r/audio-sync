pub mod audio_engine;
pub mod diag;
pub mod network;
pub mod protocol;

use std::net::SocketAddr;
use std::sync::Arc;

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tauri::{Emitter, State};
use tokio::sync::mpsc;

use crate::audio_engine::{list_output_devices, AudioConfig, AudioEngine, AudioLevels};
use crate::network::{NetworkEngine, NetworkStatus, DEFAULT_UDP_PORT};

/// Shared application state managed by Tauri.
pub struct AppState {
    pub audio_config: Arc<Mutex<AudioConfig>>,
    pub audio_engine: Arc<AudioEngine>,
    pub network_engine: Arc<NetworkEngine>,
}

/// Complete telemetry & configuration snapshot returned to the UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSnapshot {
    pub config: AudioConfig,
    pub levels: AudioLevels,
    pub network: NetworkStatus,
    pub vbcable_device_name: String,
    pub vbcable_detected: bool,
}

#[tauri::command]
fn get_app_snapshot(state: State<'_, AppState>) -> AppSnapshot {
    let config = state.audio_config.lock().clone();
    let levels = state.audio_engine.telemetry.snapshot();
    let network = state.network_engine.state.snapshot();
    let (vbcable_device_name, vbcable_detected) = state.audio_engine.vbcable_status();

    AppSnapshot {
        config,
        levels,
        network,
        vbcable_device_name,
        vbcable_detected,
    }
}

#[tauri::command]
fn update_audio_config(state: State<'_, AppState>, new_config: AudioConfig) -> AudioConfig {
    let mut cfg = state.audio_config.lock();
    *cfg = new_config.clone();
    new_config
}

#[tauri::command]
fn toggle_mic_mute(state: State<'_, AppState>) -> bool {
    let mut cfg = state.audio_config.lock();
    cfg.mic_muted = !cfg.mic_muted;
    cfg.mic_muted
}

#[tauri::command]
fn toggle_pc_mute(state: State<'_, AppState>) -> bool {
    let mut cfg = state.audio_config.lock();
    cfg.pc_muted = !cfg.pc_muted;
    cfg.pc_muted
}

#[tauri::command]
fn set_push_to_talk_active(state: State<'_, AppState>, active: bool) -> bool {
    let mut cfg = state.audio_config.lock();
    cfg.push_to_talk_active = active;
    cfg.push_to_talk_active
}

#[tauri::command]
fn set_manual_peer(state: State<'_, AppState>, ip_and_port: String) -> Result<String, String> {
    let addr: SocketAddr = ip_and_port
        .parse()
        .map_err(|e| format!("Invalid IP:Port address '{ip_and_port}': {e}"))?;
    state.network_engine.state.set_manual_peer(addr);
    Ok(addr.to_string())
}

#[tauri::command]
fn get_output_audio_devices() -> Vec<String> {
    list_output_devices()
}

/// Initializes global Windows hotkeys:
/// - `Ctrl+Shift+M`: Toggle Microphone Mute
/// - `Ctrl+Shift+Space`: Hold for Push-to-Talk
fn spawn_global_hotkey_listener(audio_config: Arc<Mutex<AudioConfig>>) {
    std::thread::Builder::new()
        .name("global-hotkey-listener".to_string())
        .spawn(move || {
            let Ok(manager) = GlobalHotKeyManager::new() else {
                log::warn!("Could not initialize GlobalHotKeyManager on this thread");
                return;
            };

            let mute_hotkey = HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::KeyM);
            let ptt_hotkey = HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Space);

            let _ = manager.register(mute_hotkey);
            let _ = manager.register(ptt_hotkey);

            let receiver = GlobalHotKeyEvent::receiver();
            while let Ok(event) = receiver.recv() {
                if event.id == mute_hotkey.id() && event.state == HotKeyState::Pressed {
                    let mut cfg = audio_config.lock();
                    cfg.mic_muted = !cfg.mic_muted;
                } else if event.id == ptt_hotkey.id() {
                    let mut cfg = audio_config.lock();
                    cfg.push_to_talk_active = event.state == HotKeyState::Pressed;
                }
            }
        })
        .ok();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let audio_config = Arc::new(Mutex::new(AudioConfig::default()));
    let audio_engine = Arc::new(AudioEngine::new(Arc::clone(&audio_config)));
    let network_engine = Arc::new(NetworkEngine::new(Arc::clone(&audio_config)));

    let app_state = AppState {
        audio_config: Arc::clone(&audio_config),
        audio_engine: Arc::clone(&audio_engine),
        network_engine: Arc::clone(&network_engine),
    };

    tauri::Builder::default()
        .manage(app_state)
        .setup(move |app| {
            diag::spawn_reporter();
            let (outbound_opus_tx, outbound_opus_rx) = mpsc::channel(256);
            let (inbound_mic_tx, inbound_mic_rx) = mpsc::channel(256);

            if let Err(err) = audio_engine.start(outbound_opus_tx, inbound_mic_rx) {
                log::error!("Failed to start AudioEngine: {err}");
            }

            let net_engine_for_spawn = Arc::clone(&network_engine);
            tauri::async_runtime::spawn(async move {
                if let Err(err) = net_engine_for_spawn
                    .start(DEFAULT_UDP_PORT, outbound_opus_rx, inbound_mic_tx)
                    .await
                {
                    log::error!("Failed to start NetworkEngine: {err}");
                }
            });

            spawn_global_hotkey_listener(Arc::clone(&audio_config));

            // Periodic telemetry emitter to frontend UI (approx 30fps = ~33ms)
            let app_handle = app.handle().clone();
            let audio_eng = Arc::clone(&audio_engine);
            let net_eng = Arc::clone(&network_engine);
            let aud_cfg = Arc::clone(&audio_config);

            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(std::time::Duration::from_millis(33));
                loop {
                    ticker.tick().await;
                    let levels = audio_eng.telemetry.snapshot();
                    let network = net_eng.state.snapshot();
                    let config = aud_cfg.lock().clone();
                    let (vbcable_device_name, vbcable_detected) = audio_eng.vbcable_status();

                    let snapshot = AppSnapshot {
                        config,
                        levels,
                        network,
                        vbcable_device_name,
                        vbcable_detected,
                    };

                    let _ = app_handle.emit("audio-telemetry", snapshot);
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_app_snapshot,
            update_audio_config,
            toggle_mic_mute,
            toggle_pc_mute,
            set_push_to_talk_active,
            set_manual_peer,
            get_output_audio_devices,
        ])
        .run(tauri::generate_context!())
        .expect("error while running AudioSync Pro Tauri application");
}
