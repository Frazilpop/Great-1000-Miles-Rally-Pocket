// SPDX-License-Identifier: GPL-3.0-only
// The OKIs' save-state chain, three copies on one clock (kaneko_oki_state3).
//
//   tb_oki_state3 set.rom oki_log frames [--every N] [--from F] [--lat N] [--spoil BIT] [--seed N]
//
// A and B replay OKI 0's writes from tools/mame_gtmr_oki.lua's log, as
// tb_gtmr_oki does (the game's protocol at 0xd232: STOP, spin on the status,
// phrase, spin, channel | volume). C plays random commands of its own. Every
// N frames from frame F (default 200 and 300) is a save point: C's writes stop
// 4 frames before it; at the next clock where A and C are quiet at the dead
// phase, on the board's oki_div 13, all three are stopped. Then:
//   1. A and C each go round once on their own, read: how many bits differ;
//   2. A round once more, C taking A's bits (a load), A fed back (a save);
//   3. C round once, read: it must be A's, bit for bit;
// B is only stopped, as long. All three let go on oki_div 13 again and take
// A's writes from then. Until C's next random spell their sound, sample and
// status must agree on every clock, A's with B's and C's with A's.
// --spoil BIT flips that bit on its way into C, to see it fail.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Vkaneko_oki_state3.h"
#include "verilated.h"

struct W { unsigned long long t; unsigned addr, data; };
static const unsigned long long FRAME = 811008;
static const int BITS = 505;

