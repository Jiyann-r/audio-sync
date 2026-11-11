import React from 'react';
import { HeadphoneIcon, Volume2Icon, VolumeXIcon } from './Icons';
import { VuMeter } from './VuMeter';
import { AudioConfig, AudioLevels } from '../types';

interface PcAudioCardProps {
  config: AudioConfig;
  levels: AudioLevels;
  onToggleMute: () => void;
  onUpdateConfig: (newConfig: AudioConfig) => void;
}

export const PcAudioCard: React.FC<PcAudioCardProps> = ({
  config,
  levels,
  onToggleMute,
  onUpdateConfig,
}) => {
  const handleVolumeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = parseFloat(e.target.value);
    onUpdateConfig({ ...config, pc_volume: val });
  };

  const handleLatencyChange = (durationMs: number) => {
    onUpdateConfig({ ...config, frame_duration_ms: durationMs });
  };

  const handleBitrateChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const bps = parseInt(e.target.value, 10);
    onUpdateConfig({ ...config, opus_bitrate_bps: bps });
  };

  return (
    <div className="glass-panel p-6 flex flex-col gap-5 relative overflow-hidden">
      {/* Header & Toggle */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-pill bg-cyan-500/10 text-cyan-400 border border-cyan-500/30 flex items-center justify-center shadow-[0_0_20px_rgba(34,211,238,0.2)]">
            <HeadphoneIcon size={20} />
          </div>
          <div>
            <h2 className="text-sm font-semibold tracking-wide text-slate-100">PC Audio Stream</h2>
            <p className="text-xs text-slate-400">Desktop sound to iPhone headphones</p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* Mute Button */}
          <button
            type="button"
            onClick={onToggleMute}
            className={`glass-pill px-3 py-1.5 flex items-center gap-2 text-xs font-medium transition-all ${
              config.pc_muted
                ? 'bg-rose-500/20 text-rose-300 border-rose-500/40 shadow-[0_0_15px_rgba(244,63,94,0.3)]'
                : 'text-slate-300 hover:text-white'
            }`}
            title="Toggle PC Output Mute"
          >
            {config.pc_muted ? <VolumeXIcon size={16} /> : <Volume2Icon size={16} />}
            <span>{config.pc_muted ? 'Muted' : 'Mute'}</span>
          </button>

          {/* Enable Toggle Switch */}
          <button
            type="button"
            onClick={() => onUpdateConfig({ ...config, pc_to_phone_enabled: !config.pc_to_phone_enabled })}
            className={`w-12 h-6 rounded-pill p-1 transition-colors duration-200 ease-in-out border flex items-center ${
              config.pc_to_phone_enabled
                ? 'bg-cyan-500 border-cyan-400 justify-end shadow-[0_0_15px_rgba(34,211,238,0.4)]'
                : 'bg-white/10 border-white/10 justify-start'
            }`}
          >
            <div className="w-4 h-4 rounded-full bg-white shadow-md transition-transform" />
          </button>
        </div>
      </div>

      {/* VU Meter */}
      <div className="pt-1">
        <VuMeter
          label="PC Loopback Audio"
          sublabel="48kHz Stereo WASAPI"
          peak={levels.pc_peak}
          rms={levels.pc_rms}
          muted={config.pc_muted || !config.pc_to_phone_enabled}
          color="cyan"
        />
      </div>

      {/* Controls: Volume, Bitrate, Latency Buffer */}
      <div className="flex flex-col gap-4 pt-2 border-t border-white/5 text-xs">
        {/* Volume Slider */}
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between text-slate-300">
            <span>Stream Volume</span>
            <span className="font-mono text-cyan-400">{Math.round(config.pc_volume * 100)}%</span>
          </div>
          <input
            type="range"
            min="0"
            max="1.5"
            step="0.05"
            value={config.pc_volume}
            onChange={handleVolumeChange}
            className="w-full"
          />
        </div>

        {/* Latency & Quality Tuning Row */}
        <div className="grid grid-cols-2 gap-3 pt-1">
          {/* Audio Buffer Latency (10ms vs 20ms) */}
          <div className="flex flex-col gap-1.5">
            <span className="text-slate-400 text-[11px] uppercase tracking-wider font-semibold">
              Frame Latency
            </span>
            <div className="flex items-center gap-1.5 bg-white/[0.04] p-1 rounded-pill border border-white/5">
              <button
                type="button"
                onClick={() => handleLatencyChange(10)}
                className={`flex-1 py-1 px-2 rounded-pill text-[11px] font-medium transition-all ${
                  config.frame_duration_ms === 10
                    ? 'bg-cyan-500 text-slate-950 font-semibold shadow-sm'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                10ms (Ultra)
              </button>
              <button
                type="button"
                onClick={() => handleLatencyChange(20)}
                className={`flex-1 py-1 px-2 rounded-pill text-[11px] font-medium transition-all ${
                  config.frame_duration_ms === 20
                    ? 'bg-cyan-500 text-slate-950 font-semibold shadow-sm'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                20ms (Standard)
              </button>
            </div>
          </div>

          {/* Opus Bitrate Selector */}
          <div className="flex flex-col gap-1.5">
            <span className="text-slate-400 text-[11px] uppercase tracking-wider font-semibold">
              Opus Bitrate
            </span>
            <select
              value={config.opus_bitrate_bps}
              onChange={handleBitrateChange}
              className="bg-white/5 border border-white/10 rounded-pill px-3 py-1 text-[11px] font-mono text-slate-200 focus:outline-none focus:border-cyan-400"
            >
              <option value="32000" className="bg-slate-900 text-white">32 kbps (Low Bandwidth)</option>
              <option value="64000" className="bg-slate-900 text-white">64 kbps (Balanced)</option>
              <option value="96000" className="bg-slate-900 text-white">96 kbps (High Quality)</option>
              <option value="128000" className="bg-slate-900 text-white">128 kbps (Lossless feel)</option>
            </select>
          </div>
        </div>
      </div>
    </div>
  );
};
