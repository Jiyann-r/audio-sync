//! TEMPORARY AUDIT INSTRUMENTATION — delete this file and every `crate::diag::` call after the audit.
//! The audio-callback path only touches atomics (no locks, no allocation, no I/O).

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

static T0: OnceLock<Instant> = OnceLock::new();

#[inline]
pub fn now_us() -> u64 {
    T0.get_or_init(Instant::now).elapsed().as_micros() as u64
}
#[inline]
pub fn inc(c: &AtomicU64) {
    c.fetch_add(1, Relaxed);
}
#[inline]
pub fn add(c: &AtomicU64, v: u64) {
    c.fetch_add(v, Relaxed);
}
#[inline]
pub fn set_max(c: &AtomicU64, v: u64) {
    c.fetch_max(v, Relaxed);
}
#[inline]
pub fn set_min(c: &AtomicU64, v: u64) {
    c.fetch_min(v, Relaxed);
}

macro_rules! counters {
    ($($name:ident),* $(,)?) => { $(pub static $name: AtomicU64 = AtomicU64::new(0);)* };
}

// ---- per-second window counters (reset by reporter) ----
counters!(
    // network task
    RX_PKTS,
    RX_BYTES,
    RX_LEN_UNEXPECTED,
    SEQ_GAP_EVENTS,
    SEQ_GAP_PKTS,
    SEQ_LATE_OR_DUP,
    CHAN_FULL_DROPS,
    IAT_N,
    IAT_SUM_US,
    IAT_MAX_US,
    IAT_GT_15MS,
    IAT_GT_30MS,
    IAT_GT_60MS,
    IAT_LT_2MS,
    SND_IAT_MAX_US,
    SND_IAT_LT_2MS,
    OWD_MAX_US,
    // jitter buffer + DSP worker
    JB_FRAMES,
    JB_LOST,
    JB_LATE_DROPS,
    JB_OVERFLOW_DROPS,
    JB_RESETS,
    JB_DEPTH_MAX,
    DSP_FRAMES,
    VAD_GATED_FRAMES,
    VAD_GATE_TOGGLES,
    RING_TRIM_SAMPLES,
    RING_HIGH_WATER,
    WORKER_SLEEP_N,
    WORKER_SLEEP_SUM_US,
    WORKER_SLEEP_MAX_US,
    // cpal output callback
    CB_CALLS,
    CB_FRAMES,
    CB_FRAMES_MAX,
    CB_UNDERRUN_CALLS,
    CB_UNDERRUN_SAMPLES,
    CB_IAT_MAX_US,
    CB_LOCK_WAIT_MAX_US,
    CB_DUR_MAX_US,
);
pub static OWD_MIN_US: AtomicU64 = AtomicU64::new(u64::MAX);
pub static CB_FRAMES_MIN: AtomicU64 = AtomicU64::new(u64::MAX);
pub static CB_RING_LOW_WATER: AtomicU64 = AtomicU64::new(u64::MAX);
pub static PREV_GATED: AtomicBool = AtomicBool::new(false);

// ---- cumulative (never reset) — used for clock-drift estimate ----
static CUM_RX_SAMPLES: AtomicU64 = AtomicU64::new(0);
static CUM_CB_FRAMES: AtomicU64 = AtomicU64::new(0);
static CB_FRAMES_AT_FIRST_RX: AtomicU64 = AtomicU64::new(0);
static FIRST_RX_US: AtomicU64 = AtomicU64::new(0);
static OUT_RATE: AtomicU64 = AtomicU64::new(48_000);
static LAST_CB_US: AtomicU64 = AtomicU64::new(0);

// ---------------- (a)+(b) network stage ----------------
struct NetState {
    expected_seq: Option<u16>,
    last_arrival_us: u64,
    last_sender_ts: Option<u32>,
}
static NET: Mutex<NetState> = Mutex::new(NetState {
    expected_seq: None,
    last_arrival_us: 0,
    last_sender_ts: None,
});

