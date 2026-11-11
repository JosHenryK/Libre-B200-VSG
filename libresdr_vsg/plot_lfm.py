#!/usr/bin/env python3
"""Plot the pulse train lfm_tx sends: the repeating pulses, and one pulse up close.

Usage: plot_lfm.py samples.iq rate_sps pw_us pri_ms out.png
"""
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

BLUE, VIOLET, INK2, GRID = "#2a78d6", "#6250d6", "#52514e", "#e4e3df"

path, rate, pw_us, pri_ms, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
raw = np.fromfile(path, dtype=np.int16).astype(float) / 32767
x = raw[0::2] + 1j * raw[1::2]
s = int(np.flatnonzero(np.abs(x) > 0.01)[0])  # first pulse start

fig, (top, bot) = plt.subplots(2, 1, figsize=(10, 6.5))
fig.suptitle(f"lfm_tx signal: 5.18 GHz, {rate / 1e6:g} MS/s, 1 MHz LFM, {pw_us:g} µs pulse, {pri_ms:g} ms PRI",
             x=0.06, ha="left", fontsize=12)

# Pulse train: the same pulse every PRI, repeated until Ctrl-C.
# The waveform repeats every PRI, so indices wrap around the buffer.
lead = int(0.1 * pri_ms * 1e-3 * rate)
idx = np.arange(s - lead, s - lead + int(4 * pri_ms * 1e-3 * rate))
t = (idx - s) / rate * 1e3
top.plot(t, np.abs(x[idx % x.size]), color=BLUE, linewidth=1)
top.set_xlabel("time (ms)")
top.set_ylabel("amplitude")
top.set_title(f"Pulse train: one {pw_us:g} µs pulse every {pri_ms:g} ms, repeating", loc="left", fontsize=11)

# One pulse: I and Q of the chirp.
m = int(0.1 * pw_us * 1e-6 * rate)
w = int(pw_us * 1e-6 * rate)
idx = np.arange(s - m, s + w + m)
seg = x[idx % x.size]
t = (idx - s) / rate * 1e6
bot.plot(t, seg.real, color=BLUE, linewidth=1, label="I")
bot.plot(t, seg.imag, color=VIOLET, linewidth=1, label="Q")
bot.set_xlabel("time from pulse start (µs)")
bot.set_ylabel("amplitude")
bot.set_title("One pulse: 1 MHz linear chirp, -0.5 MHz to +0.5 MHz", loc="left", fontsize=11)
bot.legend(loc="upper right", frameon=False)

for ax in (top, bot):
    ax.grid(True, color=GRID, linewidth=0.6)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.tick_params(colors=INK2)

fig.tight_layout(rect=(0, 0, 1, 0.95))
fig.savefig(out, dpi=130)
print(out)
