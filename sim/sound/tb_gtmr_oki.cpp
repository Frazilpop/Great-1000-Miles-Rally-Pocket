// SPDX-License-Identifier: GPL-3.0-only
// One OKI of the gtmr board, replaying the game's writes from MAME.
//
//   tb_gtmr_oki set.rom oki_log chip frames out.chan out.ev [--lat MIN MAX] [--seed N]
//
// oki_log is tools/mame_gtmr_oki.lua's. Each write is made at its clock, the
// way the game makes it (the routine at 0xd232): STOP for a channel, spin on
// the status until its bit drops, the phrase byte, spin, channel | volume.
// In MAME the bit is down as the STOP lands; here a write waits for the bit
// and then 150 clocks, what the 68000 takes to get from the read to the write.
//
// The SDRAM answers each burst after a latency drawn from MIN..MAX clocks
// (default 20 20), with the set's own bytes.
//
// out.chan: each voice's ADPCM signal at each sample, four signed 16-bit words
// (jt6295_adpcm's snd0-3; snd0 holds voice 1, the matcher rotates them back).
// out.ev: one line per thing the serial unit did, for match_oki_channels.py:
//   start <sample> <ch> <phrase> <start> <end as taken>
//   end   <sample> <ch> <samples played>     the end address reached
//   cut   <sample> <ch> <samples played>     a STOP, or a START on a playing voice
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vkaneko_gtmr_oki.h"
#include "verilated.h"

struct W { unsigned long long t; unsigned addr, data; };

static const unsigned long long FRAME = 811008, SAMPLE = 3960;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 7) {
        fprintf(stderr, "usage: %s set.rom oki_log chip frames out.chan out.ev [--lat MIN MAX] [--seed N]\n", argv[0]);
        return 2;
    }
    const int  chip   = atoi(argv[3]);
    const long frames = atol(argv[4]);
    int lat_min = 20, lat_max = 20;
    unsigned seed = 1;
    for (int i = 7; i < argc; i++) {
        if (!strcmp(argv[i], "--lat") && i + 2 < argc) { lat_min = atoi(argv[++i]); lat_max = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = atoi(argv[++i]);
    }
    srand(seed);

    std::vector<unsigned char> rom;
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 1;
    fclose(f);

    const unsigned a_oki = chip ? 0x880001 : 0x800001, a_bank = chip ? 0xe80001 : 0xe00001;
    std::vector<W> log;
    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    { long fr; W w;
      while (fscanf(f, "%ld %x %x %llu", &fr, &w.addr, &w.data, &w.t) == 4)
          if (w.addr == a_oki || w.addr == a_bank) log.push_back(w); }
    fclose(f);

    FILE* chan = fopen(argv[5], "wb");
    FILE* ev   = fopen(argv[6], "w");
    if (!chan || !ev) { perror("output"); return 1; }

    Vkaneko_gtmr_oki* t = new Vkaneko_gtmr_oki;
    t->rst = 1; t->cen = 0; t->chip = chip; t->we = 0; t->din = 0; t->okb = 0;
    t->sdr_ack = 0; t->sdr_dout = 0;

    int div = 0;
    bool sdr_busy = false; int sdr_cnt = 0;
    auto clock = [&]() {
        t->cen = (div == 0);
        div = (div + 1) % 24;
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
    };
    for (int i = 0; i < 48; i++) clock();
    t->rst = 0;

    const unsigned long long end = FRAME * frames;
    size_t k = 0;
    unsigned wait_mask = 0;
    bool cmd = false, spinning = false, sr_prev = false;
    unsigned long long not_before = 0, spin_from = 0, worst_spin = 0, spins = 0;
    long playing[4] = {0, 0, 0, 0};
    bool active[4] = {false, false, false, false};
    long starts = 0, n_end = 0, n_cut = 0, nwrites = 0;

    for (unsigned long long c = 0; c < end; c++) {
        // --- the game's next write
        t->we = 0;
        while (k < log.size() && c >= log[k].t && c >= not_before) {
            const W& w = log[k];
            if (w.addr == a_bank) { t->okb = w.data & 15; k++; nwrites++; continue; }
            const bool command = cmd || (w.data & 0x80);
            if (command && (t->dout & wait_mask)) {
                if (!spinning) { spinning = true; spin_from = c; }
                break;
            }
            if (spinning) {
                spinning = false; spins++;
                if (c - spin_from > worst_spin) worst_spin = c - spin_from;
                not_before = c + 150;
                break;
            }
            t->din = w.data; t->we = 1;
            if (cmd) { cmd = false; wait_mask = 0; }
            else if (w.data & 0x80) cmd = true;
            else wait_mask = (w.data >> 3) & 15;
            k++; nwrites++;
            not_before = c + 4;
            break;
        }

        // --- the serial unit, on the clock it commits a channel's turn
        if (t->slot) {
            int ch = t->slot_ch == 1 ? 0 : t->slot_ch == 2 ? 1 : t->slot_ch == 4 ? 2 : 3;
            const unsigned long long smp = c / SAMPLE;
            bool up = t->up_start || t->up_stop;
            if (t->busy_out) playing[ch]++;
            if (active[ch] && up) {
                fprintf(ev, "cut %llu %d %ld\n", smp, ch, playing[ch]);
                active[ch] = false; n_cut++;
            } else if (active[ch] && t->busy_out && t->over) {
                fprintf(ev, "end %llu %d %ld\n", smp, ch, playing[ch]);
                active[ch] = false; n_end++;
            }
            if (t->up_start && !t->up_stop) {
                fprintf(ev, "start %llu %d %02x %05x %05x\n", smp, ch, (unsigned)t->phrase,
                        (unsigned)t->start_addr, (unsigned)t->stop_addr);
                active[ch] = true; playing[ch] = 0; starts++;
            }
        }

        // --- the SDRAM
        t->sdr_ack = 0;
        if (sdr_busy) {
            if (--sdr_cnt <= 0) {
                unsigned long long dout = 0;
                size_t b = (size_t)t->sdr_addr * 2;
                for (int j = 0; j < 8; j++)
                    if (b + j < rom.size()) dout |= (unsigned long long)rom[b + j] << (8 * j);
                t->sdr_dout = dout; t->sdr_ack = 1;
                sdr_busy = false;
            }
        } else if (t->sdr_req) {
            sdr_busy = true;
            sdr_cnt = lat_min + (lat_max > lat_min ? rand() % (lat_max - lat_min + 1) : 0);
        }

        const bool ack_now = t->sdr_ack;
        clock();
        // one request, one burst: hold off until the feeder has dropped it
        if (ack_now && t->sdr_req) { t->sdr_ack = 0; t->eval(); }

        if (t->cen_sr && !sr_prev) {
            int16_t v[4] = { (int16_t)(t->snd0 << 4) >> 4, (int16_t)(t->snd1 << 4) >> 4,
                             (int16_t)(t->snd2 << 4) >> 4, (int16_t)(t->snd3 << 4) >> 4 };
            fwrite(v, 2, 4, chan);
        }
        sr_prev = t->cen_sr;
        if (c % (FRAME * 1000) == 0) fprintf(stderr, "%llu of %ld frames\n", c / FRAME, frames);
    }
    fclose(chan); fclose(ev);
    printf("chip %d: %ld writes of %zu replayed, %ld starts, %ld ended, %ld cut, %llu spins, worst %llu clocks\n",
           chip, nwrites, log.size(), starts, n_end, n_cut, spins, worst_spin);
    delete t;
    return 0;
}