/// Call for every PhoneToPc AudioOpus datagram (network task only).
pub fn on_mic_packet(seq: u16, sender_ts_us: u32, payload_len: usize) {
    let now = now_us();
    inc(&RX_PKTS);
    add(&RX_BYTES, payload_len as u64);
    if payload_len != 960 && payload_len != 1920 {
        inc(&RX_LEN_UNEXPECTED);
    }
    add(&CUM_RX_SAMPLES, (payload_len / 2) as u64);
    if FIRST_RX_US
        .compare_exchange(0, now.max(1), Relaxed, Relaxed)
        .is_ok()
    {
        CB_FRAMES_AT_FIRST_RX.store(CUM_CB_FRAMES.load(Relaxed), Relaxed);
    }

    let mut st = NET.lock().unwrap();
    // (a) sequence gaps / reorder
    match st.expected_seq {
        None => st.expected_seq = Some(seq.wrapping_add(1)),
        Some(exp) => {
            let d = seq.wrapping_sub(exp) as i16;
            if d == 0 {
                st.expected_seq = Some(seq.wrapping_add(1));
            } else if d > 0 {
                inc(&SEQ_GAP_EVENTS);
                add(&SEQ_GAP_PKTS, d as u64);
                st.expected_seq = Some(seq.wrapping_add(1));
            } else {
                inc(&SEQ_LATE_OR_DUP);
            }
        }
    }
    // (b) arrival jitter on the PC clock
    if st.last_arrival_us != 0 {
        let iat = now - st.last_arrival_us;
        inc(&IAT_N);
        add(&IAT_SUM_US, iat);
        set_max(&IAT_MAX_US, iat);
        if iat > 15_000 {
            inc(&IAT_GT_15MS);
        }
        if iat > 30_000 {
            inc(&IAT_GT_30MS);
        }
        if iat > 60_000 {
            inc(&IAT_GT_60MS);
        }
        if iat < 2_000 {
            inc(&IAT_LT_2MS);
        }
    }
    st.last_arrival_us = now;
    // Send-side spacing on the iPhone clock: shows whether bursts already exist before Wi-Fi
    if let Some(prev) = st.last_sender_ts {
        let sd = sender_ts_us.wrapping_sub(prev) as i32;
        if sd >= 0 {
            set_max(&SND_IAT_MAX_US, sd as u64);
            if sd < 2_000 {
                inc(&SND_IAT_LT_2MS);
            }
        }
    }
    st.last_sender_ts = Some(sender_ts_us);
    // Relative one-way delay: absolute value is meaningless, spread = network jitter, min-trend = clock skew
    let owd = (now as u32).wrapping_sub(sender_ts_us) as u64;
    set_min(&OWD_MIN_US, owd);
    set_max(&OWD_MAX_US, owd);
}

// ---------------- (c) output callback stage ----------------
/// Call at the end of `fill_output_buffer_f32` (atomics only — RT-safe).
#[inline]
pub fn on_output_callback(
    t_enter: u64,
    t_locked: u64,
    out_frames: usize,
    out_rate: u32,
    ring_before: usize,
) {
    let now = now_us();
    inc(&CB_CALLS);
    add(&CB_FRAMES, out_frames as u64);
    add(&CUM_CB_FRAMES, out_frames as u64);
    set_min(&CB_FRAMES_MIN, out_frames as u64);
    set_max(&CB_FRAMES_MAX, out_frames as u64);
    set_min(&CB_RING_LOW_WATER, ring_before as u64);
    OUT_RATE.store(out_rate as u64, Relaxed);
    let r = out_rate.max(1) as u64;
    let needed = (out_frames as u64 * 48_000 + r - 1) / r; // ring samples this callback consumes
    if FIRST_RX_US.load(Relaxed) != 0 && (ring_before as u64) < needed {
        inc(&CB_UNDERRUN_CALLS);
        add(&CB_UNDERRUN_SAMPLES, needed - ring_before as u64);
    }
    set_max(&CB_LOCK_WAIT_MAX_US, t_locked.saturating_sub(t_enter));
    set_max(&CB_DUR_MAX_US, now.saturating_sub(t_enter));
    let last = LAST_CB_US.swap(t_enter, Relaxed);
    if last != 0 {
        set_max(&CB_IAT_MAX_US, t_enter.saturating_sub(last));
    }
}

