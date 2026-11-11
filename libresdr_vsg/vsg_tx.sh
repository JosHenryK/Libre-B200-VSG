#!/usr/bin/env bash
set -Eeuo pipefail

# Use a LibreSDR B220 Mini as a simple VSG (cabled only, never into an antenna).
#
# Usage:
#   vsg_tx lfm <power_dbm> <duration_s> <inline_atten_db>       calibrated pulsed LFM
#   vsg_tx lfm-gain <tx_gain_db> <duration_s> <inline_atten_db> pulsed LFM at a raw gain
#   vsg_tx cw-gain <tx_gain_db> <duration_s> <inline_atten_db>  CW at a raw gain (calibration)
#   vsg_tx tone <freq_hz> <rate_sps> <tx_gain_db> <duration_s> <inline_atten_db>
#   vsg_tx file <iq_file> <freq_hz> <rate_sps> <tx_gain_db> <duration_s> <inline_atten_db>
#
#   power_dbm       pulse-top (peak) power at the LibreSDR TX port, from the
#                   calibration table in VSG_CAL_TABLE (no table = refused)
#   inline_atten_db total fixed attenuation physically installed between the
#                   LibreSDR TX port and the EPIQ RX port
#
# LFM/CW waveform (environment, defaults shown):
#   VSG_FREQ=5.18e9  VSG_RATE=40e6  VSG_CHIRP_BW=1e6  VSG_PW=50e-6  VSG_PRI=2e-3
#   VSG_AMPL=0.7     VSG_LO_OFFSET=0  VSG_CW_OFFSET=0
#   VSG_CAL_TABLE=~/.config/libresdr_cal/cal_5180MHz.csv
#
# Interlock (environment, defaults shown). Refuses to transmit if the fixed
# attenuation is below VSG_MIN_ATTEN_DB, or the power at the EPIQ input would
# exceed VSG_MAX_AT_DUT_DBM. With a calibration table the estimate is the
# calibrated power; otherwise it is a worst-case bound from VSG_PMAX_DBM.
#   VSG_PMAX_DBM=10  VSG_MAX_AT_DUT_DBM=-20  VSG_MIN_ATTEN_DB=30  VSG_TONE_AMPL=0.3
#
# Unattended use: VSG_SDR_NAME=<name> skips the device prompt, and
# VSG_CABLING_CONFIRMED=1 skips the cabling prompt. Set the second only after
# a person has checked the attenuator is physically in place.
#
# VSG_DRY_RUN=1 prints the settings and runs every safety check, then exits
# without opening the radio.

PMAX_DBM="${VSG_PMAX_DBM:-10}"
MAX_AT_DUT="${VSG_MAX_AT_DUT_DBM:--20}"
MIN_ATTEN="${VSG_MIN_ATTEN_DB:-30}"
TONE_AMPL="${VSG_TONE_AMPL:-0.3}"
LFM_FREQ="${VSG_FREQ:-5.18e9}"
LFM_RATE="${VSG_RATE:-40e6}"
CHIRP_BW="${VSG_CHIRP_BW:-1e6}"
PW="${VSG_PW:-50e-6}"
PRI="${VSG_PRI:-2e-3}"
LFM_AMPL="${VSG_AMPL:-0.7}"
LO_OFFSET="${VSG_LO_OFFSET:-0}"
CW_OFFSET="${VSG_CW_OFFSET:-0}"
CAL_TABLE="${VSG_CAL_TABLE:-${HOME}/.config/libresdr_cal/cal_5180MHz.csv}"
GAIN_MAX="89.75"   # AD9361 TX gain range exposed by UHD for the B200 family

LIB="${HOME}/.local/lib/b220-tx"
BUILD="${LIB}/build"

