// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (Pocket) — whole-board harness for the gtmr board.
//
//   tb_gtmr <set.rom> <game id> <frames> <outdir> [dump frames, comma list]
//          [--fb-lat N] [--rom-lat N] [--ram-lat N] [--inputs plan.txt]
//
// Hosts kaneko_gtmr the way the Pocket shell does, with behavioural memories:
//
//   SDRAM   the .rom image; nine independent read ports, fixed latency.
//           Optimistic: no contention, no refresh. It answers "does the board
//           work", not "does it fit the bandwidth".
//   SRAM    128K x 16, fixed latency.
//   PSRAM   two 4M-word arrays, row reads/writes, fixed latency per row
//           (default 96 clocks: sixteen ~100 ns async accesses at 48 MHz).
//
// The loader snoop is fed the sprite region before reset is released, so the
// blank-code table is built exactly as on the Pocket.
//
// Writes frame_NNNNN.ppm for each requested frame and one line per frame to
// stats.csv: frame, sprite draw clocks (/64), overruns so far, cycles, 68000
// bus cycles and AS clocks in the frame, the KC-002's capture and shown tags,
// the longest bus cycle (clocks AS to DTACK) and its byte address, and the
// clocks spent waiting beyond a no-wait cycle.
//
// --inputs takes tools/mame_gtmr_io_profile.lua's plan file ("<frame>
// coin=1 b2=1 right=0 ..."), so a race can be played the same way in MAME
// and here.

#include "Vkaneko_gtmr.h"
#include "Vkaneko_gtmr___024root.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <sys/stat.h>

static const int NP = 9;
static const int SDR_AW = 25;