// ---------------- PCM taps for listening (20 s each, then auto-close) ----------------
const DUMP_SECONDS: u64 = 20;
struct Dump {
    w: Option<BufWriter<File>>,
    started_us: u64,
    finished: bool,
}
static RAW_DUMP: Mutex<Dump> = Mutex::new(Dump {
    w: None,
    started_us: 0,
    finished: false,
});
static DSP_DUMP: Mutex<Dump> = Mutex::new(Dump {
    w: None,
    started_us: 0,
    finished: false,
});

pub fn dump_raw(payload: &[u8]) {
    dump(&RAW_DUMP, "audiosync_A_rx_raw_s16le_mono_48k.raw", payload);
}
pub fn dump_dsp(samples: &[f32]) {
    let bytes: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();
    dump(&DSP_DUMP, "audiosync_B_post_dsp_f32le_mono_48k.raw", &bytes);
}
fn dump(slot: &Mutex<Dump>, name: &str, bytes: &[u8]) {
    let mut d = slot.lock().unwrap();
    if d.finished {
        return;
    }
    let now = now_us();
    if d.w.is_none() {
        let path = std::env::temp_dir().join(name);
        match File::create(&path) {
            Ok(f) => {
                emit(format!(
                    "[DIAG dump] recording {DUMP_SECONDS}s -> {}",
                    path.display()
                ));
                d.w = Some(BufWriter::new(f));
                d.started_us = now;
            }
            Err(e) => {
                emit(format!("[DIAG dump] cannot create {}: {e}", path.display()));
                d.finished = true;
                return;
            }
        }
    }
    if let Some(w) = d.w.as_mut() {
        let _ = w.write_all(bytes);
    }
    if now - d.started_us > DUMP_SECONDS * 1_000_000 {
        if let Some(mut w) = d.w.take() {
            let _ = w.flush();
        }
        d.finished = true;
        emit(format!("[DIAG dump] finished {name}"));
    }
}

// ---------------- reporter (stderr + %TEMP%\audiosync_diag.log) ----------------
static LOG: Mutex<Option<File>> = Mutex::new(None);
pub fn emit(line: String) {
    eprintln!("{line}");
    let mut g = LOG.lock().unwrap();
    if g.is_none() {
        let path = std::env::temp_dir().join("audiosync_diag.log");
        *g = OpenOptions::new().create(true).append(true).open(path).ok();
    }
    if let Some(f) = g.as_mut() {
        let _ = writeln!(f, "{line}");
    }
}

fn take(c: &AtomicU64) -> u64 {
    c.swap(0, Relaxed)
}
fn take_min(c: &AtomicU64) -> u64 {
    c.swap(u64::MAX, Relaxed)
}
fn ms(us: u64) -> f64 {
    us as f64 / 1000.0
}
fn fmt_min(v: u64) -> String {
    if v == u64::MAX {
        "-".into()
    } else {
        v.to_string()
    }
}

pub fn spawn_reporter() {
    let _ = now_us();
    emit(format!(
        "[DIAG] ===== session start (build: {}) log: {} =====",
        if cfg!(debug_assertions) {
            "DEBUG"
        } else {
            "RELEASE"
        },
        std::env::temp_dir().join("audiosync_diag.log").display()
    ));
    let _ = std::thread::Builder::new()
        .name("diag-reporter".into())
        .spawn(|| {
            let mut n: u64 = 0;
            loop {
                std::thread::sleep(Duration::from_secs(1));
                n += 1;
                report(n % 10 == 0);
            }
        });
}