usage() {
  sed -n '6,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid number: $1"; }
db20() { awk -v a="$1" 'BEGIN { printf "%.2f", 20*log(a)/log(10) }'; }

[[ "$#" -ge 1 ]] || usage
MODE="$1"; shift
IQ_FILE=""; POWER_DBM=""
case "$MODE" in
  lfm)            [[ "$#" -eq 3 ]] || usage; POWER_DBM="$1"; DURATION="$2"; ATTEN="$3"
                  FREQ="$LFM_FREQ"; RATE="$LFM_RATE"; AMPL="$LFM_AMPL" ;;
  lfm-gain|cw-gain) [[ "$#" -eq 3 ]] || usage; GAIN="$1"; DURATION="$2"; ATTEN="$3"
                  FREQ="$LFM_FREQ"; RATE="$LFM_RATE"; AMPL="$LFM_AMPL" ;;
  tone)           [[ "$#" -eq 5 ]] || usage; FREQ="$1"; RATE="$2"; GAIN="$3"; DURATION="$4"; ATTEN="$5"
                  AMPL="$TONE_AMPL" ;;
  file)           [[ "$#" -eq 6 ]] || usage; IQ_FILE="$1"; FREQ="$2"; RATE="$3"; GAIN="$4"; DURATION="$5"; ATTEN="$6"
                  [[ -s "$IQ_FILE" ]] || die "IQ file missing or empty: $IQ_FILE"
                  AMPL="1.0" ;;  # a recording's peak is unknown: assume full scale
  *) usage ;;
esac
for v in "$FREQ" "$RATE" "$DURATION" "$ATTEN" "$AMPL" "$PMAX_DBM" "$MAX_AT_DUT" "$MIN_ATTEN" \
         "$CHIRP_BW" "$PW" "$PRI" "$LO_OFFSET" "$CW_OFFSET" ${GAIN:+"$GAIN"} ${POWER_DBM:+"$POWER_DBM"}; do
  num "$v"
done

if [[ -z "${UHD_IMAGES_DIR:-}" && -d "${HOME}/.local/share/uhd/images" ]]; then
  export UHD_IMAGES_DIR="${HOME}/.local/share/uhd/images"
fi

# --- Resolve gain and estimated output power -------------------------------
CAL_NOTE="worst case, uncalibrated"
if [[ "$MODE" == "lfm" ]]; then
  [[ -s "$CAL_TABLE" ]] || die "No calibration table at $CAL_TABLE. Calibrate first (cw-gain sweep + cal.py build)."
  GAIN="$(python3 -I "${LIB}/cal.py" gain-for "$CAL_TABLE" "$POWER_DBM" --ampl "$AMPL")" \
    || die "Requested power is not reachable within the calibration table."
fi
if [[ -s "$CAL_TABLE" && "$MODE" != "file" && "$MODE" != "tone" ]] \
   && EST_OUT="$(python3 -I "${LIB}/cal.py" dbm-for "$CAL_TABLE" "$GAIN" --ampl "$AMPL" 2>/dev/null)"; then
  CAL_NOTE="calibrated, $(basename "$CAL_TABLE")"
else
  EST_OUT="$(awk -v p="$PMAX_DBM" -v g="$GAIN" -v gm="$GAIN_MAX" -v a="$AMPL" \
    'BEGIN { printf "%.1f", p - (gm - g) + 20*log(a)/log(10) }')"
fi

read -r EST_DUT GAIN_OK ATTEN_OK DUT_OK < <(awk \
  -v o="$EST_OUT" -v g="$GAIN" -v gm="$GAIN_MAX" -v at="$ATTEN" -v lim="$MAX_AT_DUT" -v mina="$MIN_ATTEN" \
  'BEGIN { d = o - at; printf "%.1f %d %d %d\n", d, (g >= 0 && g <= gm), (at >= mina), (d <= lim) }')

echo "=== VSG configuration ==="
echo "Mode:                  $MODE${IQ_FILE:+ ($IQ_FILE)}"
echo "Center frequency:      $FREQ Hz"
echo "Sample rate:           $RATE S/s"
if [[ "$MODE" == lfm* ]]; then
  DUTY_DB="$(awk -v pw="$PW" -v pri="$PRI" 'BEGIN { printf "%.2f", 10*log(pw/pri)/log(10) }')"
  echo "Waveform:              LFM ${CHIRP_BW} Hz over ${PW} s, PRI ${PRI} s (avg = peak ${DUTY_DB} dB)"
fi
[[ -n "$POWER_DBM" ]] && echo "Requested power:       $POWER_DBM dBm pulse-top"
echo "TX gain:               $GAIN dB (range 0-$GAIN_MAX), digital ampl $AMPL ($(db20 "$AMPL") dBFS)"
echo "Inline attenuation:    $ATTEN dB"
echo "LibreSDR output:       $EST_OUT dBm peak ($CAL_NOTE)"
echo "At EPIQ input:         $EST_DUT dBm peak (limit $MAX_AT_DUT dBm)"
echo

