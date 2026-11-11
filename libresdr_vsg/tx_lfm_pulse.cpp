// tx_lfm_pulse: continuous pulsed-LFM (or CW) generator for B200-family UHD
// devices such as the LibreSDR B220 Mini.
//
// One PRI of samples (pulse + zeros) is built once in memory and streamed
// back-to-back in a single continuous burst, so the PRI is locked to the
// SDR's sample clock instead of host timing. Underflows are counted and
// reported at exit; any underflow means the PRI was stretched.

#include <uhd/usrp/multi_usrp.hpp>
#include <uhd/utils/safe_main.hpp>
#include <uhd/utils/thread.hpp>
#include <boost/program_options.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <csignal>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

namespace po = boost::program_options;

static std::atomic<bool> stop_signal_called{false};
static void sig_int_handler(int) { stop_signal_called = true; }

int UHD_SAFE_MAIN(int argc, char* argv[])
{
    std::string args, mode, dump_file, rx_file, rx_ant;
    size_t dump_pris;
    double rx_gain, rx_seconds;
    double freq, rate, gain, bw_chirp, pw, pri, ampl, duration, lo_offset, analog_bw, cw_offset;

    po::options_description desc("tx_lfm_pulse options");
    // clang-format off
    desc.add_options()
        ("help", "show help")
        ("args", po::value<std::string>(&args)->default_value("type=b200"), "UHD device args")
        ("mode", po::value<std::string>(&mode)->default_value("lfm"), "lfm (pulsed up-chirp) or cw (continuous tone at freq)")
        ("freq", po::value<double>(&freq)->default_value(5.18e9), "RF center frequency (Hz)")
        ("rate", po::value<double>(&rate)->default_value(40e6), "TX sample rate (S/s)")
        ("gain", po::value<double>(&gain)->default_value(0.0), "TX gain (dB, UHD units)")
        ("chirp-bw", po::value<double>(&bw_chirp)->default_value(1e6), "LFM swept bandwidth (Hz), -bw/2 to +bw/2")
        ("pw", po::value<double>(&pw)->default_value(50e-6), "pulse width (s)")
        ("pri", po::value<double>(&pri)->default_value(2e-3), "pulse repetition interval (s)")
        ("ampl", po::value<double>(&ampl)->default_value(0.7), "digital amplitude, fraction of full scale (0-1]")
        ("duration", po::value<double>(&duration)->default_value(0.0), "seconds to transmit (0 = until Ctrl-C)")
        ("cw-offset", po::value<double>(&cw_offset)->default_value(0.0), "cw mode: tone offset from freq (Hz, multiple of 1 kHz)")
        ("lo-offset", po::value<double>(&lo_offset)->default_value(0.0), "LO offset (Hz); moves LO leakage away from freq")
        ("analog-bw", po::value<double>(&analog_bw)->default_value(0.0), "TX analog filter bandwidth (Hz, 0 = UHD default)")
        ("dump", po::value<std::string>(&dump_file)->default_value(""), "write the waveform to this sc16 file and exit; no radio is opened")
        ("dump-pris", po::value<size_t>(&dump_pris)->default_value(10), "number of PRIs (or 1 ms CW blocks) to write with --dump")
        ("rx-file", po::value<std::string>(&rx_file)->default_value(""), "loopback: also record the radio's own RX channel 0 to this sc16 file; stops when the capture is done")
        ("rx-gain", po::value<double>(&rx_gain)->default_value(10.0), "loopback: RX gain (dB)")
        ("rx-seconds", po::value<double>(&rx_seconds)->default_value(0.05), "loopback: capture length (s)")
        ("rx-ant", po::value<std::string>(&rx_ant)->default_value(""), "loopback: RX antenna (blank = UHD default, RX2)")
    ;
    // clang-format on
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if (vm.count("help")) {
        std::cout << desc << std::endl;
        return EXIT_SUCCESS;
    }

    if (mode != "lfm" && mode != "cw") throw std::runtime_error("--mode must be lfm or cw");
    if (!(ampl > 0.0 && ampl <= 1.0)) throw std::runtime_error("--ampl must be in (0, 1]");

    const size_t pri_samps = size_t(std::llround(pri * rate));
    const size_t pw_samps  = size_t(std::llround(pw * rate));
    if (mode == "lfm") {
        if (std::fabs(pri * rate - double(pri_samps)) > 1e-6)
            throw std::runtime_error("pri * rate must be a whole number of samples");
        if (std::fabs(pw * rate - double(pw_samps)) > 1e-6)
            throw std::runtime_error("pw * rate must be a whole number of samples");
        if (pw_samps == 0 || pw_samps > pri_samps)
            throw std::runtime_error("need 0 < pw <= pri");
        if (bw_chirp / 2 >= rate / 2) throw std::runtime_error("chirp-bw must be below the sample rate");
    }

    // ---- Build one PRI (or a CW block) -----------------------------------
    // fc32 in [-1, 1]; UHD converts to the sc16 wire format.
    std::vector<std::complex<float>> buf;
    if (mode == "lfm") {
        buf.assign(pri_samps, {0.0f, 0.0f});
        const double k = bw_chirp / pw; // chirp rate, Hz/s
        for (size_t n = 0; n < pw_samps; n++) {
            const double t   = double(n) / rate;
            const double phi = 2.0 * M_PI * (-bw_chirp / 2.0 * t + 0.5 * k * t * t);
            buf[n] = std::complex<float>(float(ampl * std::cos(phi)), float(ampl * std::sin(phi)));
        }
    } else {
        // Constant-envelope tone, same amplitude as the LFM pulse top, so CW
        // power and pulse-top power match at equal --ampl. The 1 ms buffer
        // holds a whole number of cycles when cw-offset is a multiple of 1 kHz,
        // so it loops without a phase jump.
        const size_t n_cw = size_t(std::llround(1e-3 * rate));
        if (std::fabs(std::remainder(cw_offset, 1e3)) > 1e-6)
            throw std::runtime_error("--cw-offset must be a multiple of 1 kHz");
        buf.resize(n_cw);
        for (size_t n = 0; n < n_cw; n++) {
            const double phi = 2.0 * M_PI * cw_offset * double(n) / rate;
            buf[n] = std::complex<float>(float(ampl * std::cos(phi)), float(ampl * std::sin(phi)));
        }
    }

    // ---- Offline dump: validate the waveform with no radio involved -------
    if (!dump_file.empty()) {
        std::ofstream out(dump_file, std::ios::binary);
        if (!out) throw std::runtime_error("cannot open " + dump_file);
        std::vector<std::complex<int16_t>> s16(buf.size());
        for (size_t n = 0; n < buf.size(); n++)
            s16[n] = {int16_t(std::lround(buf[n].real() * 32767.0)),
                      int16_t(std::lround(buf[n].imag() * 32767.0))};
        for (size_t i = 0; i < dump_pris; i++)
            out.write(reinterpret_cast<const char*>(s16.data()), std::streamsize(s16.size() * sizeof(s16[0])));
        std::cout << "Wrote " << dump_pris << " x " << buf.size() << " samples (sc16) to " << dump_file
                  << "; nothing was transmitted." << std::endl;
        return EXIT_SUCCESS;
    }

    // ---- Configure the radio ---------------------------------------------
    uhd::usrp::multi_usrp::sptr usrp = uhd::usrp::multi_usrp::make(args);
    usrp->set_tx_rate(rate, 0);
    const double actual_rate = usrp->get_tx_rate(0);
    if (std::fabs(actual_rate - rate) > 1.0)
        throw std::runtime_error("device could not set rate exactly; got " + std::to_string(actual_rate));

    uhd::tune_request_t tr(freq, lo_offset);
    usrp->set_tx_freq(tr, 0);
    const uhd::gain_range_t gr = usrp->get_tx_gain_range(0);
    if (gain < gr.start() || gain > gr.stop())
        throw std::runtime_error("gain outside device range " + gr.to_pp_string());
    usrp->set_tx_gain(gain, 0);
    if (analog_bw > 0) usrp->set_tx_bandwidth(analog_bw, 0);

    std::this_thread::sleep_for(std::chrono::milliseconds(300)); // LO settle
    std::vector<std::string> sensors = usrp->get_tx_sensor_names(0);
    if (std::find(sensors.begin(), sensors.end(), "lo_locked") != sensors.end()
        && !usrp->get_tx_sensor("lo_locked", 0).to_bool())
        throw std::runtime_error("TX LO did not lock");

    std::cout << "Device TX gain range: " << gr.to_pp_string() << std::endl;
    std::cout << "TX freq " << usrp->get_tx_freq(0) / 1e6 << " MHz, rate " << actual_rate / 1e6
              << " MS/s, gain " << usrp->get_tx_gain(0) << " dB, ampl " << ampl << std::endl;
    if (mode == "lfm") {
        std::cout << "LFM " << bw_chirp / 1e6 << " MHz over " << pw * 1e6 << " us, PRI "
                  << pri * 1e3 << " ms (" << pri_samps << " samples), duty "
                  << 100.0 * pw / pri << " %" << std::endl;
    } else {
        std::cout << "CW tone at freq + " << cw_offset / 1e3 << " kHz" << std::endl;
    }

    // Stream sc16 straight from memory: no float-to-int conversion per sample,
    // which leaves more CPU headroom at 40 MS/s.
    std::vector<std::complex<int16_t>> tx_buf(buf.size());
    for (size_t n = 0; n < buf.size(); n++)
        tx_buf[n] = {int16_t(std::lround(buf[n].real() * 32767.0)),
                     int16_t(std::lround(buf[n].imag() * 32767.0))};
    uhd::stream_args_t sargs("sc16", "sc16");
    sargs.channels = {0};
    uhd::tx_streamer::sptr tx = usrp->get_tx_stream(sargs);

    // ---- Optional loopback RX on the same radio ---------------------------
    uhd::rx_streamer::sptr rx;
    if (!rx_file.empty()) {
        usrp->set_rx_rate(rate, 0);
        if (std::fabs(usrp->get_rx_rate(0) - rate) > 1.0)
            throw std::runtime_error("RX could not use the TX rate");
        usrp->set_rx_freq(uhd::tune_request_t(freq), 0);
        usrp->set_rx_gain(rx_gain, 0);
        if (!rx_ant.empty()) usrp->set_rx_antenna(rx_ant, 0);
        uhd::stream_args_t rargs("sc16", "sc16");
        rargs.channels = {0};
        rx = usrp->get_rx_stream(rargs);
        std::cout << "Loopback RX: antenna " << usrp->get_rx_antenna(0) << ", gain "
                  << usrp->get_rx_gain(0) << " dB, " << rx_seconds * 1e3 << " ms to " << rx_file
                  << std::endl;
    }
    std::atomic<bool> rx_done{false};
    std::atomic<size_t> overflows{0};
    std::atomic<int> rx_error{0};
    std::thread rx_thread;
    if (rx) {
        rx_thread = std::thread([&]() {
            // Let the TX stream settle before recording.
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            const size_t n = size_t(std::llround(rx_seconds * rate));
            std::vector<std::complex<int16_t>> cap(n);
            uhd::stream_cmd_t cmd(uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_DONE);
            cmd.num_samps  = n;
            cmd.stream_now = true;
            rx->issue_stream_cmd(cmd);
            uhd::rx_metadata_t rmd;
            size_t got = 0;
            while (got < n && !stop_signal_called) {
                got += rx->recv(&cap[got], n - got, rmd, 1.0);
                if (rmd.error_code == uhd::rx_metadata_t::ERROR_CODE_OVERFLOW) {
                    overflows++;
                } else if (rmd.error_code != uhd::rx_metadata_t::ERROR_CODE_NONE) {
                    std::cerr << "RX error: " << rmd.strerror() << std::endl;
                    rx_error = 1;
                    break;
                }
            }
            std::ofstream out(rx_file, std::ios::binary);
            out.write(reinterpret_cast<const char*>(cap.data()), std::streamsize(got * sizeof(cap[0])));
            if (got < n) rx_error = 1;
            rx_done = true;
        });
    }

    // Count underflows from the async message channel.
    std::atomic<size_t> underflows{0};
    std::thread async_thread([&]() {
        uhd::async_metadata_t amd;
        while (!stop_signal_called) {
            if (!tx->recv_async_msg(amd, 0.1)) continue;
            if (amd.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW
                || amd.event_code == uhd::async_metadata_t::EVENT_CODE_UNDERFLOW_IN_PACKET) {
                if (underflows++ == 0)
                    std::cerr << "\nWARNING: underflow - the computer could not keep up, so the signal now has"
                                 " gaps.\n         Use a USB 3 connection or a lower --rate." << std::endl;
            }
        }
    });

    std::signal(SIGINT, &sig_int_handler);
    std::signal(SIGTERM, &sig_int_handler);
    std::cout << "Transmitting. Press Ctrl-C to stop." << std::endl;

    // Ask the OS to schedule the sending thread ahead of desktop work
    // (best effort: UHD only warns if it is not allowed).
    uhd::set_thread_priority_safe(1.0, true);

    uhd::tx_metadata_t md;
    md.start_of_burst = true;
    md.end_of_burst   = false;
    md.has_time_spec  = false;

    const auto t_end = std::chrono::steady_clock::now()
                       + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                           std::chrono::duration<double>(duration));
    while (!stop_signal_called) {
        if (duration > 0 && std::chrono::steady_clock::now() >= t_end) break;
        if (rx && rx_done) break;
        size_t sent = 0;
        while (sent < tx_buf.size() && !stop_signal_called) {
            sent += tx->send(&tx_buf[sent], tx_buf.size() - sent, md, 0.5);
            md.start_of_burst = false;
        }
    }

    // Close the burst cleanly so the DAC returns to idle.
    md.end_of_burst = true;
    tx->send("", 0, md);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    stop_signal_called = true;
    async_thread.join();
    if (rx_thread.joinable()) rx_thread.join();

    std::cout << "Stopped. Underflows: " << underflows.load()
              << (underflows.load() ? "  <-- PRI was disturbed; lower rate or reduce host load" : "")
              << std::endl;
    if (rx)
        std::cout << "Loopback capture: " << (rx_error ? "INCOMPLETE" : "complete")
                  << ", overflows: " << overflows.load() << std::endl;
    if (underflows.load()) return 3;
    if (rx && (overflows.load() || rx_error)) return 4;
    return EXIT_SUCCESS;
}
