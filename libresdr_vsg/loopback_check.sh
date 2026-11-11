#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the LibreSDR transmitter BEFORE connecting it to the EPIQ, by
# looping its TX back into its own RX through a fixed attenuator:
#
#   LibreSDR TX port -> attenuator (>= 30 dB) -> LibreSDR RX port
#
# For each TX gain it transmits the pulsed LFM, records the RX at the same
# time, and checks pulse width, PRI, chirp bandwidth, clipping, underflows,
# and that power changes 1 dB per 1 dB of TX gain.
#
# Usage:
#   loopback_check <inline_atten_db> [tx_gain_db ...]      (default gains: 60 65 70 75 80)
#
# Environment (defaults shown):
#   LB_FREQ=5.18e9  LB_RATE=4e6  LB_RX_GAIN=30  LB_PW=50e-6  LB_PRI=2e-3  LB_CHIRP_BW=1e6
#   VSG_SDR_NAME=<name>   skip the device prompt
#   LB_RATE 4e6 keeps TX + RX together inside USB 2 bandwidth; on USB 3 you can use 20e6+.

FREQ="${LB_FREQ:-5.18e9}"
RATE="${LB_RATE:-4e6}"
RX_GAIN="${LB_RX_GAIN:-30}"
PW="${LB_PW:-50e-6}"
PRI="${LB_PRI:-2e-3}"
CHIRP_BW="${LB_CHIRP_BW:-1e6}"
AMPL="${LB_AMPL:-0.7}"
MIN_ATTEN=30
LIB="${HOME}/.local/lib/b220-tx"
TX_BIN="${LIB}/build/tx_lfm_pulse"
MEASURE="${LIB}/measure_iq.py"
OUTDIR="${HOME}/libresdr_loopback/$(date +%Y%m%d_%H%M%S)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid number: $1"; }

