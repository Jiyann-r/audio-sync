import React, { useState } from 'react';
import { WifiIcon, ActivityIcon, CheckIcon } from './Icons';
import { NetworkStatus } from '../types';

interface ConnectionCardProps {
  network: NetworkStatus;
  onSetManualPeer: (ipAndPort: string) => void;
}

export const ConnectionCard: React.FC<ConnectionCardProps> = ({ network, onSetManualPeer }) => {
  const [manualIp, setManualIp] = useState('');
  const [showManualInput, setShowManualInput] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  const handleManualSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!manualIp.trim()) return;
    try {
      // Validate IP or IP:Port
      const formatted = manualIp.includes(':') ? manualIp.trim() : `${manualIp.trim()}:${network.udp_port || 54321}`;
      onSetManualPeer(formatted);
      setShowManualInput(false);
      setErrorMsg(null);
    } catch (err: unknown) {
      setErrorMsg(err instanceof Error ? err.message : String(err));
    }
  };

  return (
    <div className="glass-panel p-6 flex flex-col gap-4 relative overflow-hidden group">
      {/* Subtle top indicator line */}
      <div
        className={`absolute top-0 left-0 right-0 h-1 transition-all duration-300 ${
          network.connected
            ? 'bg-gradient-to-r from-emerald-400 via-cyan-400 to-blurple'
            : 'bg-gradient-to-r from-amber-500/40 via-violet-500/20 to-transparent'
        }`}
      />

      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div
            className={`w-10 h-10 rounded-pill flex items-center justify-center transition-all duration-300 ${
              network.connected
                ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/40 shadow-[0_0_20px_rgba(16,185,129,0.3)]'
                : 'bg-white/5 text-slate-400 border border-white/10'
            }`}
          >
            <WifiIcon size={20} />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h2 className="text-sm font-semibold tracking-wide text-slate-100">Local Wi-Fi Network</h2>
              <span
                className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-pill text-[11px] font-medium tracking-wide uppercase ${
                  network.connected
                    ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30'
                    : 'bg-amber-500/15 text-amber-400 border border-amber-500/30'
                }`}
              >
                <span
                  className={`w-1.5 h-1.5 rounded-full ${
                    network.connected ? 'bg-emerald-400 animate-pulse' : 'bg-amber-400'
                  }`}
                />
                {network.connected ? 'Connected' : 'Waiting for iPhone'}
              </span>
            </div>
            <p className="text-xs text-slate-400 mt-0.5">
              mDNS: <span className="font-mono text-cyan-400">{network.mdns_active ? 'Active (_audiosync._udp)' : 'Inactive'}</span>
            </p>
          </div>
        </div>

        {/* Latency RTT Badge */}
        {network.connected && (
          <div className="flex items-center gap-3 bg-white/5 px-3 py-1.5 rounded-pill border border-white/10 font-mono text-xs">
            <div className="flex items-center gap-1.5 text-cyan-400">
              <ActivityIcon size={14} />
              <span>{network.rtt_ms.toFixed(1)} ms</span>
            </div>
            <span className="text-slate-500">|</span>
            <span className="text-slate-300 text-[11px]">
              {network.peer_device_name || 'iPhone 13'}
            </span>
          </div>
        )}
      </div>

      {/* Network Stats Grid */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 font-mono text-xs pt-1">
        <div className="bg-white/[0.03] p-3 rounded-2xl border border-white/5">
          <div className="text-[10px] text-slate-400 uppercase tracking-wider font-sans">PC Local IP</div>
          <div className="text-slate-200 mt-1 font-semibold truncate">{network.local_ip}</div>
        </div>
        <div className="bg-white/[0.03] p-3 rounded-2xl border border-white/5">
          <div className="text-[10px] text-slate-400 uppercase tracking-wider font-sans">UDP Port</div>
          <div className="text-slate-200 mt-1 font-semibold">{network.udp_port}</div>
        </div>
        <div className="bg-white/[0.03] p-3 rounded-2xl border border-white/5">
          <div className="text-[10px] text-slate-400 uppercase tracking-wider font-sans">Packets In / Out</div>
          <div className="text-slate-200 mt-1 font-semibold">
            {network.packets_received} / {network.packets_sent}
          </div>
        </div>
        <div className="bg-white/[0.03] p-3 rounded-2xl border border-white/5">
          <div className="text-[10px] text-slate-400 uppercase tracking-wider font-sans">Packets Lost</div>
          <div className={`mt-1 font-semibold ${network.packets_lost > 0 ? 'text-amber-400' : 'text-slate-200'}`}>
            {network.packets_lost}
          </div>
        </div>
      </div>

      {/* Manual IP Fallback Toggle & Input */}
      <div className="pt-2 border-t border-white/5 flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <span className="text-xs text-slate-400">
            {network.peer_address ? (
              <span>Peer: <span className="font-mono text-slate-300">{network.peer_address}</span></span>
            ) : (
              'Auto-discovery will pair automatically when iPhone opens the app.'
            )}
          </span>
          <button
            type="button"
            onClick={() => setShowManualInput(!showManualInput)}
            className="text-xs text-cyan-400 hover:text-cyan-300 underline font-medium transition-colors"
          >
            {showManualInput ? 'Close Manual IP' : 'Manual IP Pair'}
          </button>
        </div>

        {showManualInput && (
          <form onSubmit={handleManualSubmit} className="flex items-center gap-2 mt-1 animate-popover">
            <input
              type="text"
              placeholder="e.g. 192.168.1.50:54321"
              value={manualIp}
              onChange={(e) => setManualIp(e.target.value)}
              className="flex-1 bg-white/5 border border-white/10 rounded-pill px-4 py-2 text-xs font-mono text-slate-100 placeholder:text-slate-500 focus:outline-none focus:border-cyan-400"
            />
            <button
              type="submit"
              className="glass-pill px-4 py-2 text-xs font-medium text-cyan-300 hover:text-white flex items-center gap-1.5 border-cyan-500/40"
            >
              <CheckIcon size={14} />
              <span>Connect</span>
            </button>
          </form>
        )}
        {errorMsg && <div className="text-xs text-rose-400 font-mono">{errorMsg}</div>}
      </div>
    </div>
  );
};
