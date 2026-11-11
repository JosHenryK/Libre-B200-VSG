#include <uhd/types/tune_request.hpp>
#include <uhd/usrp/multi_usrp.hpp>
#include <uhd/utils/thread.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr double kTwoPi = 6.28318530717958647692;

struct options {
    std::string args;
    double frequency_hz = 5.18e9;
    double sample_rate_sps = 40e6;
    double gain_db = 0.0;
    double pulse_width_s = 50e-6;
    double pri_s = 2e-3;
    double duration_s = 1.0;
};

[[noreturn]] void usage(const char* name, const std::string& error = {}) {
    if (!error.empty()) std::cerr << "ERROR: " << error << '\n';
    std::cerr << "Usage: " << name
              << " --args DEVICE_ARGS [--freq HZ] [--rate SPS] [--gain DB]"
                 " [--pulse-width SEC] [--pri SEC] --duration SEC\n";
    std::exit(error.empty() ? 0 : 2);
}

double number(const char* value, const char* flag) {
    try {
        size_t consumed = 0;
        const double parsed = std::stod(value, &consumed);
        if (value[consumed] != '\0' || !std::isfinite(parsed)) throw std::invalid_argument("invalid");
        return parsed;
    } catch (const std::exception&) {
        usage("tx_lfm_pulses", std::string("invalid value for ") + flag + ": " + value);
    }
}

options parse_options(int argc, char* argv[]) {
    options result;
    bool duration_set = false;
    for (int i = 1; i < argc; ++i) {
        const std::string flag = argv[i];
        if (flag == "--help" || flag == "-h") usage(argv[0]);
        if (++i == argc) usage(argv[0], "missing value for " + flag);
        const char* value = argv[i];
        if (flag == "--args") result.args = value;
        else if (flag == "--freq") result.frequency_hz = number(value, "--freq");
        else if (flag == "--rate") result.sample_rate_sps = number(value, "--rate");
        else if (flag == "--gain") result.gain_db = number(value, "--gain");
        else if (flag == "--pulse-width") result.pulse_width_s = number(value, "--pulse-width");
        else if (flag == "--pri") result.pri_s = number(value, "--pri");
        else if (flag == "--duration") { result.duration_s = number(value, "--duration"); duration_set = true; }
        else usage(argv[0], "unknown option " + flag);
    }
    if (result.args.empty()) usage(argv[0], "--args is required");
    if (!duration_set) usage(argv[0], "--duration is required");
    if (result.frequency_hz <= 0 || result.sample_rate_sps <= 0 || result.pulse_width_s <= 0 ||
        result.pri_s <= 0 || result.duration_s <= 0 || result.pulse_width_s > result.pri_s) {
        usage(argv[0], "frequency, rate, duration, PRI, and pulse width must be positive; pulse width must not exceed PRI");
    }
    return result;
}

size_t exact_samples(double seconds, double rate, const char* label) {
    const double samples = seconds * rate;
    const auto rounded = static_cast<size_t>(std::llround(samples));
    if (rounded == 0 || std::abs(samples - static_cast<double>(rounded)) > 1e-6) {
        throw std::runtime_error(std::string(label) + " must correspond to an integer number of samples at the chosen rate");
    }
    return rounded;
}
} // namespace

int main(int argc, char* argv[]) {
    try {
        const options opt = parse_options(argc, argv);
        const size_t pulse_samples = exact_samples(opt.pulse_width_s, opt.sample_rate_sps, "pulse width");
        const size_t pri_samples = exact_samples(opt.pri_s, opt.sample_rate_sps, "PRI");

        uhd::set_thread_priority_safe();
        auto usrp = uhd::usrp::multi_usrp::make(opt.args);
        usrp->set_tx_rate(opt.sample_rate_sps);
        const double actual_rate = usrp->get_tx_rate();
        if (std::abs(actual_rate - opt.sample_rate_sps) > 1.0) {
            throw std::runtime_error("device did not accept the requested transmit sample rate");
        }
        usrp->set_tx_freq(uhd::tune_request_t(opt.frequency_hz));
        usrp->set_tx_gain(opt.gain_db);

        std::vector<std::complex<float>> frame(pri_samples, {0.0F, 0.0F});
        const double chirp_rate_hz_per_s = 1e6 / opt.pulse_width_s;
        for (size_t n = 0; n < pulse_samples; ++n) {
            const double t = static_cast<double>(n) / actual_rate;
            // A 1 MHz complex baseband LFM sweep centered at DC: -0.5 to +0.5 MHz.
            const double phase = kTwoPi * (-0.5e6 * t + 0.5 * chirp_rate_hz_per_s * t * t);
            frame[n] = static_cast<float>(0.5) * std::complex<float>(std::cos(phase), std::sin(phase));
        }

        uhd::stream_args_t stream_args("fc32");
        auto tx_stream = usrp->get_tx_stream(stream_args);
        const size_t repetitions = static_cast<size_t>(std::ceil(opt.duration_s / opt.pri_s));
        std::cout << "TX frequency: " << usrp->get_tx_freq() << " Hz\n"
                  << "TX sample rate: " << actual_rate << " samples/s\n"
                  << "TX gain: " << usrp->get_tx_gain() << " dB\n"
                  << "LFM bandwidth: 1000000 Hz\n"
                  << "Pulse width: " << opt.pulse_width_s << " s (" << pulse_samples << " samples)\n"
                  << "PRI: " << opt.pri_s << " s (" << pri_samples << " samples)\n"
                  << "Pulses: " << repetitions << " (" << repetitions * opt.pri_s << " s on-air)\n";

        uhd::tx_metadata_t metadata;
        for (size_t repetition = 0; repetition < repetitions; ++repetition) {
            size_t offset = 0;
            while (offset < frame.size()) {
                const size_t count = std::min(tx_stream->get_max_num_samps(), frame.size() - offset);
                metadata.start_of_burst = repetition == 0 && offset == 0;
                metadata.end_of_burst = repetition + 1 == repetitions && offset + count == frame.size();
                const size_t sent = tx_stream->send(&frame[offset], count, metadata);
                if (sent != count) throw std::runtime_error("short transmit write");
                offset += sent;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        std::cout << "Transmit complete.\n";
    } catch (const std::exception& error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return 1;
    }
}