[[ "$#" -ge 1 ]] || { sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
ATTEN="$1"; shift
GAINS=("$@"); [[ "${#GAINS[@]}" -gt 0 ]] || GAINS=(60 65 70 75 80)
for v in "$ATTEN" "$FREQ" "$RATE" "$RX_GAIN" "$PW" "$PRI" "$CHIRP_BW" "$AMPL" "${GAINS[@]}"; do num "$v"; done
awk -v a="$ATTEN" -v m="$MIN_ATTEN" 'BEGIN { exit !(a >= m) }' \
  || die "Attenuation ${ATTEN} dB is below ${MIN_ATTEN} dB. The LibreSDR's own RX input can be damaged too."
for g in "${GAINS[@]}"; do
  awk -v g="$g" 'BEGIN { exit !(g >= 0 && g <= 89.75) }' || die "TX gain $g is outside 0-89.75 dB."
done
[[ -x "$TX_BIN" ]] || die "tx_lfm_pulse not built. Run setup_tx.sh."
[[ -f "$MEASURE" ]] || die "measure_iq.py not installed. Run setup_tx.sh."

if [[ -z "${UHD_IMAGES_DIR:-}" && -d "${HOME}/.local/share/uhd/images" ]]; then
  export UHD_IMAGES_DIR="${HOME}/.local/share/uhd/images"
fi
UHD_FIND="$(command -v uhd_find_devices || true)"
for c in /opt/homebrew/bin/uhd_find_devices /home/linuxbrew/.linuxbrew/bin/uhd_find_devices; do
  [[ -n "$UHD_FIND" ]] || { [[ -x "$c" ]] && UHD_FIND="$c"; }
done
[[ -n "$UHD_FIND" ]] || die "uhd_find_devices not found."
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed."
if [[ -n "${VSG_SDR_NAME:-}" ]]; then
  SDR_NAME="$VSG_SDR_NAME"
else
  printf '%s\n' "$DEVICE_LIST"
  read -r -p "Name of the SDR (as listed above): " SDR_NAME
fi
grep -Fq "name: $SDR_NAME" <<< "$DEVICE_LIST" || die "SDR name '$SDR_NAME' was not listed."

echo
echo "Loopback cabling required:"
echo "  LibreSDR TX port -> ${ATTEN} dB attenuator -> LibreSDR RX port   (nothing else connected)"
read -r -p "Cabling verified? [y/N]: " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || die "Cancelled."

mkdir -p "$OUTDIR"
RESULTS="${OUTDIR}/results.jsonl"
: > "$RESULTS"
echo
echo "Captures and results: $OUTDIR"

for g in "${GAINS[@]}"; do
  cap="${OUTDIR}/loopback_gain${g}.iq"
  log="${OUTDIR}/loopback_gain${g}.log"
  printf 'TX gain %-6s ... ' "$g"
  set +e
  "$TX_BIN" --args="type=b200,name=$SDR_NAME" --mode lfm --freq "$FREQ" --rate "$RATE" \
    --gain "$g" --ampl "$AMPL" --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI" \
    --rx-file "$cap" --rx-gain "$RX_GAIN" --rx-seconds 0.05 >"$log" 2>&1
  st=$?
  set -e
  if [[ ! -s "$cap" ]]; then
    echo "no capture (exit $st); see $log"
    printf '{"gain": %s, "tx_exit": %s, "error": "no capture"}\n' "$g" "$st" >> "$RESULTS"
    continue
  fi
  m="$(python3 -I "$MEASURE" "$cap" --rate "$RATE" --skip 0)"
  printf '{"gain": %s, "tx_exit": %s, "m": %s}\n' "$g" "$st" "$m" >> "$RESULTS"
  echo "done (exit $st)"
done

python3 -I - "$RESULTS" "$PW" "$PRI" "$CHIRP_BW" <<'PY'
import json, sys
path, pw, pri, bw = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
rows = [json.loads(l) for l in open(path)]
fails = []
print()
print(f"{'gain':>6} {'top dBFS':>9} {'step':>6} {'PW us':>8} {'PRI ms':>8} {'BW MHz':>7} {'SNR':>6}  notes")
prev = None
for r in rows:
    g = r["gain"]
    if "m" not in r:
        print(f"{g:>6}  no capture"); fails.append(f"gain {g}: no capture"); continue
    m, notes = r["m"], []
    if r["tx_exit"] == 3: notes.append("TX underflow"); fails.append(f"gain {g}: TX underflow")
    elif r["tx_exit"] == 4: notes.append("RX overflow"); fails.append(f"gain {g}: RX overflow")
    elif r["tx_exit"] not in (0,): notes.append(f"exit {r['tx_exit']}"); fails.append(f"gain {g}: exit {r['tx_exit']}")
    if m.get("clipping"): notes.append("RX CLIPPING: lower LB_RX_GAIN"); fails.append(f"gain {g}: RX clipping")
    if m.get("mode") != "pulse":
        print(f"{g:>6} {m.get('mean_dbfs', 0):>9.2f}  no pulses found ({m.get('mode')}) - check ports/cable")
        fails.append(f"gain {g}: no pulses (mode {m.get('mode')})"); prev = None; continue
    top = m["top_dbfs"]
    step = ""
    if prev is not None:
        d, dg = top - prev[1], g - prev[0]
        step = f"{d:+.2f}"
        if abs(d - dg) > 1.0:
            notes.append(f"expected {dg:+.1f} dB"); fails.append(f"gain {g}: step {d:+.2f} dB vs {dg:+.1f}")
    if abs(m["pw_us"] - pw * 1e6) > max(1.0, 0.02 * pw * 1e6): fails.append(f"gain {g}: PW {m['pw_us']} us")
    if "pri_ms" in m and abs(m["pri_ms"] - pri * 1e3) > 0.001 * pri * 1e3: fails.append(f"gain {g}: PRI {m['pri_ms']} ms")
    if "chirp_bw_mhz" in m and abs(abs(m["chirp_bw_mhz"]) - bw / 1e6) > 0.05 * bw / 1e6:
        fails.append(f"gain {g}: chirp BW {m['chirp_bw_mhz']} MHz")
    if (m.get("snr_db") or 0) < 20: notes.append("low SNR")
    print(f"{g:>6} {top:>9.2f} {step:>6} {m['pw_us']:>8.2f} {m.get('pri_ms', float('nan')):>8.3f} "
          f"{m.get('chirp_bw_mhz', float('nan')):>7.3f} {str(m.get('snr_db')):>6}  {'; '.join(notes)}")
    prev = (g, top)
print()
if fails:
    print("LOOPBACK CHECK: FAIL"); [print("  -", f) for f in fails]; sys.exit(1)
print("LOOPBACK CHECK: PASS  (waveform timing, chirp, gain steps and streaming all as expected)")
PY
