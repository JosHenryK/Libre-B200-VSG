#!/usr/bin/env python3
"""LibreSDR TX gain <-> true dBm calibration, using a real VSG as the reference.

Substitution method: the EPIQ is only a transfer standard. With the EPIQ's gain
fixed, the VSG (known dBm) and the LibreSDR (known gain) are connected in turn
at the SAME reference plane, and the EPIQ's reading converts one into the other.

build   cal_points.csv  ->  cal_table.csv
  cal_points.csv columns:
    source         vsg | sdr
    segment        label for one fixed EPIQ RX gain setting (e.g. g0, g20)
    setting        vsg: output level in dBm   sdr: UHD TX gain in dB
    ampl           sdr: digital amplitude used (0-1]; blank for vsg
    measured_dbfs  EPIQ reading (top_dbfs from measure_iq.py)
  Each segment needs >= 2 VSG points; the offset K = measured - dBm is taken
  from them and applied to the SDR points in the same segment. Use more than one
  segment to cover a gain span wider than the EPIQ's linear range.

  cal_table.csv columns: gain_db, dbm_fs
    dbm_fs = output power for a full-scale (ampl = 1.0) constant-envelope signal.
    Power for another amplitude = dbm_fs + 20*log10(ampl).

gain-for TABLE DBM [--ampl A]   print the TX gain that gives DBM
dbm-for  TABLE GAIN [--ampl A]  print the dBm a TX gain gives
"""
import argparse
import csv
import math
import sys
from collections import defaultdict

import numpy as np

LINEARITY_TOL_DB = 0.5   # flag VSG points further than this from the segment fit
OVERLAP_TOL_DB = 0.5     # flag gains where two segments disagree by more than this


def build(points_path, table_path):
    vsg = defaultdict(list)
    sdr = defaultdict(list)
    with open(points_path, newline="") as f:
        for row in csv.DictReader(f):
            src = row["source"].strip().lower()
            seg = row["segment"].strip()
            setting = float(row["setting"])
            meas = float(row["measured_dbfs"])
            if src == "vsg":
                vsg[seg].append((setting, meas))
            elif src == "sdr":
                ampl = float(row["ampl"])
                if not 0 < ampl <= 1:
                    sys.exit(f"bad ampl {ampl} in row {row}")
                sdr[seg].append((setting, ampl, meas))
            else:
                sys.exit(f"unknown source {src!r}")

    warnings = []
    by_gain = defaultdict(list)
    for seg, pts in sdr.items():
        ref = vsg.get(seg, [])
        if len(ref) < 2:
            sys.exit(f"segment {seg!r} has {len(ref)} VSG points; need at least 2")
        dbm = np.array([r[0] for r in ref])
        meas = np.array([r[1] for r in ref])
        slope, icpt = np.polyfit(dbm, meas, 1)
        resid = meas - (slope * dbm + icpt)
        if abs(slope - 1) > 0.05:
            warnings.append(f"segment {seg}: EPIQ slope {slope:.3f} dB/dB (expect 1.000) -> compressed or noise-limited")
        for (d, m), r in zip(ref, resid):
            if abs(r) > LINEARITY_TOL_DB:
                warnings.append(f"segment {seg}: VSG {d:+.1f} dBm is {r:+.2f} dB off the fit")
        k = float(np.mean(meas - dbm))
        lo, hi = float(meas.min()), float(meas.max())
        print(f"segment {seg}: K = {k:+.3f} dB (dBFS - dBm), VSG span {dbm.min():+.1f}..{dbm.max():+.1f} dBm, "
              f"fit residual rms {float(np.sqrt(np.mean(resid**2))):.3f} dB")
        for gain, ampl, m in pts:
            if m < lo - 3 or m > hi + 3:
                warnings.append(f"segment {seg}: SDR gain {gain} reads {m:.1f} dBFS, outside the VSG-verified "
                                f"range {lo:.1f}..{hi:.1f} dBFS (+/-3 dB)")
            by_gain[gain].append((seg, m - k - 20 * math.log10(ampl)))

    rows = []
    for gain in sorted(by_gain):
        vals = [v for _, v in by_gain[gain]]
        if len(vals) > 1 and max(vals) - min(vals) > OVERLAP_TOL_DB:
            segs = ", ".join(f"{s}:{v:+.2f}" for s, v in by_gain[gain])
            warnings.append(f"gain {gain}: segments disagree ({segs})")
        rows.append((gain, float(np.mean(vals))))

    dbms = [r[1] for r in rows]
    if any(b <= a for a, b in zip(dbms, dbms[1:])):
        warnings.append("dBm is not strictly increasing with gain; gain-for lookups may be ambiguous")

    with open(table_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["gain_db", "dbm_fs"])
        for g, d in rows:
            w.writerow([f"{g:.2f}", f"{d:.3f}"])

    print(f"\nwrote {table_path}: {len(rows)} gains, {rows[0][1]:+.2f} .. {rows[-1][1]:+.2f} dBm at full scale")
    if len(rows) > 1:
        g = np.array([r[0] for r in rows]); d = np.array([r[1] for r in rows])
        print(f"average slope {np.polyfit(g, d, 1)[0]:.3f} dB per gain dB (AD9361 nominal 1.000)")
    for msg in warnings:
        print("WARNING:", msg)
    return 1 if warnings else 0


def load_table(path):
    g, d = [], []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            g.append(float(row["gain_db"]))
            d.append(float(row["dbm_fs"]))
    if len(g) < 2:
        sys.exit("calibration table needs at least 2 rows")
    return np.array(g), np.array(d)


def gain_for(table, dbm, ampl):
    g, d = load_table(table)
    if np.any(np.diff(d) <= 0):
        sys.exit("table is not monotonic; rebuild it before inverting")
    want = dbm - 20 * math.log10(ampl)
    if not d[0] <= want <= d[-1]:
        lo, hi = d[0] + 20 * math.log10(ampl), d[-1] + 20 * math.log10(ampl)
        sys.exit(f"{dbm:+.2f} dBm is outside the calibrated range {lo:+.2f}..{hi:+.2f} dBm at ampl {ampl}; "
                 "no extrapolation")
    # UHD sets B200 TX gain in 0.25 dB steps.
    print(f"{round(float(np.interp(want, d, g)) * 4) / 4:.2f}")


def dbm_for(table, gain, ampl):
    g, d = load_table(table)
    if not g[0] <= gain <= g[-1]:
        sys.exit(f"gain {gain} is outside the calibrated range {g[0]}..{g[-1]}; no extrapolation")
    print(f"{float(np.interp(gain, g, d)) + 20 * math.log10(ampl):.2f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("points"); b.add_argument("table")
    gf = sub.add_parser("gain-for"); gf.add_argument("table"); gf.add_argument("dbm", type=float)
    gf.add_argument("--ampl", type=float, default=0.7)
    df = sub.add_parser("dbm-for"); df.add_argument("table"); df.add_argument("gain", type=float)
    df.add_argument("--ampl", type=float, default=0.7)
    a = ap.parse_args()
    if a.cmd == "build":
        sys.exit(build(a.points, a.table))
    if a.cmd == "gain-for":
        gain_for(a.table, a.dbm, a.ampl)
    else:
        dbm_for(a.table, a.gain, a.ampl)


if __name__ == "__main__":
    main()