fn report(with_drift: bool) {
    let t = now_us() as f64 / 1e6;
    let rx = take(&RX_PKTS);
    let iat_n = take(&IAT_N);
    let iat_sum = take(&IAT_SUM_US);
    let owd_min = take_min(&OWD_MIN_US);
    let owd_max = take(&OWD_MAX_US);
    let owd_spread = if owd_min == u64::MAX {
        0
    } else {
        owd_max.saturating_sub(owd_min)
    };
    emit(format!(
        "[DIAG {t:7.1}s NET ] rx={rx} bytes={} bad_len={} gap_ev={} gap_pkts={} late_dup={} chan_full={} | iat avg={:.2}ms max={:.1}ms >15={} >30={} >60={} <2={} | snd_iat_max={:.1}ms snd<2ms={} | owd_min={} owd_spread={:.1}ms",
        take(&RX_BYTES),
        take(&RX_LEN_UNEXPECTED),
        take(&SEQ_GAP_EVENTS),
        take(&SEQ_GAP_PKTS),
        take(&SEQ_LATE_OR_DUP),
        take(&CHAN_FULL_DROPS),
        if iat_n > 0 { ms(iat_sum) / iat_n as f64 } else { 0.0 },
        ms(take(&IAT_MAX_US)),
        take(&IAT_GT_15MS),
        take(&IAT_GT_30MS),
        take(&IAT_GT_60MS),
        take(&IAT_LT_2MS),
        ms(take(&SND_IAT_MAX_US)),
        take(&SND_IAT_LT_2MS),
        fmt_min(owd_min),
        ms(owd_spread),
    ));

    let ws_n = take(&WORKER_SLEEP_N);
    let ws_sum = take(&WORKER_SLEEP_SUM_US);
    emit(format!(
        "[DIAG {t:7.1}s JB  ] frames={} lost_zero_fill={} late_drop={} overflow_drop={} resets={} depth_max={} | dsp_frames={} vad_gated={} gate_toggles={} | worker_sleep avg={:.2}ms max={:.1}ms",
        take(&JB_FRAMES),
        take(&JB_LOST),
        take(&JB_LATE_DROPS),
        take(&JB_OVERFLOW_DROPS),
        take(&JB_RESETS),
        take(&JB_DEPTH_MAX),
        take(&DSP_FRAMES),
        take(&VAD_GATED_FRAMES),
        take(&VAD_GATE_TOGGLES),
        if ws_n > 0 { ms(ws_sum) / ws_n as f64 } else { 0.0 },
        ms(take(&WORKER_SLEEP_MAX_US)),
    ));

    let cb = take(&CB_CALLS);
    let cb_frames = take(&CB_FRAMES);
    emit(format!(
        "[DIAG {t:7.1}s OUT ] ring high={} low@cb={} trimmed={} | cb={cb} frames/cb min={} max={} avg={:.0} | underrun_cbs={} underrun_samp={} | cb_iat_max={:.1}ms lock_wait_max={}us cb_dur_max={}us",
        take(&RING_HIGH_WATER),
        fmt_min(take_min(&CB_RING_LOW_WATER)),
        take(&RING_TRIM_SAMPLES),
        fmt_min(take_min(&CB_FRAMES_MIN)),
        take(&CB_FRAMES_MAX),
        if cb > 0 { cb_frames as f64 / cb as f64 } else { 0.0 },
        take(&CB_UNDERRUN_CALLS),
        take(&CB_UNDERRUN_SAMPLES),
        ms(take(&CB_IAT_MAX_US)),
        take(&CB_LOCK_WAIT_MAX_US),
        take(&CB_DUR_MAX_US),
    ));

    let first = FIRST_RX_US.load(Relaxed);
    if with_drift && first != 0 {
        let el = (now_us() - first) as f64 / 1e6;
        let produced = CUM_RX_SAMPLES.load(Relaxed) as f64 / el;
        let out_rate = OUT_RATE.load(Relaxed) as f64;
        let consumed_dev = CUM_CB_FRAMES
            .load(Relaxed)
            .saturating_sub(CB_FRAMES_AT_FIRST_RX.load(Relaxed)) as f64
            / el;
        let consumed_48k = consumed_dev * 48_000.0 / out_rate;
        let delta = produced - consumed_48k;
        emit(format!(
            "[DIAG DRIFT] elapsed={el:.0}s producer={produced:.1} samp/s consumer={consumed_48k:.1} samp/s (device {consumed_dev:.1} fps @ {out_rate}) delta={delta:+.2} samp/s = {:+.0} ppm",
            delta / 48_000.0 * 1e6
        ));
    }
}