// The game's protocol, as tb_gtmr_oki plays it, for one chip.
struct Player {
    size_t k = 0;
    unsigned wait_mask = 0;
    bool cmd = false, spinning = false;
    unsigned long long not_before = 0;
    // one step at virtual time vt: returns true and the byte to write, or a bank
    bool step(const std::vector<W>& log, unsigned long long vt, unsigned dout,
              int& we, unsigned& din, unsigned& okb) {
        while (k < log.size() && vt >= log[k].t && vt >= not_before) {
            const W& w = log[k];
            if (w.addr == 0xe00001) { okb = w.data & 15; k++; continue; }
            const bool command = cmd || (w.data & 0x80);
            if (command && (dout & wait_mask)) { spinning = true; return false; }
            if (spinning) { spinning = false; not_before = vt + 150; return false; }
            din = w.data; we = 1;
            if (cmd) { cmd = false; wait_mask = 0; }
            else if (w.data & 0x80) cmd = true;
            else wait_mask = (w.data >> 3) & 15;
            k++;
            not_before = vt + 4;
            return true;
        }
        return false;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: %s set.rom oki_log frames [--every N] [--from F] [--lat N] [--spoil BIT] [--seed N]\n", argv[0]);
        return 2;
    }
    const long frames = atol(argv[3]);
    long every = 200, from = 300;
    int lat = 20, spoil = -1;
    unsigned seed = 1;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--every") && i + 1 < argc) every = atol(argv[++i]);
        else if (!strcmp(argv[i], "--from") && i + 1 < argc) from = atol(argv[++i]);
        else if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--spoil") && i + 1 < argc) spoil = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = atoi(argv[++i]);
    }
    srand(seed);

    std::vector<unsigned char> rom;
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END); rom.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(rom.data(), 1, rom.size(), f) != rom.size()) return 1;
    fclose(f);

    std::vector<W> log;
    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    { long fr; W w;
      while (fscanf(f, "%ld %x %x %llu", &fr, &w.addr, &w.data, &w.t) == 4)
          if (w.addr == 0x800001 || w.addr == 0xe00001) log.push_back(w); }
    fclose(f);

    Vkaneko_oki_state3* t = new Vkaneko_oki_state3;
    t->rst = 1; t->cen = 0; t->we = 0; t->din = 0; t->okb = 0;
    t->sdr_ack = 0; t->ss_scan = 0; t->ss_gsh = 0; t->ss_gi = 0;

    int div = 0;
    bool hold = false;
    struct Sdr { bool busy = false; int cnt = 0; } sdr[3];
    auto clock = [&]() {
        t->cen = (div == 0 && !hold) ? 7 : 0;
        div = (div + 1) % 24;
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
    };
    auto sdram = [&]() {
        unsigned ack = 0;
        for (int c = 0; c < 3; c++) {
            if (sdr[c].busy) {
                if (--sdr[c].cnt <= 0) {
                    unsigned long long d = 0;
                    unsigned a = c == 0 ? t->sdr_addr0 : c == 1 ? t->sdr_addr1 : t->sdr_addr2;
                    size_t b = (size_t)a * 2;
                    for (int j = 0; j < 8; j++)
                        if (b + j < rom.size()) d |= (unsigned long long)rom[b + j] << (8 * j);
                    t->sdr_dout[2 * c] = (uint32_t)d; t->sdr_dout[2 * c + 1] = (uint32_t)(d >> 32);
                    ack |= 1u << c; sdr[c].busy = false;
                }
            } else if ((t->sdr_req >> c) & 1) { sdr[c].busy = true; sdr[c].cnt = lat; }
        }
        t->sdr_ack = ack;
        return ack;
    };
    for (int i = 0; i < 48; i++) clock();
    t->rst = 0;

    Player pa, pb, pc;
    unsigned okb[3] = {0, 0, 0};
    unsigned long long vt = 0;                 // the game's time: stands while frozen
    const unsigned long long end = FRAME * frames;
    // C: 0 its own commands, 1 waiting for the point, 2 taking A's writes
    int c_mode = 0;
    unsigned long long c_next = 0;
    int c_pending = -1;

    long points = 0, bad_points = 0, differs = 0, compared_clocks = 0;
    unsigned long long first_bad = 0;
    long next_point = from;

    auto pop4 = [](unsigned v) { return __builtin_popcount(v & 15); };

    while (vt < end) {
        const long frame = (long)(vt / FRAME);
        // ---- a save point
        if (c_mode == 1) {
            // stop where both are quiet at the dead phase, on oki_div 13
            if (div == 13 && (t->ss_quiet & 5) == 5 && (t->ss_phase & 7) == 7) {
                hold = true;
                unsigned busyA = t->busy & 15, busyC = (t->busy >> 8) & 15;
                std::vector<int> a1(BITS), c1(BITS), a2(BITS), c3(BITS);
                auto moves = [&](int n, int mode, std::vector<int>* ra, std::vector<int>* rc) {
                    for (int m = 0; m < n; m++) {
                        int ga = t->ss_go & 1, gc = (t->ss_go >> 2) & 1;
                        if (ra) (*ra)[m] = ga;
                        if (rc) (*rc)[m] = gc;
                        int gi_a = ga, gi_c = mode == 1 ? ga : gc;
                        if (mode == 1 && m == spoil) gi_c ^= 1;
                        t->ss_scan = 5;
                        t->ss_gi = gi_a | (gi_c << 2);
                        t->ss_gsh = mode == 2 ? 4 : mode == 3 ? 1 : 5;
                        sdram(); clock();
                        t->ss_gsh = 0;
                    }
                };
                t->ss_scan = 5; sdram(); clock();
                moves(BITS, 0, &a1, &c1);          // 1: each round on its own
                int dbits = 0;
                for (int m = 0; m < BITS; m++) dbits += a1[m] != c1[m];
                moves(BITS, 1, &a2, nullptr);      // 2: C takes A's
                moves(BITS, 2, nullptr, &c3);      // 3: C round, read back
                int rbits = 0;
                for (int m = 0; m < BITS; m++) rbits += a2[m] != c3[m] || a1[m] != a2[m];
                t->ss_scan = 0; t->ss_gi = 0;
                // let go on oki_div 13, a whole number of 24-clock periods later
                do { sdram(); clock(); } while (div != 13);
                for (int i = 0; i < 24 * 40; i++) { sdram(); clock(); }   // the ROM feeders settle
                hold = false;
                pc = pa; okb[2] = okb[0]; c_mode = 2;
                points++;
                printf("point %ld: frame %ld, playing A %d C %d, chain bits differing before %d, read back wrong %d\n",
                       points, frame, pop4(busyA), pop4(busyC), dbits, rbits);
                if (rbits) bad_points++;
                next_point += every;
                continue;
            }
        }
        // ---- writes
        int we[3] = {0, 0, 0};
        unsigned din[3] = {0, 0, 0};
        pa.step(log, vt, t->dout & 0xff, we[0], din[0], okb[0]);
        pb.step(log, vt, (t->dout >> 8) & 0xff, we[1], din[1], okb[1]);
        if (c_mode == 0) {
            if (vt >= c_next) {
                if (c_pending >= 0) { we[2] = 1; din[2] = c_pending; c_pending = -1; c_next = vt + 8; }
                else if (rand() % 4 == 0) {
                    we[2] = 1; din[2] = ((rand() & 15) << 3); c_next = vt + 5000 + rand() % 200000;
                } else {
                    we[2] = 1; din[2] = 0x80 | (1 + rand() % 0x7e);
                    c_pending = ((1 << (rand() % 4)) << 4) | (rand() % 9);
                    c_next = vt + 8;
                }
                if (rand() % 8 == 0) okb[2] = rand() & 15;
            }
            if (frame >= next_point && c_pending < 0) c_mode = 1;
        } else if (c_mode == 2) {
            pc.step(log, vt, (t->dout >> 16) & 0xff, we[2], din[2], okb[2]);
            if (frame >= next_point - 4) { c_mode = 0; c_next = vt; }
        }
        t->we = we[0] | (we[1] << 1) | (we[2] << 2);
        t->din = din[0] | (din[1] << 8) | (din[2] << 16);
        t->okb = okb[0] | (okb[1] << 4) | (okb[2] << 8);

        // ---- compare
        const unsigned long long s = (unsigned long long)t->sound;
        unsigned sa = s & 0x3fff, sb = (s >> 14) & 0x3fff, sc = (s >> 28) & 0x3fff;
        unsigned da = t->dout & 0xff, db = (t->dout >> 8) & 0xff, dc = (t->dout >> 16) & 0xff;
        unsigned pa_ = t->sample & 1, pb_ = (t->sample >> 1) & 1, pc_ = (t->sample >> 2) & 1;
        bool ab = sa == sb && da == db && pa_ == pb_;
        bool ac = sa == sc && da == dc && pa_ == pc_;
        if (!ab) { if (!differs++) first_bad = vt; }
        if (c_mode == 2) {
            compared_clocks++;
            if (!ac) { if (!differs++) first_bad = vt; }
        }

        unsigned ack = sdram();
        clock();
        if (ack && (t->sdr_req & ack)) { t->sdr_ack = 0; t->eval(); }
        vt++;
        if (vt % (FRAME * 100) == 0) fprintf(stderr, "%llu of %ld frames\n", vt / FRAME, frames);
    }
    printf("%ld points, %ld read back wrong; %ld clocks of C compared; %ld clocks differing%s",
           points, bad_points, compared_clocks, differs, differs ? "" : "\n");
    if (differs) printf(", the first at frame %llu clock %llu\n", first_bad / FRAME, first_bad % FRAME);
    printf(differs || bad_points || points == 0 ? "FAIL\n" : "PASS\n");
    delete t;
    return differs || bad_points || points == 0;
}
