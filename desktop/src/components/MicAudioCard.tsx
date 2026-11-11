import React, { useState } from 'react';
import {
  MicIcon,
  MicOffIcon,
  SparklesIcon,
  ShieldCheckIcon,
  AlertCircleIcon,
  ChevronDownIcon,
} from './Icons';
import { VuMeter } from './VuMeter';
import { AudioConfig, AudioLevels } from '../types';

interface MicAudioCardProps {
  config: AudioConfig;
  levels: AudioLevels;
  vbcableDeviceName: string;
  vbcableDetected: boolean;
  availableDevices: string[];
  onToggleMute: () => void;
  onSetPttActive: (active: boolean) => void;
  onUpdateConfig: (newConfig: AudioConfig) => void;
}

export const MicAudioCard: React.FC<MicAudioCardProps> = ({
  config,
  levels,
  vbcableDeviceName,
  vbcableDetected,
  availableDevices,
  onToggleMute,
  onSetPttActive,
  onUpdateConfig,
}) => {
  const [showDeviceDropdown, setShowDeviceDropdown] = useState(false);

  const handleGainChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseFloat(e.target.value);
    onUpdateConfig({ ...config, mic_gain_db: val });
  };

  const handleVadChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseFloat(e.target.value);
    onUpdateConfig({ ...config, vad_gate_threshold: val });
  };

  const handleJitterChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseInt(e.target.value, 10);
    onUpdateConfig({ ...config, jitter_buffer_packets: val });
  };

  const handleSelectDevice = (dev: string) => {
    onUpdateConfig({ ...config, virtual_mic_device_hint: dev });
    setShowDeviceDropdown(false);
  };

  const isMicTransmitting =
    config.phone_to_pc_enabled &&
    !config.mic_muted &&
    (!config.push_to_talk_enabled || config.push_to_talk_active);

  return (
    <div className="glass-panel p-6 flex flex-col gap-5 relative overflow-hidden">
      {/* Header & Toggle */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-pill bg-violet-500/10 text-violet-400 border border-violet-500/30 flex items-center justify-center shadow-[0_0_20px_rgba(168,85,247,0.2)]">
            <MicIcon size={20} />
          </div>
          <div>
            <h2 className="text-sm font-semibold tracking-wide text-slate-100">iPhone Microphone</h2>
            <p className="text-xs text-slate-400">Routes phone mic to Windows virtual cable</p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* Mute Button */}
          <button
            type="button"
            onClick={onToggleMute}
            className={`glass-pill px-3 py-1.5 flex items-center gap-2 text-xs font-medium transition-all ${
              config.mic_muted
                ? 'bg-rose-500/20 text-rose-300 border-rose-500/40 shadow-[0_0_15px_rgba(244,63,94,0.3)]'
                : 'text-slate-300 hover:text-white'
            }`}
            title="Toggle iPhone Mic Mute (Ctrl+Shift+M)"
          >
            {config.mic_muted ? <MicOffIcon size={16} /> : <MicIcon size={16} />}
            <span>{config.mic_muted ? 'Muted' : 'Mute'}</span>
          </button>

          {/* Enable Toggle Switch */}
          <button
            type="button"
            onClick={() => onUpdateConfig({ ...config, phone_to_pc_enabled: !config.phone_to_pc_enabled })}
            className={`w-12 h-6 rounded-pill p-1 transition-colors duration-200 ease-in-out border flex items-center ${
              config.phone_to_pc_enabled
                ? 'bg-violet-500 border-violet-400 justify-end shadow-[0_0_15px_rgba(168,85,247,0.4)]'
                : 'bg-white/10 border-white/10 justify-start'
            }`}
          >
            <div className="w-4 h-4 rounded-full bg-white shadow-md transition-transform" />
          </button>
        </div>
      </div>

      {/* VB-CABLE Status Pill & Output Selector */}
      <div className="flex items-center justify-between text-xs bg-white/[0.03] p-3 rounded-2xl border border-white/5 relative">
        <div className="flex items-center gap-2">
          {vbcableDetected ? (
            <div className="flex items-center gap-1.5 text-emerald-400">
              <ShieldCheckIcon size={16} />
              <span className="font-medium">VB-CABLE Active</span>
            </div>
          ) : (
            <div className="flex items-center gap-1.5 text-amber-400">
              <AlertCircleIcon size={16} />
              <span className="font-medium">Virtual Cable Missing</span>
            </div>
          )}
          <span className="text-slate-500">|</span>
          <span className="text-slate-300 truncate max-w-[200px]" title={vbcableDeviceName}>
            {vbcableDeviceName}
          </span>
        </div>

        <button
          type="button"
          onClick={() => setShowDeviceDropdown(!showDeviceDropdown)}
          className="flex items-center gap-1 text-[11px] text-violet-400 hover:text-violet-300 font-medium"
        >
          <span>Change Device</span>
          <ChevronDownIcon size={14} />
        </button>

        {showDeviceDropdown && (
          <div className="absolute right-0 top-12 z-20 w-72 glass-dropdown p-2 animate-popover flex flex-col gap-1 max-h-56 overflow-y-auto">
            <div className="px-3 py-1 text-[10px] uppercase tracking-wider font-semibold text-slate-400">
              Select Output Recording Sink
            </div>
            {availableDevices.map((dev) => (
              <button
                key={dev}
                type="button"
                onClick={() => handleSelectDevice(dev)}
                className={`text-left px-3 py-2 rounded-xl text-xs transition-colors truncate ${
                  vbcableDeviceName.includes(dev)
                    ? 'bg-violet-500/20 text-violet-300 font-medium'
                    : 'text-slate-200 hover:bg-white/5'
                }`}
              >
                {dev}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* VU Meter */}
      <div className="pt-1">
        <VuMeter
          label="Microphone Audio Level"
          sublabel={isMicTransmitting ? 'Transmitting' : 'Silenced / PTT off'}
          peak={levels.mic_peak}
          rms={levels.mic_rms}
          muted={!isMicTransmitting}
          color="violet"
        />
      </div>

      {/* Push-to-Talk Controls */}
      <div className="bg-white/[0.03] p-4 rounded-2xl border border-white/5 flex flex-col gap-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <span className="text-xs font-semibold text-slate-200">Push-to-Talk Mode</span>
            <span className="text-[10px] font-mono px-2 py-0.5 rounded-pill bg-white/5 text-slate-400 border border-white/10">
              Hotkey: Ctrl+Shift+Space
            </span>
          </div>

          <button
            type="button"
            onClick={() => onUpdateConfig({ ...config, push_to_talk_enabled: !config.push_to_talk_enabled })}
            className={`w-10 h-5 rounded-pill p-0.5 transition-colors duration-200 ease-in-out border flex items-center ${
              config.push_to_talk_enabled
                ? 'bg-violet-500 border-violet-400 justify-end'
                : 'bg-white/10 border-white/10 justify-start'
            }`}
          >
            <div className="w-3.5 h-3.5 rounded-full bg-white shadow-md" />
          </button>
        </div>

        {/* Large PTT Button (Interactive on press or hotkey) */}
        <button
          type="button"
          onMouseDown={() => onSetPttActive(true)}
          onMouseUp={() => onSetPttActive(false)}
          onTouchStart={() => onSetPttActive(true)}
          onTouchEnd={() => onSetPttActive(false)}
          disabled={!config.push_to_talk_enabled}
          className={`w-full py-2.5 rounded-pill font-medium text-xs tracking-wider uppercase flex items-center justify-center gap-2 border transition-all ${
            !config.push_to_talk_enabled
              ? 'opacity-40 bg-white/5 border-white/5 text-slate-500 cursor-not-allowed'
              : config.push_to_talk_active
              ? 'bg-violet-500 text-white border-violet-300 shadow-[0_0_25px_rgba(168,85,247,0.7)] scale-[0.98]'
              : 'bg-violet-500/20 text-violet-300 border-violet-500/40 hover:bg-violet-500/30'
          }`}
        >
          <MicIcon size={16} />
          <span>
            {config.push_to_talk_enabled
              ? config.push_to_talk_active
                ? 'Speaking (PTT Active)'
                : 'Hold To Speak (PTT)'
              : 'Continuous Transmission (PTT Disabled)'}
          </span>
        </button>
      </div>

      {/* DSP Sliders: RNNoise AI, VAD Gate, Mic Gain Boost, Jitter Buffer */}
      <div className="flex flex-col gap-4 pt-1 border-t border-white/5 text-xs">
        {/* RNNoise Toggle and VAD Gate */}
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <SparklesIcon size={16} className="text-violet-400" />
              <span className="font-semibold text-slate-200">AI Noise Suppression (RNNoise)</span>
            </div>
            <button
              type="button"
              onClick={() => onUpdateConfig({ ...config, rnnoise_enabled: !config.rnnoise_enabled })}
              className={`w-10 h-5 rounded-pill p-0.5 transition-colors border flex items-center ${
                config.rnnoise_enabled
                  ? 'bg-violet-500 border-violet-400 justify-end shadow-sm'
                  : 'bg-white/10 border-white/10 justify-start'
              }`}
            >
              <div className="w-3.5 h-3.5 rounded-full bg-white shadow-md" />
            </button>
          </div>

          {config.rnnoise_enabled && (
            <div className="flex flex-col gap-1.5 pl-6 pt-1">
              <div className="flex items-center justify-between text-slate-300 text-[11px]">
                <span>Voice Gate Threshold (VAD)</span>
                <span className="font-mono text-violet-400">
                  {Math.round(config.vad_gate_threshold * 100)}%
                </span>
              </div>
              <input
                type="range"
                min="0.0"
                max="0.8"
                step="0.05"
                value={config.vad_gate_threshold}
                onChange={handleVadChange}
                className="w-full"
              />
            </div>
          )}
        </div>

        {/* Mic Gain Boost Slider */}
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between text-slate-300">
            <span>Microphone Gain Boost</span>
            <span className="font-mono text-violet-400">{config.mic_gain_db.toFixed(1)} dB</span>
          </div>
          <input
            type="range"
            min="-12"
            max="18"
            step="0.5"
            value={config.mic_gain_db}
            onChange={handleGainChange}
            className="w-full"
          />
        </div>

        {/* Jitter Buffer Latency Slider */}
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between text-slate-300">
            <span>Adaptive Jitter Buffer</span>
            <span className="font-mono text-violet-400">
              {config.jitter_buffer_packets * 10} ms ({config.jitter_buffer_packets} frames)
            </span>
          </div>
          <input
            type="range"
            min="1"
            max="6"
            step="1"
            value={config.jitter_buffer_packets}
            onChange={handleJitterChange}
            className="w-full"
          />
        </div>
      </div>
    </div>
  );
};