[[ "$GAIN_OK" -eq 1 ]]  || die "TX gain must be between 0 and $GAIN_MAX dB."
[[ "$ATTEN_OK" -eq 1 ]] || die "Inline attenuation ${ATTEN} dB is below the ${MIN_ATTEN} dB minimum. Add a fixed attenuator."
[[ "$DUT_OK" -eq 1 ]]   || die "EPIQ input ${EST_DUT} dBm exceeds ${MAX_AT_DUT} dBm. Lower power or add attenuation."

if [[ "${VSG_DRY_RUN:-0}" == "1" ]]; then
  echo "Dry run: all safety checks passed. Nothing was transmitted."
  exit 0
fi

# --- Device selection (same pattern as the collect_* scripts) --------------
UHD_FIND="$(command -v uhd_find_devices || true)"
for c in /opt/homebrew/bin/uhd_find_devices /home/linuxbrew/.linuxbrew/bin/uhd_find_devices; do
  [[ -n "$UHD_FIND" ]] || { [[ -x "$c" ]] && UHD_FIND="$c"; }
done
[[ -x "$UHD_FIND" ]] || die "uhd_find_devices not found."
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed."
if [[ -n "${VSG_SDR_NAME:-}" ]]; then
  SDR_NAME="$VSG_SDR_NAME"
else
  printf '%s\n' "$DEVICE_LIST"
  read -r -p "Name of the SDR to transmit from (as listed above): " SDR_NAME
fi
[[ -n "$SDR_NAME" ]] || die "SDR name cannot be empty."
grep -Fq "name: $SDR_NAME" <<< "$DEVICE_LIST" || die "SDR name '$SDR_NAME' was not listed."

if [[ "${VSG_CABLING_CONFIRMED:-0}" != "1" ]]; then
  echo "Check the cabling before continuing:"
  echo "  LibreSDR TX port -> ${ATTEN} dB fixed attenuator(s) -> (DC block) -> EPIQ RX port"
  echo "  No antennas attached to either radio. EPIQ AGC off, RX gain fixed."
  read -r -p "Cabling verified? [y/N]: " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || die "Cancelled."
fi

ARGS="type=b200,name=$SDR_NAME"
# SIGINT lets UHD send end-of-burst and close the stream cleanly on timeout.
# --preserve-status keeps the program's own exit code (e.g. 3 = underflows).
RUN=(timeout --preserve-status --signal=INT --kill-after=5 "$DURATION")

set +e
case "$MODE" in
  lfm|lfm-gain|cw-gain)
    [[ -x "${BUILD}/tx_lfm_pulse" ]] || die "tx_lfm_pulse not built. Run setup_tx.sh."
    WAVE=lfm; [[ "$MODE" == "cw-gain" ]] && WAVE=cw
    "${RUN[@]}" "${BUILD}/tx_lfm_pulse" --args="$ARGS" --mode "$WAVE" --freq "$FREQ" --rate "$RATE" \
      --gain "$GAIN" --ampl "$AMPL" --chirp-bw "$CHIRP_BW" --pw "$PW" --pri "$PRI" \
      --lo-offset "$LO_OFFSET" --cw-offset "$CW_OFFSET" ;;
  tone)
    [[ -x "${BUILD}/tx_waveforms" ]] || die "tx_waveforms not built. Run setup_tx.sh."
    WAVE_FREQ="$(awk -v r="$RATE" 'BEGIN { printf "%.0f", r/4 }')"
    echo "Tone will appear at $FREQ + $WAVE_FREQ Hz"
    "${RUN[@]}" "${BUILD}/tx_waveforms" --args="$ARGS" --freq "$FREQ" --rate "$RATE" \
      --gain "$GAIN" --wave-type SINE --wave-freq "$WAVE_FREQ" --wave-ampl "$TONE_AMPL" ;;
  file)
    [[ -x "${BUILD}/tx_samples_from_file" ]] || die "tx_samples_from_file not built. Run setup_tx.sh."
    "${RUN[@]}" "${BUILD}/tx_samples_from_file" --args="$ARGS" --file "$IQ_FILE" --type short \
      --freq "$FREQ" --rate "$RATE" --gain "$GAIN" --repeat ;;
esac
STATUS=$?
set -e

# 3 = tx_lfm_pulse saw underflows (PRI disturbed). 137 = had to be killed.
[[ "$STATUS" -ne 3 ]] || die "Underflows occurred: PRI timing was not held. See output above."
[[ "$STATUS" -eq 0 ]] || die "Transmit exited with status $STATUS."
echo "Transmission finished."
