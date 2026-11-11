import React from 'react';

interface VuMeterProps {
  label: string;
  sublabel?: string;
  peak: number; // 0.0 to 1.0+
  rms: number;  // 0.0 to 1.0+
  muted?: boolean;
  color?: 'cyan' | 'violet' | 'emerald';
  segmentsCount?: number;
}

export const VuMeter: React.FC<VuMeterProps> = ({
  label,
  sublabel,
  peak,
  rms,
  muted = false,
  color = 'cyan',
  segmentsCount = 28,
}) => {
  // Convert peak & rms to normalized bar display (0 to 1) with log scaling
  const effectivePeak = muted ? 0 : Math.min(Math.max(peak, 0), 1.2);
  const effectiveRms = muted ? 0 : Math.min(Math.max(rms, 0), 1.0);

  // Map 0..1 to segments
  const activeSegments = Math.round(effectivePeak * segmentsCount);
  const rmsSegments = Math.round(effectiveRms * segmentsCount);

  // Peak in dB for readout
  const db = effectivePeak > 0.0001 ? (20 * Math.log10(effectivePeak)).toFixed(1) : '-inf';

  const getColorClasses = (index: number) => {
    const ratio = index / segmentsCount;
    if (ratio > 0.88) {
      return 'bg-rose-500 shadow-[0_0_8px_rgba(244,63,94,0.8)]';
    }
    if (ratio > 0.72) {
      return 'bg-amber-400 shadow-[0_0_8px_rgba(251,191,36,0.6)]';
    }
    if (color === 'violet') {
      return 'bg-violet-400 shadow-[0_0_8px_rgba(168,85,247,0.7)]';
    }
    if (color === 'emerald') {
      return 'bg-emerald-400 shadow-[0_0_8px_rgba(16,185,129,0.7)]';
    }
    return 'bg-cyan-400 shadow-[0_0_8px_rgba(34,211,238,0.7)]';
  };

  return (
    <div className="w-full flex flex-col gap-2">
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-slate-200 tracking-wide">{label}</span>
          {sublabel && <span className="text-slate-400 text-[11px]">({sublabel})</span>}
        </div>
        <div className="font-mono text-[11px] text-slate-400">
          {muted ? <span className="text-rose-400 font-medium">MUTED</span> : `${db} dB`}
        </div>
      </div>

      {/* Segmented LED VU Bar */}
      <div className="h-4 w-full bg-slate-900/80 rounded-pill p-1 border border-white/10 flex items-center gap-1 shadow-inner overflow-hidden">
        {Array.from({ length: segmentsCount }).map((_, idx) => {
          const isActive = !muted && idx < activeSegments;
          const isRms = !muted && idx < rmsSegments;
          
          return (
            <div
              key={idx}
              className={`h-full flex-1 rounded-sm transition-all duration-75 ${
                isActive
                  ? getColorClasses(idx)
                  : 'bg-white/5 opacity-40'
              } ${isRms ? 'opacity-100' : 'opacity-85'}`}
            />
          );
        })}
      </div>
    </div>
  );
};
