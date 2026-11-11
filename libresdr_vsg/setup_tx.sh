#!/usr/bin/env bash
set -Eeuo pipefail

# Builds tx_lfm_pulse and the UHD TX examples (tx_waveforms,
# tx_samples_from_file) against Homebrew UHD, and installs vsg_tx.
#   Raspberry Pi: run ATHENA-Skydar's setup.sh first (installs UHD + FPGA).
#   macOS:        brew install uhd cmake, plus ~/.config/uhd.conf pointing at
#                 the LibreSDR FPGA image (see the Skydar README).
# Run as the normal login user (NOT with sudo).

if [[ "$(uname -s)" == "Darwin" ]]; then
  BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
else
  BREW="/home/linuxbrew/.linuxbrew/bin/brew"
fi
UHD_VERSION="${UHD_VERSION:-4.11.0.0}"   # must match the Homebrew uhd formula
INSTALL_DIR="${HOME}/.local/lib/b220-tx"
BUILD="${INSTALL_DIR}/build"
BIN_DIR="${HOME}/.local/bin"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RAW="https://raw.githubusercontent.com/EttusResearch/uhd/v${UHD_VERSION}/host/examples"

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, not with sudo."
# numpy for cal.py / measure_iq.py. Checked before loading Homebrew's
# environment, because that puts Homebrew's own python3 (often without numpy)
# first on PATH, while vsg_tx runs with your normal PATH.
if ! python3 -c 'import numpy' 2>/dev/null; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    die "python3 ($(command -v python3)) has no numpy. Install it and rerun."
  fi
  sudo apt-get install -y python3-numpy
fi
[[ -x "$BREW" ]] || die "Homebrew not found. Run ATHENA-Skydar setup.sh first (Pi) or install Homebrew (Mac)."
eval "$("$BREW" shellenv)"
brew list uhd >/dev/null 2>&1 || die "Homebrew uhd is not installed (brew install uhd cmake)."

for f in lfm_tx.sh vsg_tx.sh loopback_check.sh tx_lfm_pulse.cpp cal.py measure_iq.py plot_iq.py plot_lfm.py; do
  [[ -f "${REPO_DIR}/${f}" ]] || die "${f} not found next to this script."
done

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "${HOME}/.config/libresdr_cal"
# tx_waveforms.cpp includes wavetable.hpp from the same examples directory.
for f in tx_waveforms.cpp tx_samples_from_file.cpp wavetable.hpp; do
  curl -fsSL "${RAW}/${f}" -o "${INSTALL_DIR}/${f}" || die "Could not download ${f} for UHD v${UHD_VERSION}"
done
cp "${REPO_DIR}/tx_lfm_pulse.cpp" "${INSTALL_DIR}/"
install -m 0755 "${REPO_DIR}/cal.py" "${REPO_DIR}/measure_iq.py" "${REPO_DIR}/plot_iq.py" "${REPO_DIR}/plot_lfm.py" "${INSTALL_DIR}/"

cat > "${INSTALL_DIR}/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(b220_tx_examples LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(UHD REQUIRED)
find_package(Boost REQUIRED COMPONENTS program_options filesystem)
find_package(Threads REQUIRED)
foreach(ex tx_waveforms tx_samples_from_file tx_lfm_pulse)
  add_executable(${ex} ${ex}.cpp)
  target_include_directories(${ex} PRIVATE ${UHD_INCLUDE_DIRS} ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(${ex} PRIVATE ${UHD_LIBRARIES} Boost::program_options Boost::filesystem Threads::Threads)
endforeach()
CMAKE

CMAKE_EXTRA=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  # When Command Line Tools and Xcode are out of step, the default SDK can be
  # newer than the linker understands ("tapi error: malformed file"). Use the
  # newest installed SDK that actually links a test program.
  probe_dir="$(mktemp -d)"
  printf 'int main(){return 0;}\n' > "${probe_dir}/t.cpp"
  SDK=""
  # shellcheck disable=SC2012  # SDK paths have no spaces
  for cand in "$(xcrun --show-sdk-path 2>/dev/null)" \
              $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    [[ -d "$cand" ]] || continue
    if /usr/bin/c++ -isysroot "$cand" "${probe_dir}/t.cpp" -o "${probe_dir}/t" >/dev/null 2>&1; then
      SDK="$cand"; break
    fi
  done
  rm -rf "$probe_dir"
  [[ -n "$SDK" ]] || die "No macOS SDK links a test program. Update Xcode / Command Line Tools."
  echo "Using macOS SDK: $SDK"
  CMAKE_EXTRA+=("-DCMAKE_OSX_SYSROOT=$SDK")
fi

rm -rf "$BUILD"
cmake -S "$INSTALL_DIR" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix);$(brew --prefix uhd);$(brew --prefix boost)" \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"}
cmake --build "$BUILD" --parallel 2
for ex in tx_waveforms tx_samples_from_file tx_lfm_pulse; do
  [[ -x "${BUILD}/${ex}" ]] || die "Failed to build ${ex}"
done

install -m 0755 "${REPO_DIR}/vsg_tx.sh" "${BIN_DIR}/vsg_tx"
install -m 0755 "${REPO_DIR}/loopback_check.sh" "${BIN_DIR}/loopback_check"
install -m 0755 "${REPO_DIR}/lfm_tx.sh" "${BIN_DIR}/lfm_tx"

echo
echo "Built: tx_waveforms, tx_samples_from_file, tx_lfm_pulse in ${BUILD}"
echo "Calibration tools: ${INSTALL_DIR}/cal.py, ${INSTALL_DIR}/measure_iq.py, ${INSTALL_DIR}/plot_iq.py"
echo "Put the calibration table at ${HOME}/.config/libresdr_cal/cal_5180MHz.csv"
echo "Installed: ${BIN_DIR}/lfm_tx, ${BIN_DIR}/vsg_tx, ${BIN_DIR}/loopback_check  (run with no arguments for usage)"
