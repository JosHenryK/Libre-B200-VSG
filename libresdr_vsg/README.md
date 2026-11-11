# libresdr_vsg

One-command pulsed-LFM transmitter for a LibreSDR B220 Mini (UHD B210 clone) on macOS or Linux,
used as a VSG into an EPIQ Sidekiq X40. Cabled use only, never into an antenna.

Waveform: 5.18 GHz, 40 MS/s, 1 MHz linear chirp, 50 µs pulse (or any width), 2 ms PRI, TX channel A only.

## Setup (once)

1. `brew install uhd cmake` and Python 3 with numpy and matplotlib.
2. Point UHD at the LibreSDR FPGA image (bkerler's `LibreSDR_UHD_B220_Mini_FPGA`) in `~/.config/uhd.conf`:
   ```
   [type=b200]
   fpga=/path/to/usrp_b210_fpga_b220mini.bin
   ```
3. `./setup_tx.sh` builds `tx_lfm_pulse` into `~/.local/lib/b220-tx` and installs `lfm_tx`, `vsg_tx` and `loopback_check` into `~/.local/bin`.

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
