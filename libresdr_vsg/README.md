# libresdr_vsg

One-command pulsed-LFM transmitter for a LibreSDR B220 Mini (UHD B210 clone) on macOS or Linux,
used as a VSG into an EPIQ Sidekiq X40. Cabled use only, never into an antenna.

Waveform: 5.18 GHz, 40 MS/s, 1 MHz linear chirp, 50 µs pulse (or any width), 2 ms PRI, TX channel A only.

## Setup (once per computer)

Nothing is flashed to the radio. Like the Ettus B210 it copies, the LibreSDR keeps no firmware or FPGA image of
its own: every time it powers up, UHD on the computer loads both over USB. So each computer that drives it needs
these two files once. After that it is plug and play: plug in, run `lfm_tx`.

1. **Tools:** `brew install uhd cmake`, and Python 3 with numpy and matplotlib.

2. **USB-chip firmware** (`usrp_b200_fw.hex`). Homebrew's UHD doesn't include it. Get it from Ettus and put it
   where `lfm_tx` looks (`~/.local/share/uhd/images`):
   ```bash
   mkdir -p ~/.local/share/uhd/images && cd "$(mktemp -d)"
   curl -fsSLO https://files.ettus.com/binaries/cache/b2xx/uhd-7f7d016/b2xx_common_fw_default-g7f7d016.zip
   echo "22ac0e54cc90d53d8494d481439447a0c89b9bbaced6fabe24df260eda3ce3a3  b2xx_common_fw_default-g7f7d016.zip" | shasum -a 256 -c
   unzip -q b2xx_common_fw_default-g7f7d016.zip && find . -name usrp_b200_fw.hex -exec cp {} ~/.local/share/uhd/images/ \;
   ```

3. **LibreSDR FPGA image** (bkerler's `LibreSDR_UHD_B220_Mini_FPGA`, the same one ATHENA-Skydar uses). The stock
   Ettus FPGA image does not work on this board.
   ```bash
   mkdir -p ~/.local/share/libresdr
   curl -fsSL -o ~/.local/share/libresdr/usrp_b210_fpga_b220mini.bin \
     https://raw.githubusercontent.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA/main/usrp_b210_fpga.bin
   shasum -a 256 ~/.local/share/libresdr/usrp_b210_fpga_b220mini.bin
   # tested with c503101c6c130fe43f253b969d2a09f28b7cd7392389e73a3598a5305df89005
   ```

4. **Tell UHD to use that image.** Create `~/.config/uhd.conf` (use the full path; `~` is not expanded here):
   ```
   [type=b200]
   fpga=/Users/<you>/.local/share/libresdr/usrp_b210_fpga_b220mini.bin
   ```
   This applies to every B200-family radio on the computer. If a real Ettus B200/B210 is also used there,
   use `[serial=<LibreSDR serial>]` instead of `[type=b200]`.

5. **Build and install:** `./setup_tx.sh` builds `tx_lfm_pulse` into `~/.local/lib/b220-tx` and installs
   `lfm_tx`, `vsg_tx` and `loopback_check` into `~/.local/bin`.

6. **Check:** plug the LibreSDR into a USB 3 port and run
   ```bash
   UHD_IMAGES_DIR=~/.local/share/uhd/images uhd_find_devices --args type=b200
   ```
   It should list one B200-family device. A freshly plugged board first shows as "WestBridge" at 480 Mb/s
   until the firmware loads; that's normal.

## Transmit

```
lfm_tx <tx_gain_db> [pulse_width_us]
lfm_tx 60          # 50 µs pulse
lfm_tx 60 200      # 200 µs pulse
```

It saves and opens a plot of the exact samples it sends (`~/libresdr_tx/`), then transmits until Ctrl-C.

- **USB 3 is required** for 40 MS/s. Plug straight into the computer, not a hub. A freshly plugged board shows up as
  "WestBridge" at 480 Mb/s until firmware loads; `lfm_tx` loads it first, then checks the link speed.
- Underflows are avoided with `sc16` samples, a real-time send thread and a deep USB send queue
  (`num_send_frames=256`, override with `LFM_SEND_FRAMES`). The run ends with `Underflows: N`.
- Wiring used: LibreSDR TXA → 30 dB attenuator → DC block → X40 RX port.

## Files

| File | What it does |
|---|---|
| `lfm_tx.sh` | The one command: USB check, plot, transmit |
| `tx_lfm_pulse.cpp` | UHD transmitter (LFM / CW / tone), also dumps the waveform with `--dump` |
| `setup_tx.sh` | Build and install |
| `vsg_tx.sh` | Calibrated VSG modes with an attenuation interlock |
| `cal.py`, `measure_iq.py` | Power calibration table, pulse measurements |
| `plot_lfm.py`, `plot_iq.py` | Plots of the sent waveform and of captures |
| `loopback_check.sh` | TX→RX loopback check on the LibreSDR itself |
| `plots/` | Example plots: sent waveform and loopback at gain 70 |
