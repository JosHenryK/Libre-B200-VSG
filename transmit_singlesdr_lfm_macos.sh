#!/usr/bin/env bash
set -Eeuo pipefail

# Transmit a 1 MHz baseband LFM pulse train using one USB-connected LibreSDR.
# Usage: transmit_singlesdr_lfm_macos.sh <duration_s> <gain_db>
# Default waveform: 5.18 GHz RF, 40 MS/s, 50 us pulse, 2 ms PRI.

usage() {
  printf 'Usage: %s <duration_s> <gain_db>\n' "${0##*/}" >&2
  exit 2
}

[[ "$#" -eq 2 ]] || usage
DURATION="$1"
GAIN="$2"
FREQ="${B220_TX_FREQ_HZ:-5180000000}"
RATE="${B220_TX_RATE_SPS:-40000000}"
PULSE_WIDTH="${B220_TX_PULSE_WIDTH_S:-0.000050}"
PRI="${B220_TX_PRI_S:-0.002}"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${B220_TX_BUILD_DIR:-${REPO_DIR}/build-macos}"
TX_BIN="${BUILD_DIR}/tx_lfm_pulses"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for value in "$DURATION" "$GAIN" "$FREQ" "$RATE" "$PULSE_WIDTH" "$PRI"; do
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid numeric value: $value"
done

# Homebrew's UHD formula ships the host library but not the separately
# downloadable firmware/images package. Reuse an existing Radioconda image
# directory when present; the configured per-device B220 FPGA in
# ~/.config/uhd.conf remains in effect and takes precedence for that device.
if [[ -z "${UHD_IMAGES_DIR:-}" ]]; then
  for image_dir in "${HOME}/.local/share/uhd/images" "${HOME}/radioconda/share/uhd/images"; do
    if [[ -f "${image_dir}/usrp_b200_fw.hex" ]]; then
      export UHD_IMAGES_DIR="$image_dir"
      break
    fi
  done
fi
[[ -n "${UHD_IMAGES_DIR:-}" && -f "${UHD_IMAGES_DIR}/usrp_b200_fw.hex" ]] || \
  die "UHD B200 firmware image is missing. Set UHD_IMAGES_DIR to a directory containing usrp_b200_fw.hex."

find_tool() {
  local tool="$1"
  # Match the Homebrew UHD library selected by CMake, rather than a possibly
  # older Conda/Radioconda UHD earlier on PATH.
  if [[ -x "/opt/homebrew/bin/$tool" ]]; then printf '%s\n' "/opt/homebrew/bin/$tool"
  elif [[ -x "/usr/local/bin/$tool" ]]; then printf '%s\n' "/usr/local/bin/$tool"
  elif command -v "$tool" >/dev/null 2>&1; then command -v "$tool"
  else return 1
  fi
}

UHD_FIND="$(find_tool uhd_find_devices)" || die "uhd_find_devices not found. Install UHD first: brew install uhd cmake"
if [[ ! -x "$TX_BIN" || "$REPO_DIR/tx_lfm_pulses.cpp" -nt "$TX_BIN" || "$REPO_DIR/CMakeLists.txt" -nt "$TX_BIN" ]]; then
  command -v cmake >/dev/null 2>&1 || die "cmake not found. Install it first: brew install cmake"
  echo "Building the transmit helper..."
  cmake -S "$REPO_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$BUILD_DIR" --target tx_lfm_pulses --parallel 2
fi

echo "=== Attached UHD SDR diagnostic ==="
echo "UHD images directory: $UHD_IMAGES_DIR"
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed. Check USB connection and UHD installation."
printf '%s\n\n' "$DEVICE_LIST"
read -r -p "Name for the transmitting SDR (as listed above): " SDR_NAME
[[ -n "$SDR_NAME" ]] || die "SDR name cannot be empty."
grep -Fq "name: $SDR_NAME" <<< "$DEVICE_LIST" || die "SDR name '$SDR_NAME' was not listed by uhd_find_devices."

echo "WARNING: This emits RF. Confirm the antenna/load, frequency authorization, and a safe gain before continuing."
echo "Frequency: $FREQ Hz; rate: $RATE samples/s; pulse: $PULSE_WIDTH s; PRI: $PRI s; gain: $GAIN dB; duration: $DURATION s"
read -r -p "Type TRANSMIT to start: " CONFIRM
[[ "$CONFIRM" == "TRANSMIT" ]] || die "Transmit cancelled."

exec "$TX_BIN" --args "type=b200,name=$SDR_NAME" --freq "$FREQ" --rate "$RATE" --gain "$GAIN" \
  --pulse-width "$PULSE_WIDTH" --pri "$PRI" --duration "$DURATION"