// ---------------------------------------------------------------- wide bits
template <typename W>
static uint64_t getbits(const W& w, int lo, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((w[b >> 5] >> (b & 31)) & 1) v |= 1ull << i;
    }
    return v;
}
template <typename W>
static void setbits(W& w, int lo, int n, uint64_t v) {
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((v >> i) & 1) w[b >> 5] |= (1u << (b & 31));
        else              w[b >> 5] &= ~(1u << (b & 31));
    }
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s set.rom game frames outdir [dumps] [--fb-lat N] [--rom-lat N] [--ram-lat N]\n", argv[0]);
        return 2;
    }
    const char* rom_path = argv[1];
    int game   = atoi(argv[2]);
    int frames = atoi(argv[3]);
    std::string outdir = argv[4];
    std::set<int> dumps;
    int fb_lat = 96, rom_lat = 10, ram_lat = 4;
    const char* trace_path = nullptr;
    long trace_count = 0;
    bool trace_data_only = false;
    bool no_sprites = false;
    const char* rand_path = nullptr;
    const char* inputs_path = nullptr;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--fb-lat") && i + 1 < argc)       fb_lat  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc) rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ram-lat") && i + 1 < argc) ram_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)   trace_path = argv[++i];
        else if (!strcmp(argv[i], "--trace-count") && i + 1 < argc) trace_count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace-data-only"))          trace_data_only = true;
        else if (!strcmp(argv[i], "--no-sprites"))               no_sprites = true;
        else if (!strcmp(argv[i], "--rand-from") && i + 1 < argc) rand_path = argv[++i];
        else if (!strcmp(argv[i], "--inputs") && i + 1 < argc)   inputs_path = argv[++i];
        else {
            std::string s = argv[i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
    }
    mkdir(outdir.c_str(), 0755);

    // -------------------------------------------------------------- memories
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(rom_path, "rb");
        if (!f) { perror(rom_path); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n);
        if (fread(rom.data(), 1, n, f) != (size_t)n) { perror("read"); return 1; }
        fclose(f);
    }
    rom.resize(64u << 20, 0);
    auto rom_word = [&](uint32_t w) -> uint16_t {
        return (uint16_t)rom[2 * w] | ((uint16_t)rom[2 * w + 1] << 8);
    };
    std::vector<uint16_t> sram(128 * 1024, 0);
    std::vector<uint16_t> fb[2] = { std::vector<uint16_t>(4u << 20, 0x5a5a),
                                    std::vector<uint16_t>(4u << 20, 0xa5a5) };

    Verilated::commandArgs(argc, argv);
    Vkaneko_gtmr* t = new Vkaneko_gtmr;

    t->game = game;
    t->rst = 1; t->rst_por = 1; t->rom_loaded = 0;
    t->p1 = 0; t->p2 = 0; t->coin = 0; t->start = 0; t->service = 0; t->test = 0;
    // gtmr DSW1: everything off/default -> all ones in the high byte
    t->dsw = 0xff00;
    t->nv_we = 0; t->nv_dirty_clr = 0;
    t->dl_wr = 0;

    uint64_t cyc = 0;
    auto tick = [&]() {
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        cyc++;
    };

    // Power-on: a few clocks of reset, then the EEPROM image (all ones, as an
    // erased 93C46), then the sprite region through the snoop.
    for (int i = 0; i < 16; i++) tick();
    t->rst_por = 0;
    for (int a = 0; a < 64; a++) {
        t->nv_we = 1; t->nv_addr = a; t->nv_din = 0xffff; tick();
    }
    t->nv_we = 0;
    for (uint32_t w = 0x380000; w < 0x380000 + 0x420000; w++) {
        t->dl_wr = 1; t->dl_addr = w; t->dl_data = rom_word(w);
        tick();
    }
    t->dl_wr = 0;
    t->rom_loaded = 1;
    t->rst = 0;

    // ----------------------------------------------------------- port state
    struct Port { int busy = 0; int cnt = 0; uint32_t addr = 0; };
    Port rp[NP];
    Port ram_p;
    Port fbp[2];

    // ------------------------------------------------------------- video
    std::vector<uint8_t> img(320 * 240 * 3, 0);
    std::vector<uint16_t> sprimg(320 * 240, 0);
    int x = 0, y = 0, frame = 0;
    int prev_hb = 1, prev_vb = 1;
    FILE* stats = fopen((outdir + "/stats.csv").c_str(), "w");
    fprintf(stats, "frame,draw_clocks64,overruns,cycles,bus_cycles,as_clocks,cap_tag,shown_tag,max_wait,max_wait_addr,hold_clocks\n");

    auto& R = *t->rootp;
    R.kaneko_gtmr__DOT__dbg_spr_off = no_sprites;

    // MAME's random numbers, in the order the game read them (every
    // "900014 R" line of a MAME bus trace).
    std::vector<uint16_t> rnds;
    size_t rnd_i = 0;
    bool rnd_next = false;
    if (rand_path) {
        FILE* f = fopen(rand_path, "r");
        char line[128];
        while (f && fgets(line, sizeof line, f)) {
            unsigned a, d, m; char rw;
            if (sscanf(line, "%x %c %x %x", &a, &rw, &d, &m) == 4 && a == 0x900014 && rw == 'R')
                rnds.push_back((uint16_t)d);
        }
        if (f) fclose(f);
        fprintf(stderr, "replaying %zu random numbers\n", rnds.size());
        R.kaneko_gtmr__DOT__dbg_rnd_use = 1;
        R.kaneko_gtmr__DOT__dbg_rnd = rnds.empty() ? 0 : rnds[0];
    }

    // Scripted inputs: one line per frame, "<frame> coin=1 b2=1 right=0 ...",
    // the same plan file tools/mame_gtmr_io_profile.lua takes. A field keeps
    // its value until a later line changes it. Applied at the start of the
    // numbered frame (counting from 0, as the harness does).
    struct Step { int frame; std::string name; int val; };
    std::vector<Step> plan;
    size_t plan_i = 0;
    if (inputs_path) {
        FILE* f = fopen(inputs_path, "r");
        if (!f) { perror(inputs_path); return 1; }
        char line[512];
        while (fgets(line, sizeof line, f)) {
            char* save = nullptr;
            char* tok = strtok_r(line, " \t\r\n", &save);
            if (!tok) continue;
            int fr = atoi(tok);
            while ((tok = strtok_r(nullptr, " \t\r\n", &save))) {
                char* eq = strchr(tok, '=');
                if (!eq) continue;
                *eq = 0;
                plan.push_back({fr, tok, atoi(eq + 1)});
            }
        }
        fclose(f);
        fprintf(stderr, "inputs: %zu steps from %s\n", plan.size(), inputs_path);
    }
    uint8_t p1v = 0, coinv = 0, startv = 0;
    auto apply_inputs = [&](int fr) {
        while (plan_i < plan.size() && plan[plan_i].frame <= fr) {
            const Step& st = plan[plan_i++];
            int bit = -1;
            // p1 = {b4,b3,b2,b1,right,left,down,up}, as core_top.v wires it
            if      (st.name == "up")    bit = 0;
            else if (st.name == "down")  bit = 1;
            else if (st.name == "left")  bit = 2;
            else if (st.name == "right") bit = 3;
            else if (st.name == "b1")    bit = 4;
            else if (st.name == "b2")    bit = 5;
            else if (st.name == "coin")  { coinv  = st.val ? 1 : 0; t->coin  = coinv;  continue; }
            else if (st.name == "start") { startv = st.val ? 1 : 0; t->start = startv; continue; }
            if (bit >= 0) {
                if (st.val) p1v |= (1u << bit); else p1v &= ~(1u << bit);
                t->p1 = p1v;
            }
        }
    };
    apply_inputs(0);

    // CPU stalls: clocks from AS asserted to DTACK, the longest per frame and
    // the clocks spent waiting beyond a no-wait cycle.
    uint64_t as_start = 0, max_wait = 0, hold_clocks = 0;
    uint32_t max_wait_addr = 0;
    bool waiting = false;

    // Bus trace, in tools/mame_gtmr_bus_trace.lua's format: one line per
    // 68000 bus cycle, at the clock DTACK is first asserted.
    FILE* trace = trace_path ? fopen(trace_path, "w") : nullptr;
    long traced = 0;
    bool dtack_prev = false;
    uint64_t bus_cycles = 0, as_clocks = 0, bus_cycles_f = 0, as_clocks_f = 0;
    bool as_prev = false;

    while (frame < frames) {
        // ---- inputs for the next edge, from the outputs of the last one
        uint32_t req = t->rom_req;
        uint32_t ack = 0;
        for (int p = 0; p < NP; p++) {
            Port& P = rp[p];
            if (!P.busy && ((req >> p) & 1)) {
                P.busy = 1; P.cnt = rom_lat;
                P.addr = (uint32_t)getbits(t->rom_addr, p * SDR_AW, SDR_AW);
            }
            if (P.busy) {
                if (--P.cnt <= 0) {
                    ack |= 1u << p;
                    uint32_t w = P.addr & ~3u;    // word address, line aligned
                    for (int k = 0; k < 4; k++)
                        setbits(t->rom_dout, p * 64 + k * 16, 16, rom_word(w + k));
                    P.busy = 0;
                }
            }
        }
        t->rom_ack = ack;

        t->ram_ack = 0;
        if (!ram_p.busy && t->ram_req) { ram_p.busy = 1; ram_p.cnt = ram_lat; }
        if (ram_p.busy && --ram_p.cnt <= 0) {
            uint32_t a = t->ram_addr & 0x1ffff;
            if (t->ram_we) {
                uint16_t v = sram[a];
                if (t->ram_be & 2) v = (v & 0x00ff) | (t->ram_din & 0xff00);
                if (t->ram_be & 1) v = (v & 0xff00) | (t->ram_din & 0x00ff);
                sram[a] = v;
            } else t->ram_dout = sram[a];
            t->ram_ack = 1;
            ram_p.busy = 0;
        }

        for (int c = 0; c < 2; c++) {
            Port& P = fbp[c];
            bool rq = c ? t->fb1_req : t->fb0_req;
            if (c) t->fb1_ack = 0; else t->fb0_ack = 0;
            if (!P.busy && rq) { P.busy = 1; P.cnt = fb_lat; }
            if (P.busy && --P.cnt <= 0) {
                uint32_t a  = c ? t->fb1_addr : t->fb0_addr;
                bool     we = c ? t->fb1_we : t->fb0_we;
                if (we) {
                    uint32_t m = c ? t->fb1_wmask : t->fb0_wmask;
                    for (int k = 0; k < 16; k++)
                        if ((m >> k) & 1)
                            fb[c][(a + k) & 0x3fffff] = (uint16_t)getbits(c ? t->fb1_wdata : t->fb0_wdata, 16 * k, 16);
                } else {
                    for (int k = 0; k < 16; k++) {
                        if (c) setbits(t->fb1_rdata, 16 * k, 16, fb[c][(a + k) & 0x3fffff]);
                        else   setbits(t->fb0_rdata, 16 * k, 16, fb[c][(a + k) & 0x3fffff]);
                    }
                }
                if (c) t->fb1_ack = 1; else t->fb0_ack = 1;
                P.busy = 0;
            }
        }

        tick();

        {
            bool as = R.kaneko_gtmr__DOT__dbg_as;
            if (as) as_clocks++;
            if (as && !as_prev) { bus_cycles++; as_start = cyc; waiting = true; }
            if (as && waiting && R.kaneko_gtmr__DOT__dbg_dtack) {
                uint64_t w = cyc - as_start;
                waiting = false;
                if (w > max_wait) { max_wait = w; max_wait_addr = (uint32_t)R.kaneko_gtmr__DOT__dbg_eab << 1; }
                if (w > 3) hold_clocks += w - 3;
            }
            if (!as) waiting = false;
            as_prev = as;
        }
        // ---- bus monitor: random replay and trace, at the clock DTACK is
        // first asserted for a bus cycle
        {
            bool dt = R.kaneko_gtmr__DOT__dbg_dtack && R.kaneko_gtmr__DOT__dbg_as;
            if (dt && !dtack_prev) {
                uint32_t a  = (uint32_t)R.kaneko_gtmr__DOT__dbg_eab << 1;
                bool     rd = R.kaneko_gtmr__DOT__dbg_rw;
                // The 68000 latches read data after DTACK, so the next number
                // goes in when this cycle ends, not now.
                if (!rnds.empty() && a == 0x900014 && rd) rnd_next = true;
                if (trace && !(trace_data_only && rd && a < 0x0ffffe)) {
                    uint32_t ds = R.kaneko_gtmr__DOT__dbg_ds;
                    uint32_t d  = rd ? R.kaneko_gtmr__DOT__dbg_din : R.kaneko_gtmr__DOT__dbg_dout;
                    uint32_t m  = (ds == 3) ? 0xffff : (ds == 2) ? 0xff00 : 0x00ff;
                    fprintf(trace, "%06x %c %04x %04x\n", a, rd ? 'R' : 'W', d & m, m);
                    if (++traced >= trace_count && trace_count > 0) { fclose(trace); trace = nullptr; }
                }
            }
            if (!dt && dtack_prev && rnd_next) {
                rnd_next = false;
                if (++rnd_i < rnds.size()) R.kaneko_gtmr__DOT__dbg_rnd = rnds[rnd_i];
            }
            dtack_prev = dt;
        }

        // ---- video capture
        if (t->ce_pix) {
            int hb = t->hblank, vb = t->vblank;
            if (!hb && !vb) {
                if (x < 320 && y < 240) {
                    uint8_t* px = &img[(y * 320 + x) * 3];
                    px[0] = t->r; px[1] = t->g; px[2] = t->b;
                    sprimg[y * 320 + x] = R.kaneko_gtmr__DOT__dbg_spr_word;
                }
                x++;
            }
            if (hb && !prev_hb && !vb) { y++; x = 0; }
            if (vb && !prev_vb) {
                if (trace) fprintf(trace, "# frame %d\n", frame);
                if (dumps.count(frame)) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), frame);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n320 240\n255\n");
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                    snprintf(fn, sizeof fn, "%s/spr_%05d.bin", outdir.c_str(), frame);
                    f = fopen(fn, "wb");
                    fwrite(sprimg.data(), 2, sprimg.size(), f);
                    fclose(f);
                }
                fprintf(stats, "%d,%u,%u,%llu,%llu,%llu,%u,%u,%llu,%06x,%llu\n", frame,
                        (unsigned)R.kaneko_gtmr__DOT__spr_draw_clocks,
                        (unsigned)R.kaneko_gtmr__DOT__spr_overruns,
                        (unsigned long long)cyc,
                        (unsigned long long)(bus_cycles - bus_cycles_f),
                        (unsigned long long)(as_clocks - as_clocks_f),
                        (unsigned)R.kaneko_gtmr__DOT__u_spr__DOT__cap_tag,
                        (unsigned)R.kaneko_gtmr__DOT__u_spr__DOT__shown_tag,
                        (unsigned long long)max_wait, max_wait_addr,
                        (unsigned long long)hold_clocks);
                bus_cycles_f = bus_cycles; as_clocks_f = as_clocks;
                max_wait = 0; max_wait_addr = 0; hold_clocks = 0;
                fflush(stats);
                if (frame % 10 == 0) { fprintf(stderr, "frame %d  cycles %llu\n", frame, (unsigned long long)cyc); }
                frame++;
                apply_inputs(frame);
                y = 0; x = 0;
            }
            if (!vb && prev_vb) { y = 0; x = 0; }
            prev_hb = hb; prev_vb = vb;
        }
    }

    fclose(stats);
    t->final();
    delete t;
    return 0;
}
