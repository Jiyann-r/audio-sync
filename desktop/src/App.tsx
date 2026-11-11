import React, { useEffect, useState, useCallback } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { ConnectionCard } from './components/ConnectionCard';
import { PcAudioCard } from './components/PcAudioCard';
import { MicAudioCard } from './components/MicAudioCard';
import { SlidersIcon } from './components/Icons';
import { AppSnapshot, AudioConfig } from './types';

export const App: React.FC = () => {
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [outputDevices, setOutputDevices] = useState<string[]>([]);

  // Initial fetch of snapshot and output audio devices
  useEffect(() => {
    invoke<AppSnapshot>('get_app_snapshot')
      .then((data) => setSnapshot(data))
      .catch((err) => console.error('Failed to get snapshot:', err));

    invoke<string[]>('get_output_audio_devices')
      .then((devs) => setOutputDevices(devs))
      .catch((err) => console.error('Failed to get devices:', err));
  }, []);

  // Subscribe to real-time 30fps telemetry events from Tauri backend
  useEffect(() => {
    let unlistenFn: (() => void) | undefined;

    listen<AppSnapshot>('audio-telemetry', (event) => {
      setSnapshot(event.payload);
    }).then((unlisten) => {
      unlistenFn = unlisten;
    }).catch((err) => {
      console.warn('Could not listen to audio-telemetry event, fallback to poll:', err);
    });

    return () => {
      if (unlistenFn) unlistenFn();
    };
  }, []);

  // Update backend audio configuration
  const handleUpdateConfig = useCallback((newConfig: AudioConfig) => {
    setSnapshot((prev) => (prev ? { ...prev, config: newConfig } : null));
    invoke<AudioConfig>('update_audio_config', { newConfig })
      .catch((err) => console.error('Failed to update config:', err));
  }, []);

  // Toggle Mic Mute
  const handleToggleMicMute = useCallback(() => {
    invoke<boolean>('toggle_mic_mute')
      .then((muted) => {
        setSnapshot((prev) =>
          prev ? { ...prev, config: { ...prev.config, mic_muted: muted } } : null
        );
      })
      .catch((err) => console.error('Failed to toggle mic mute:', err));
  }, []);

  // Toggle PC Mute
  const handleTogglePcMute = useCallback(() => {
    invoke<boolean>('toggle_pc_mute')
      .then((muted) => {
        setSnapshot((prev) =>
          prev ? { ...prev, config: { ...prev.config, pc_muted: muted } } : null
        );
      })
      .catch((err) => console.error('Failed to toggle pc mute:', err));
  }, []);

  // Push-to-Talk active state trigger
  const handleSetPttActive = useCallback((active: boolean) => {
    invoke<boolean>('set_push_to_talk_active', { active })
      .then((isActive) => {
        setSnapshot((prev) =>
          prev
            ? { ...prev, config: { ...prev.config, push_to_talk_active: isActive } }
            : null
        );
      })
      .catch((err) => console.error('Failed to set PTT active:', err));
  }, []);

  // Manual IP pairing
  const handleSetManualPeer = useCallback((ipAndPort: string) => {
    invoke<string>('set_manual_peer', { ipAndPort })
      .then(() => {
        invoke<AppSnapshot>('get_app_snapshot').then((s) => setSnapshot(s));
      })
      .catch((err) => {
        alert(`Failed to set manual peer: ${err}`);
      });
  }, []);

  return (
    <div className="relative min-h-screen w-screen bg-canvas text-slate-100 flex flex-col p-6 overflow-x-hidden select-none">
      {/* 24px dot grid overlay */}
      <div className="fixed inset-0 bg-dot-grid pointer-events-none opacity-40 z-0" />

      {/* Vivid ambient lighting waves */}
      <div className="ambient-glow-violet top-[-80px] left-[15%] w-[480px] h-[380px] z-0 opacity-60" />
      <div className="ambient-glow-cyan top-[20%] right-[-100px] w-[540px] h-[440px] z-0 opacity-40" />
      <div className="ambient-glow-violet bottom-[-100px] left-[35%] w-[600px] h-[400px] z-0 opacity-50" />

      {/* Main Container */}
      <div className="relative z-10 max-w-6xl w-full mx-auto flex flex-col gap-6">
        {/* Top App Header */}
        <header className="flex items-center justify-between pb-2 border-b border-white/10">
          <div className="flex items-center gap-3">
            <div className="w-9 h-9 rounded-pill bg-gradient-to-tr from-cyan-400 via-blurple to-violet-500 p-[1px] shadow-[0_0_20px_rgba(99,102,241,0.5)]">
              <div className="w-full h-full bg-slate-950 rounded-pill flex items-center justify-center">
                <SlidersIcon size={18} className="text-cyan-400" />
              </div>
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h1 className="text-base font-bold tracking-tight text-white">AudioSync Pro</h1>
                <span className="text-[10px] font-mono px-2 py-0.5 rounded-pill bg-white/10 text-cyan-300 font-semibold border border-white/10">
                  v0.1.0
                </span>
              </div>
              <p className="text-xs text-slate-400">
                Low-Latency Bi-Directional Wi-Fi Audio Sync for iPhone 13 & Windows
              </p>
            </div>
          </div>

          {/* Quick status badge */}
          <div className="flex items-center gap-2 text-xs font-mono">
            <span className="px-3 py-1 rounded-pill bg-white/5 border border-white/10 text-slate-300">
              WASAPI Loopback 48kHz
            </span>
            <span className="px-3 py-1 rounded-pill bg-white/5 border border-white/10 text-slate-300">
              Opus Low-Delay
            </span>
          </div>
        </header>

        {snapshot ? (
          <>
            {/* Top Row: Network Discovery & Connection Card */}
            <ConnectionCard
              network={snapshot.network}
              onSetManualPeer={handleSetManualPeer}
            />

            {/* Bottom Row: Dual Audio Cards (PC Desktop Audio vs iPhone Mic) */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              {/* Left Column: PC to iPhone Stream */}
              <PcAudioCard
                config={snapshot.config}
                levels={snapshot.levels}
                onToggleMute={handleTogglePcMute}
                onUpdateConfig={handleUpdateConfig}
              />

              {/* Right Column: iPhone to PC Microphone Stream */}
              <MicAudioCard
                config={snapshot.config}
                levels={snapshot.levels}
                vbcableDeviceName={snapshot.vbcable_device_name}
                vbcableDetected={snapshot.vbcable_detected}
                availableDevices={outputDevices}
                onToggleMute={handleToggleMicMute}
                onSetPttActive={handleSetPttActive}
                onUpdateConfig={handleUpdateConfig}
              />
            </div>
          </>
        ) : (
          <div className="glass-panel p-16 flex flex-col items-center justify-center gap-4 text-center">
            <div className="w-12 h-12 rounded-full border-2 border-cyan-400 border-t-transparent animate-spin" />
            <div className="text-sm text-slate-300">Initializing Audio Engine & Network Telemetry...</div>
          </div>
        )}
      </div>
    </div>
  );
};
