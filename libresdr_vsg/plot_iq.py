#!/usr/bin/env python3
"""Plot a pulsed-LFM IQ file so the waveform can be checked by eye.

Four panels, written to one PNG:
  1  envelope (dBFS) over the first few PRIs   -> PRI, pulse width, duty cycle
  2  one pulse zoomed in, I and Q               -> the chirp speeding up across the pulse
  3  instantaneous frequency inside the pulse   -> straight line from -B/2 to +B/2 (ideal dashed)
  4  spectrum averaged over all pulses          -> occupied bandwidth ~ B

Optionally overlay a reference file (e.g. the ideal --dump against a loopback
capture) in panels 3 and 4 with --ref.

Usage:
  plot_iq.py FILE --rate R [--out FILE.png] [--chirp-bw 1e6] [--pw 50e-6]
             [--ref FILE --ref-rate R --ref-label NAME] [--dtype int16|float32]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

from measure_iq import load, measure, runs  # noqa: E402

BLUE, ORANGE, VIOLET = "#2a78d6", "#eb6834", "#6250d6"
INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"


def find_pulses(x, rate):
    p = np.abs(x) ** 2
    w = max(1, int(round(0.5e-6 * rate)))
    ps = np.convolve(p, np.ones(w) / w, mode="same")
    on = ps > np.percentile(ps, 99.9) / 4
    s, e = runs(on)
    keep = (s > 0) & (e < p.size)
    return s[keep], e[keep]


def inst_freq(seg, rate):
    """Instantaneous frequency (Hz) from the phase step between samples, lightly smoothed."""
    f = np.angle(seg[1:] * np.conj(seg[:-1])) * rate / (2 * np.pi)
    k = max(1, int(round(1e-6 * rate)))
    if k > 1 and f.size > k:
        f = np.convolve(f, np.ones(k) / k, mode="valid")
    t = (np.arange(f.size) + (k + 1) / 2) / rate
    return t, f


def pulse_core(x, s, e):
    n = e - s
    return x[s + n // 20: e - n // 20], n // 20  # drop edge transients


def spectrum(x, rate, starts, stops):
    width = int(np.median(stops - starts))
    pad = width // 2
    L = width + 2 * pad
    nfft = 1 << int(np.ceil(np.log2(8 * L)))
    acc, n = np.zeros(nfft), 0
    for s in starts:
        a = s - pad
        if a < 0 or a + L > x.size:
            continue
        acc += np.abs(np.fft.fft(x[a:a + L], nfft)) ** 2
        n += 1
    if n == 0:
        return None, None
    f = np.fft.fftshift(np.fft.fftfreq(nfft, 1 / rate))
    psd = np.fft.fftshift(acc / n)
    return f, 10 * np.log10(np.maximum(psd / psd.max(), 1e-12))


def style(ax, title):
    ax.set_facecolor(SURF)
    ax.set_title(title, loc="left", fontsize=11, color=INK)
    ax.grid(True, color=GRID, linewidth=0.6)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(INK2)
    ax.tick_params(colors=INK2, labelsize=9)
    ax.xaxis.label.set_color(INK2)
    ax.yaxis.label.set_color(INK2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--rate", type=float, required=True)
    ap.add_argument("--dtype", choices=["int16", "float32"], default="int16")
    ap.add_argument("--fullscale", type=float, default=None)
    ap.add_argument("--skip", type=float, default=0.0, help="seconds to drop from the start")
    ap.add_argument("--chirp-bw", type=float, default=1e6, help="expected sweep (Hz), for the ideal line")
    ap.add_argument("--pw", type=float, default=50e-6, help="expected pulse width (s), for the ideal line")
    ap.add_argument("--pris", type=int, default=3, help="PRIs shown in the envelope panel")
    ap.add_argument("--label", default=None, help="legend name for FILE")
    ap.add_argument("--ref", default=None, help="second IQ file to overlay in panels 3 and 4")
    ap.add_argument("--ref-rate", type=float, default=None)
    ap.add_argument("--ref-label", default="reference")
    ap.add_argument("--title", default=None)
    ap.add_argument("--out", default=None, help="PNG path (default: FILE with .png)")
    a = ap.parse_args()

    fs = a.fullscale or (32768.0 if a.dtype == "int16" else 1.0)
    x = load(a.file, a.dtype, int(a.skip * a.rate))
    m = measure(x, a.rate, fs)
    if m.get("mode") != "pulse":
        sys.exit(f"no pulses found in {a.file} (mode {m.get('mode')}); nothing to plot")
    starts, stops = find_pulses(x, a.rate)
    label = a.label or os.path.basename(a.file)

    ref = None
    if a.ref:
        rr = a.ref_rate or a.rate
        xr = load(a.ref, a.dtype, int(a.skip * rr))
        rs, re_ = find_pulses(xr, rr)
        if rs.size:
            ref = (xr, rr, rs, re_)
        else:
            print(f"warning: no pulses in reference {a.ref}; not overlaid", file=sys.stderr)

    fig, axs = plt.subplots(4, 1, figsize=(10, 13), facecolor=SURF)
    summary = (f"PW {m['pw_us']:.2f} µs   PRI {m.get('pri_ms', float('nan')):.3f} ms   "
               f"chirp {abs(m.get('chirp_bw_mhz', float('nan'))):.3f} MHz   duty {m.get('duty_pct', float('nan')):.2f} %   "
               f"\npulse top {m['top_dbfs']:.1f} dBFS   "
               + (f"SNR {m['snr_db']} dB" if m.get('snr_db') is not None else "noise-free (generated)")
               + f"   pulses {m['n_pulses']}")
    fig.suptitle((a.title or label) + "\n" + summary, x=0.06, ha="left", fontsize=12, color=INK)

    # 1. envelope over a few PRIs
    ax = axs[0]
    pri = m.get("pri_ms", 2.0) * 1e-3
    a0 = max(0, starts[0] - int(0.1 * pri * a.rate))
    b0 = min(x.size, a0 + int(a.pris * pri * a.rate))
    env = 20 * np.log10(np.maximum(np.abs(x[a0:b0]) / fs, 1e-6))
    t = np.arange(env.size) / a.rate * 1e3
    ax.plot(t, env, color=BLUE, linewidth=0.8)
    floor = m.get("floor_dbfs")
    lo = -100 if floor is None or not np.isfinite(floor) else floor - 15
    ax.set_ylim(max(lo, -120), 3)
    ax.set_xlabel("time (ms)")
    ax.set_ylabel("|x| (dBFS)")
    style(ax, f"1  Envelope over {a.pris} PRIs  (expect pulses every {pri * 1e3:.3f} ms)")

    # 2. one pulse, I and Q
    ax = axs[1]
    s, e = starts[0], stops[0]
    margin = int(0.2 * (e - s))
    seg = x[max(0, s - margin): e + margin] / fs
    t = (np.arange(seg.size) - min(s, margin)) / a.rate * 1e6
    ax.plot(t, seg.real, color=BLUE, linewidth=1.0, label="I")
    ax.plot(t, seg.imag, color=VIOLET, linewidth=1.0, label="Q")
    ax.set_xlabel("time from pulse start (µs)")
    ax.set_ylabel("amplitude (FS)")
    ax.legend(loc="upper right", fontsize=9, frameon=False, labelcolor=INK)
    style(ax, "2  One pulse, I and Q  (oscillation slows to zero mid-pulse, then speeds up again)")

    # 3. instantaneous frequency
    ax = axs[2]
    core, off = pulse_core(x, starts[0], stops[0])
    tf, f = inst_freq(core, a.rate)
    ax.plot((tf + off / a.rate) * 1e6, f / 1e3, color=BLUE, linewidth=1.6, label=label)
    if ref:
        xr, rr, rs, re_ = ref
        core_r, off_r = pulse_core(xr, rs[0], re_[0])
        tfr, fr = inst_freq(core_r, rr)
        ax.plot((tfr + off_r / rr) * 1e6, fr / 1e3, color=ORANGE, linewidth=1.6, label=a.ref_label)
    ti = np.linspace(0, a.pw, 200)
    ax.plot(ti * 1e6, (-a.chirp_bw / 2 + a.chirp_bw / a.pw * ti) / 1e3, color=INK2,
            linestyle=(0, (4, 3)), linewidth=1.2, label="ideal")
    ax.set_xlabel("time from pulse start (µs)")
    ax.set_ylabel("frequency offset (kHz)")
    ax.legend(loc="upper left", fontsize=9, frameon=False, labelcolor=INK)
    style(ax, f"3  Instantaneous frequency  (ideal: {-a.chirp_bw / 2e3:+.0f} → {a.chirp_bw / 2e3:+.0f} kHz "
              f"over {a.pw * 1e6:.0f} µs)")

    # 4. spectrum
    ax = axs[3]
    f, psd = spectrum(x, a.rate, starts, stops)
    ax.plot(f / 1e6, psd, color=BLUE, linewidth=1.2, label=label)
    span = 2.0 * a.chirp_bw
    if ref:
        fr, psdr = spectrum(xr, rr, rs, re_)
        if fr is not None:
            ax.plot(fr / 1e6, psdr, color=ORANGE, linewidth=1.2, label=a.ref_label)
            span = min(span, rr / 2)
    span = min(span, a.rate / 2)
    for edge in (-a.chirp_bw / 2, a.chirp_bw / 2):
        ax.axvline(edge / 1e6, color=INK2, linestyle=(0, (4, 3)), linewidth=1.0)
    ax.set_xlim(-span / 1e6, span / 1e6)
    ax.set_ylim(-60, 3)
    ax.set_xlabel("frequency offset from carrier (MHz)")
    ax.set_ylabel("power (dB rel. peak)")
    ax.legend(loc="upper right", fontsize=9, frameon=False, labelcolor=INK)
    style(ax, f"4  Spectrum, averaged over pulses  (dashed: ±{a.chirp_bw / 2e6:.2f} MHz sweep edges)")

    fig.tight_layout(rect=(0, 0, 1, 0.94))
    out = a.out or os.path.splitext(a.file)[0] + ".png"
    fig.savefig(out, dpi=130, facecolor=SURF)
    print(out)


if __name__ == "__main__":
    main()
