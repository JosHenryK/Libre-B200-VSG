#!/usr/bin/env bash
set -Eeuo pipefail

# lfm_tx - transmit the pulsed LFM on LibreSDR channel A (TXA) until Ctrl-C.
#
#   5.18 GHz, 40 MS/s, 1 MHz linear chirp, 50 us pulse, 2 ms PRI
#
# Usage:   lfm_tx <tx_gain_db> [pulse_width_us]
#          lfm_tx 70          (50 us pulse)
#          lfm_tx 70 200      (200 us pulse)
#
# It first saves and opens a plot of the exact samples it sends (~/libresdr_tx/).
# Keep the 30 dB attenuator and DC block on TXA. Needs a USB 3 connection.

FREQ=5.18e9
RATE=40e6
CHIRP_BW=1e6
PRI=2e-3
AMPL=0.7
LIB="${HOME}/.local/lib/b220-tx"
TX_BIN="${LIB}/build/tx_lfm_pulse"
OUT="${HOME}/libresdr_tx"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || { sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
GAIN="$1"
PW_US="${2:-50}"
[[ "$GAIN" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v g="$GAIN" 'BEGIN { exit !(g <= 89.75) }' \
  || die "TX gain must be 0-89.75 dB (got '$GAIN')."
[[ "$PW_US" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v p="$PW_US" 'BEGIN { exit !(p > 0 && p < 2000) }' \
  || die "Pulse width must be between 0 and 2000 us (got '$PW_US')."
PW="$(awk -v p="$PW_US" 'BEGIN { printf "%.9g", p * 1e-6 }')"
[[ -x "$TX_BIN" ]] || die "tx_lfm_pulse not built. Run setup_tx.sh once."
if [[ -z "${UHD_IMAGES_DIR:-}" && -d "${HOME}/.local/share/uhd/images" ]]; then
  export UHD_IMAGES_DIR="${HOME}/.local/share/uhd/images"
fi
export UHD_LOG_CONSOLE_LEVEL="${UHD_LOG_CONSOLE_LEVEL:-warning}"   # hide UHD's start-up chatter

# USB link speed (Mb/s) of the LibreSDR (USB vendor 0x2500 = 9472).
usb_mbps() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local s
    s="$(system_profiler SPUSBHostDataType 2>/dev/null \
      | awk '/USRP B2/ { f = 1 } f && /Link Speed:/ { v = $3; u = $4; print (u ~ /^Gb/ ? v * 1000 : v); exit }')"
    [[ -n "$s" ]] || s="$(ioreg -p IOUSB -l -w0 2>/dev/null \
      | awk '/\+-o / { sp = ""; v = 0 } /"UsbLinkSpeed"/ { sp = $NF } /"idVendor" = 9472/ { v = 1 }
             v && sp != "" { print sp / 1e6; exit }')"
    [[ -n "$s" ]] && echo "$s"
  else
    for d in /sys/bus/usb/devices/*; do
      [[ "$(cat "$d/idVendor" 2>/dev/null)" == "2500" ]] && { cat "$d/speed"; return; }
    done
  fi
}
SPEED="$(usb_mbps || true)"
if [[ -z "$SPEED" ]]; then
  # Freshly plugged in, the board shows up as "WestBridge" (no firmware yet) and only
  # reports its real link speed once UHD has loaded firmware. Load it (no RF), then re-check.
  uhd_find_devices --args type=b200 >/dev/null 2>&1 || true
  sleep 2
  SPEED="$(usb_mbps || true)"
fi
if [[ -z "$SPEED" ]]; then
  echo "WARNING: could not read the USB link speed; transmitting anyway (an underflow warning appears if USB is too slow)." >&2
elif awk -v s="$SPEED" 'BEGIN { exit !(s < 5000) }'; then
  die "LibreSDR is on a ${SPEED} Mb/s (USB 2) link; 40 MS/s needs USB 3.
       Use a USB 3 cable plugged straight into the Mac (no hub, no USB 2 adapter)."
fi

# Plot the exact samples that will be transmitted.
mkdir -p "$OUT"
tag="40MSps_${PW_US}us"
"$TX_BIN" --rate "$RATE" --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI" --ampl "$AMPL" \
  --dump "${OUT}/lfm_${tag}.iq" >/dev/null
python3 -I "${LIB}/plot_lfm.py" "${OUT}/lfm_${tag}.iq" "$RATE" "$PW_US" 2 "${OUT}/lfm_${tag}.png" >/dev/null
echo "Plot: ${OUT}/lfm_${tag}.png"
[[ "$(uname -s)" == "Darwin" && -z "${LFM_NO_OPEN:-}" ]] && open "${OUT}/lfm_${tag}.png"

echo "TXA: 5.18 GHz, 40 MS/s, 1 MHz LFM, ${PW_US} us pulse, 2 ms PRI, TX gain ${GAIN} dB. Ctrl-C to stop."
# num_send_frames: a much deeper USB send queue than UHD's default, so a short
# stall on the Mac (an app opening, a window redraw) doesn't starve the radio.
exec "$TX_BIN" --args="type=b200,num_send_frames=${LFM_SEND_FRAMES:-256}" --mode lfm --freq "$FREQ" --rate "$RATE" --gain "$GAIN" --ampl "$AMPL" \
  --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI"
