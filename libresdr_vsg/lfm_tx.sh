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

# USB state of the LibreSDR (USB vendor 0x2500 = 9472), printed as "<name>|<Mb/s>".
# Before UHD loads its firmware the board enumerates as "WestBridge" at 480 Mb/s, even on
# a USB 3 port; once firmware is loaded it re-enumerates as "USRP B2xx" at its real speed.
# So a WestBridge reading means "load firmware", never "USB 2 link". If several entries
# match (e.g. a stale WestBridge entry next to the new one), the USRP entry wins.
pick_usb_state() {
  awk -F'|' 'NF == 2 && $2 != "" { if ($1 !~ /WestBridge/ && !best) best = $0; if (!first) first = $0 }
             END { if (best) print best; else if (first) print first }'
}
usb_state() {
  local s=""
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # One record per device node; name, link speed and vendor are read from that node only.
    s="$(ioreg -p IOUSB -l -w0 2>/dev/null | awk '
      function emit() { if (v && sp != "") print name "|" sp / 1e6 }
      /\+-o / { emit(); name = $0; sub(/^.*\+-o /, "", name); sub(/@.*$/, "", name); sp = ""; v = 0; next }
      /"UsbLinkSpeed" = / { sp = $NF }
      /"idVendor" = 9472$/ { v = 1 }
      END { emit() }' | pick_usb_state)"
    if [[ -z "$s" ]]; then
      # Fallback: system_profiler. A line ending in ":" starts a new device section.
      s="$(system_profiler SPUSBHostDataType 2>/dev/null | awk '
        function emit() { if (v && sp != "") print name "|" sp }
        /^ *[^:]+:$/ { emit(); name = $0; gsub(/^ +|:$/, "", name); sp = ""; v = 0; next }
        /Link Speed:/ { sp = $3; if ($4 ~ /^Gb/) sp = $3 * 1000 }
        /USB Vendor ID: 0x2500/ { v = 1 }
        END { emit() }' | pick_usb_state)"
    fi
  else
    local d
    s="$(for d in /sys/bus/usb/devices/*; do
           [[ "$(cat "$d/idVendor" 2>/dev/null)" == "2500" ]] || continue
           echo "$(cat "$d/product" 2>/dev/null)|$(cat "$d/speed" 2>/dev/null)"
         done | pick_usb_state)"
  fi
  [[ -n "$s" ]] && echo "$s"
}
needs_firmware() { [[ -z "$1" || "${1%%|*}" == *WestBridge* ]]; }

# uhd_find_devices from the SAME UHD install that tx_lfm_pulse is linked against. A second
# UHD (e.g. MacPorts in /opt/local, often first on PATH) would load its own, different
# firmware into the board, which the Homebrew-built tx_lfm_pulse then has to stream through.
uhd_find_for_tx() {
  local lib="" c
  if [[ "$(uname -s)" == "Darwin" ]]; then
    lib="$(otool -L "$TX_BIN" 2>/dev/null | awk '/libuhd/ { print $1; exit }')"
  else
    lib="$(ldd "$TX_BIN" 2>/dev/null | awk '/libuhd/ { print $3; exit }')"
  fi
  for c in ${lib:+"$(dirname "$lib")/../bin/uhd_find_devices"} \
           /opt/homebrew/bin/uhd_find_devices /home/linuxbrew/.linuxbrew/bin/uhd_find_devices \
           "$(command -v uhd_find_devices || true)"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return; }
  done
}

STATE="$(usb_state || true)"
if needs_firmware "$STATE"; then
  # No firmware yet (or board not visible): load it (no RF), then wait for the board to
  # drop off USB and come back as "USRP B2xx" at its real link speed.
  echo "Loading LibreSDR firmware..." >&2
  UHD_FIND="$(uhd_find_for_tx)"
  [[ -n "$UHD_FIND" ]] || die "uhd_find_devices not found (needed to load the LibreSDR firmware)."
  "$UHD_FIND" --args type=b200 >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    STATE="$(usb_state || true)"
    needs_firmware "$STATE" || break
  done
fi
USB_NAME="${STATE%%|*}"
SPEED="${STATE#*|}"
if [[ -z "$STATE" ]]; then
  echo "WARNING: could not read the USB link speed; transmitting anyway (an underflow warning appears if USB is too slow)." >&2
elif [[ "$USB_NAME" == *WestBridge* ]]; then
  die "LibreSDR firmware did not load (board still shows as WestBridge).
       Check that usrp_b200_fw.hex is installed (see README), then unplug/replug and retry."
elif awk -v s="$SPEED" 'BEGIN { exit !(s < 5000) }'; then
  die "LibreSDR is on a ${SPEED} Mb/s (USB 2) link; 40 MS/s needs USB 3.
       Use a USB 3 cable plugged straight into the Mac (no hub, no USB 2 adapter)."
fi

# Plot the exact samples that will be transmitted.
# The plot is a convenience: if it fails (e.g. matplotlib missing) warn and still transmit.
mkdir -p "$OUT"
tag="40MSps_${PW_US}us"
PRI_MS="$(awk -v p="$PRI" 'BEGIN { printf "%g", p * 1e3 }')"
if "$TX_BIN" --rate "$RATE" --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI" --ampl "$AMPL" \
     --dump "${OUT}/lfm_${tag}.iq" >/dev/null \
   && python3 -I "${LIB}/plot_lfm.py" "${OUT}/lfm_${tag}.iq" "$RATE" "$PW_US" "$PRI_MS" "${OUT}/lfm_${tag}.png" >/dev/null; then
  echo "Plot: ${OUT}/lfm_${tag}.png"
  if [[ "$(uname -s)" == "Darwin" && -z "${LFM_NO_OPEN:-}" ]]; then
    open "${OUT}/lfm_${tag}.png" || true
    sleep 1   # let Preview finish launching before the 160 MB/s stream starts
  fi
else
  echo "WARNING: could not make the waveform plot (see above); transmitting anyway." >&2
fi

echo "TXA: 5.18 GHz, 40 MS/s, 1 MHz LFM, ${PW_US} us pulse, 2 ms PRI, TX gain ${GAIN} dB. Ctrl-C to stop."
# num_send_frames: a much deeper USB send queue than UHD's default, so a short
# stall on the Mac (an app opening, a window redraw) doesn't starve the radio.
# tx_lfm_pulse exit codes: 0 ok, 3 underflows, 5 USB link failed.
exec "$TX_BIN" --args="type=b200,num_send_frames=${LFM_SEND_FRAMES:-256}" --mode lfm --freq "$FREQ" --rate "$RATE" --gain "$GAIN" --ampl "$AMPL" \
  --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI"
