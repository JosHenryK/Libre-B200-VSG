#!/usr/bin/env python3
"""Measure power and pulse parameters in an IQ capture (e.g. from the EPIQ).

Reports, as one JSON object:
  mean_dbfs       average power over the whole capture
  top_dbfs        pulse-top (peak envelope) power, noise-corrected  [pulse mode]
  pw_us, pri_ms, duty_pct, n_pulses                                  [pulse mode]
  chirp_bw_mhz    swept bandwidth estimated from instantaneous frequency
  snr_db          pulse-top power over the between-pulse floor

dBFS is relative to a full-scale complex sample (|x| = fullscale). Swapped I/Q
(some receivers store Q first) does not change any power value; it only flips
the sign of chirp_bw_mhz.

Usage:
  measure_iq.py capture.iq --rate 40e6 [--dtype int16|float32] [--fullscale 32768]
"""
import argparse
import json
import sys

import numpy as np


def load(path, dtype, skip):
    raw = np.fromfile(path, dtype=np.int16 if dtype == "int16" else np.float32)
    if raw.size % 2:
        raw = raw[:-1]
    x = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    return x[skip:]


def runs(mask):
    """Start/stop indices of True runs in a boolean array."""
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    return np.flatnonzero(d == 1), np.flatnonzero(d == -1)


def db(v):
    return float(10 * np.log10(v)) if v > 0 else float("-inf")


def measure(x, rate, fullscale):
    p = (np.abs(x) / fullscale) ** 2
    peak_dbfs = db(p.max())
    out = {"n_samples": int(x.size), "mean_dbfs": round(db(p.mean()), 3),
           "peak_dbfs": round(peak_dbfs, 2),
           # Within ~1 dB of full scale on I or Q: the receiver is probably clipping.
           "clipping": bool(max(np.abs(x.real).max(), np.abs(x.imag).max()) >= 0.89 * fullscale)}

    # Smooth the envelope over ~0.5 us so noise does not split pulses.
    w = max(1, int(round(0.5e-6 * rate)))
    ps = np.convolve(p, np.ones(w) / w, mode="same")
    peak = np.percentile(ps, 99.9)
    floor = np.percentile(ps, 10)
    if peak <= 0:
        out["mode"] = "empty"
        return out

    on = ps > peak / 4  # 6 dB below the pulse top
    on_frac = on.mean()
    if on_frac > 0.95 or peak / max(floor, 1e-30) < 10:
        out["mode"] = "cw"
        out["top_dbfs"] = out["mean_dbfs"]
        return out

    starts, stops = runs(on)
    # Drop pulses cut off by the capture edges.
    keep = (starts > 0) & (stops < p.size)
    starts, stops = starts[keep], stops[keep]
    if starts.size == 0:
        out["mode"] = "pulse-unresolved"
        return out

    # The -6 dB crossing of the boxcar-smoothed edge sits ~(w-1)/4 samples
    # outside the true edge on each side; remove that widening.
    widths = stops - starts - (w - 1) / 2
    tops, freqs_bw = [], []
    for s, e in zip(starts, stops):
        n = e - s
        a, b = s + n // 10, e - n // 10  # central 80 % = the flat pulse top
        if b <= a:
            continue
        tops.append(p[a:b].mean())
        ph = np.unwrap(np.angle(x[a:b]))
        if ph.size > 8:
            t = np.arange(ph.size) / rate
            slope = np.polyfit(t, ph, 2)[0] * 2 / (2 * np.pi)  # Hz/s
            freqs_bw.append(slope * n / rate)

    off = ~np.convolve(on, np.ones(4 * w + 1), mode="same").astype(bool)
    noise = p[off].mean() if off.any() else 0.0
    top = float(np.median(tops)) if tops else float("nan")

    out.update(
        mode="pulse",
        n_pulses=int(starts.size),
        top_dbfs=round(db(max(top - noise, 1e-30)), 3),
        top_raw_dbfs=round(db(top), 3),
        floor_dbfs=round(db(noise), 3),
        snr_db=round(db(top) - db(noise), 1) if noise > 0 else None,
        pw_us=round(float(np.median(widths)) / rate * 1e6, 3),
    )
    # Noise alone also crosses the threshold, in short random blips. Real
    # pulses stand well above the floor and are many smoothing windows long.
    if (out["snr_db"] is not None and out["snr_db"] < 6) or np.median(widths) < 4 * w:
        out["mode"] = "noise"
        return out
    if starts.size > 1:
        pri = float(np.median(np.diff(starts))) / rate
        out["pri_ms"] = round(pri * 1e3, 4)
        out["pri_jitter_us"] = round(float(np.std(np.diff(starts))) / rate * 1e6, 3)
        out["duty_pct"] = round(100 * out["pw_us"] * 1e-6 / pri, 3)
    if freqs_bw:
        out["chirp_bw_mhz"] = round(float(np.median(freqs_bw)) / 1e6, 4)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--rate", type=float, required=True, help="capture sample rate (S/s)")
    ap.add_argument("--dtype", choices=["int16", "float32"], default="int16")
    ap.add_argument("--fullscale", type=float, default=None,
                    help="amplitude of a full-scale sample (default 32768 for int16, 1.0 for float32)")
    ap.add_argument("--skip", type=float, default=0.01,
                    help="seconds to drop from the start (receiver settling)")
    a = ap.parse_args()
    fs = a.fullscale or (32768.0 if a.dtype == "int16" else 1.0)
    x = load(a.file, a.dtype, int(a.skip * a.rate))
    if x.size == 0:
        sys.exit("capture is empty after --skip")
    print(json.dumps(measure(x, a.rate, fs)))


if __name__ == "__main__":
    main()
