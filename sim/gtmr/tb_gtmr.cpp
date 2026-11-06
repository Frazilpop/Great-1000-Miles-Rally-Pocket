// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (Pocket) — whole-board harness for the gtmr board.
//
//   tb_gtmr <set.rom> <game id> <frames> <outdir> [dump frames, comma list]
//          [--fb-lat N] [--rom-lat N] [--ram-lat N] [--sdram-serial N]
//          [--inputs plan.txt]
//          [--state-save F FILE | --state-load FILE [--load-at F] [--resave FILE]]
//          [--after N]
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
// and here. The plan may also set hidelines=1/0 (Hide speed lines) and
// pause=1/0 (the board's pause input); MAME has no counterpart to either.
//
// Save states, through the board's state window (rtl/top/kaneko_state.sv), a
// word every 20 clocks as the Pocket's bridge gives them:
//   --state-save F FILE  asks for a clean point at frame F, reads the state
//                        into FILE and lets the game go on; FILE.tb gets the
//                        harness frame of the let-go, for the loaded run's inputs
//   --state-load FILE    writes FILE into the board at frame --load-at (30)
//                        and lets it go; the plan's inputs from the saving
//                        run's frame of the let-go on
//   --resave FILE        (with --state-load) reads the state back before the
//                        let-go, into FILE
//   --pocket             both through pocket/src/fpga/core/pocket_state.sv, the
//                        Pocket's side, with the bridge's clock and commands as
//                        the Pocket gives them: a pair of words read or written
//                        every --pocket-period clocks of clk_74a (75, its
//                        fastest), a pause of 40,000 after each 4 KB with the
//                        last pair read again; --pocket-reset holds the
//                        Pocket's reset over a load's file until after it,
//                        --pocket-menu saves from under the menu's pause
//   --crc                every frame's picture and sound CRCs to crc.txt, from the
//                        start, saved or not (for a run against one that never saved)
//   --after N            run N frames after the let-go, writing after.txt:
//                        one line a frame, "<k> <picture CRC> <sound CRC>",
//                        the sound's from the let-go's clock, every clock
// Each says the frame it froze in, the line, the 68000's PC and how many OKI
// channels were playing.

#include "Vkaneko_gtmr.h"
#include "Vbridge.h"
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
    int sdr_serial = 0;
    const char* trace_path = nullptr;
    long trace_count = 0;
    bool trace_data_only = false;
    bool no_sprites = false;
    const char* rand_path = nullptr;
    const char* inputs_path = nullptr;
    int save_frame = -1, load_frame = 30, after_frames = 300;
    const char* save_path = nullptr;
    const char* load_path = nullptr;
    const char* resave_path = nullptr;
    const char* save2_path = nullptr;
    int save2_frame = -1;
    bool pocket = false, p_reset = false, p_menu = false, crc_all = false;
    int p_period = 75;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--fb-lat") && i + 1 < argc)       fb_lat  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc) rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ram-lat") && i + 1 < argc) ram_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--sdram-serial") && i + 1 < argc) sdr_serial = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)   trace_path = argv[++i];
        else if (!strcmp(argv[i], "--trace-count") && i + 1 < argc) trace_count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace-data-only"))          trace_data_only = true;
        else if (!strcmp(argv[i], "--no-sprites"))               no_sprites = true;
        else if (!strcmp(argv[i], "--rand-from") && i + 1 < argc) rand_path = argv[++i];
        else if (!strcmp(argv[i], "--inputs") && i + 1 < argc)   inputs_path = argv[++i];
        else if (!strcmp(argv[i], "--state-save") && i + 2 < argc) { save_frame = atoi(argv[++i]); save_path = argv[++i]; }
        else if (!strcmp(argv[i], "--state-load") && i + 1 < argc) load_path = argv[++i];
        else if (!strcmp(argv[i], "--load-at") && i + 1 < argc)  load_frame = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--resave") && i + 1 < argc)   resave_path = argv[++i];
        else if (!strcmp(argv[i], "--save2") && i + 2 < argc)    { save2_frame = atoi(argv[++i]); save2_path = argv[++i]; }
        else if (!strcmp(argv[i], "--after") && i + 1 < argc)    after_frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pocket"))                    pocket = true;
        else if (!strcmp(argv[i], "--crc"))                       crc_all = true;
        else if (!strcmp(argv[i], "--pocket-period") && i + 1 < argc) p_period = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--pocket-reset"))              p_reset = true;
        else if (!strcmp(argv[i], "--pocket-menu"))               p_menu = true;
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
    t->pause = 0;
    t->hide_speed_lines = 0;
    // gtmr DSW1: everything off/default -> all ones in the high byte
    t->dsw = 0xff00;
    t->nv_we = 0; t->nv_dirty_clr = 0;
    t->dl_wr = 0;

    uint64_t cyc = 0;
    Vbridge* br = nullptr;
    auto tick = [&]() {
        if (br) {
            // the window between them, as each stood before this edge
            br->ss_status = t->ss_status; br->ss_loading = t->ss_loading;
            br->ss_refused = t->ss_refused; br->ss_do = t->ss_do; br->rom_loaded = t->rom_loaded;
            t->ss_save = br->ss_save; t->ss_go = br->ss_go; t->ss_addr = br->ss_addr;
            t->ss_rd = br->ss_rd; t->ss_wr = br->ss_wr; t->ss_di = br->ss_di;
            br->clk = 0; br->eval();
        }
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
        if (br) { br->clk = 1; br->eval(); }
        cyc++;
    };
    if (pocket) {
        br = new Vbridge;
        br->clk_74a = 0; br->clk = 0; br->bridge_endian_little = 0; br->reset_n = 1;
        br->bridge_rd = 0; br->bridge_wr = 0; br->savestate_start = 0; br->savestate_load = 0;
        br->eval();
    }

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
    fprintf(stats, "frame,draw_clocks64,overruns,cycles,bus_cycles,as_clocks,cap_tag,shown_tag,max_wait,max_wait_addr,hold_clocks,late_lines,max_line_clocks,late_spr_lines,max_spr_line_clocks\n");
    // Tile line fetch: lines whose fetch was still running when the next
    // line started (the display then reads a half-written bank), and the
    // longest fetch, start to done.
    uint64_t late_lines = 0, max_line = 0, line_t0 = 0;
    bool line_run_prev = false;
    // The same for the KC-002's scan-out of the sprite line from PSRAM.
    uint64_t late_spr = 0, max_spr = 0, spr_t0 = 0;
    bool spr_run_prev = false;
    // --sdram-serial N: the Pocket's one SDRAM, roughly. One access at a time,
    // N clocks each, the lowest-numbered waiting port first (kaneko_sdram's
    // urgent ports 0-6 come before the sprite ports 7-8), and a refresh of
    // 6 clocks every 350 (T_REFI 700 / T_RC 11 at 96 MHz).
    int srv_port = -1, srv_cnt = 0, refi = 350;

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
    int plan_offset = 0;          // a loaded run: its frames against the saving run's
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
            else if (st.name == "pause") { t->pause = st.val ? 1 : 0; continue; }
            else if (st.name == "hidelines") { t->hide_speed_lines = st.val ? 1 : 0; continue; }
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
    // (with a save state, from the clock it lets go, so two runs line up)
    FILE* trace = (trace_path && !save_path && !load_path) ? fopen(trace_path, "w") : nullptr;
    long traced = 0;
    bool dtack_prev = false;
    uint64_t bus_cycles = 0, as_clocks = 0, bus_cycles_f = 0, as_clocks_f = 0;
    bool as_prev = false;

    // ------------------------------------------------------- save states
    const int NW = 0x2C000;       // the file, in words
    std::vector<uint16_t> sbuf(NW, 0);
    enum { W_IDLE, W_ASK, W_ASKWAIT, W_READ, W_GO, W_GOWAIT, W_WRITE, W_LGO, W_LWAIT, W_DONE } wst = W_IDLE;
    int wk = 0, wc = 0;
    int reading_resave = 0;       // 1 the load's read-back, 2 --save2
    if (load_path) {
        FILE* f = fopen(load_path, "rb");
        if (!f) { perror(load_path); return 1; }
        std::vector<uint8_t> b(NW * 2, 0);
        size_t n = fread(b.data(), 1, b.size(), f);
        fclose(f);
        if (n != b.size()) fprintf(stderr, "state: %s is %zu bytes, not %d\n", load_path, n, NW * 2);
        for (int k = 0; k < NW; k++) sbuf[k] = (uint16_t)(b[2 * k] << 8 | b[2 * k + 1]);
    }
    int lg_saved = -1;            // the saving run's frame at its let-go
    if (load_path) {
        std::string tb = std::string(load_path) + ".tb";
        FILE* f = fopen(tb.c_str(), "r");
        if (f) { if (fscanf(f, "%d", &lg_saved) != 1) lg_saved = -1; fclose(f); }
    }
    auto crc_add = [](uint32_t c, const uint8_t* p, size_t n) {
        c = ~c;
        for (size_t i = 0; i < n; i++) {
            c ^= p[i];
            for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1)));
        }
        return ~c;
    };
    FILE* after = nullptr;
    int after_k = 0;
    uint32_t snd_crc = 0, snd_crc_all = 0;
    FILE* crcf = crc_all ? fopen((outdir + "/crc.txt").c_str(), "w") : nullptr;
    unsigned frz_busy = 0;
    auto write_state = [&](const char* path) {
        FILE* f = fopen(path, "wb");
        if (!f) { perror(path); exit(1); }
        for (int k = 0; k < NW; k++) { uint8_t b2[2] = { (uint8_t)(sbuf[k] >> 8), (uint8_t)sbuf[k] }; fwrite(b2, 1, 2, f); }
        fclose(f);
        unsigned pc = (unsigned)sbuf[0x62] << 16 | sbuf[0x63];
        fprintf(stderr, "state: %s: froze in frame %u, line %u, dot %u, PC %06x%s, OKI channels playing %d+%d\n",
                path, (unsigned)sbuf[0x0f] | (unsigned)sbuf[0x0e] << 16, sbuf[0x20], sbuf[0x21], pc,
                sbuf[0x68] ? " (STOP)" : "", __builtin_popcount(frz_busy & 15), __builtin_popcount((frz_busy >> 4) & 15));
    };
    uint64_t letgo_cyc = 0;
    auto let_go = [&]() {
        letgo_cyc = cyc;
        std::string ap = outdir + "/after.txt";
        after = fopen(ap.c_str(), "w");
        after_k = 0; snd_crc = 0;
        frames = frame + after_frames;
        fprintf(stderr, "state: let go at frame %d, clock %llu\n", frame, (unsigned long long)cyc);
        if (trace_path && !trace && (!resave_path || reading_resave || !load_path)) trace = fopen(trace_path, "w");
        if (save_path && !load_path) {
            std::string tb = std::string(save_path) + ".tb";
            FILE* f = fopen(tb.c_str(), "w");
            fprintf(f, "%d\n", frame);
            fclose(f);
        }
        if (load_path && lg_saved >= 0) {
            plan_i = 0; p1v = 0; coinv = 0; startv = 0;
            t->p1 = 0; t->coin = 0; t->start = 0; t->pause = 0; t->hide_speed_lines = 0;
            plan_offset = lg_saved - frame;
            apply_inputs(lg_saved);
        }
        wst = W_DONE;
    };

    // ---- --pocket: the bridge's side, on clk_74a
    enum { P_IDLE, P_ACK, P_POLL, P_DELAY, P_READ, P_STALL, P_WRITE, P_LRESET, P_LACK, P_LPOLL, P_WAITGO, P_DONE } ps = P_IDLE;
    const long FILE_BYTES = NW * 2, P_CHUNK = 4096, P_STALL_CLKS = 40000;
    long pa = 0, pt = 0, pchunk_end = 0;
    bool pfirst = true, p_resave = false, p_reset_n = true;
    double pphase = 0;
    std::vector<uint8_t> pfile;
    auto p_clock = [&]() {
        br->bridge_rd = 0; br->bridge_wr = 0;
        switch (ps) {
        case P_IDLE:
            if (save_path && !load_path && frame >= save_frame) {
                br->savestate_start = 1; ps = P_ACK; p_resave = false;
                fprintf(stderr, "state: Savestate Start at frame %d\n", frame);
            } else if (load_path && frame >= load_frame) {
                pa = 0; pt = 0; pchunk_end = P_CHUNK;
                if (p_reset) { p_reset_n = false; br->reset_n = 0; }
                ps = P_WRITE;
            }
            break;
        case P_ACK:
            if (br->savestate_start_ack) { br->savestate_start = 0; ps = P_POLL; }
            break;
        case P_POLL:
            if (br->savestate_start_err) { fprintf(stderr, "state: Savestate Start answered an error\n"); exit(1); }
            if (br->savestate_start_ok) {
                frz_busy = R.kaneko_gtmr__DOT__dbg_oki_busy;
                pfile.assign(FILE_BYTES, 0); pa = 0; pt = 0; pfirst = true; pchunk_end = P_CHUNK;
                ps = P_DELAY;
            }
            break;
        case P_DELAY:
            if (++pt == 20000) { pt = 0; ps = P_READ; }
            break;
        case P_READ:
            // a pair: its address, the bus's value a few clocks on (what the
            // read before fetched), then this read's strobe
            if (pt == 0) br->bridge_addr = 0x40000000 + pa;
            if (pt == 4 && !pfirst) {
                uint32_t d = br->bridge_rd_data; long o = pa - 4;
                pfile[o] = d >> 24; pfile[o + 1] = d >> 16; pfile[o + 2] = d >> 8; pfile[o + 3] = d;
            }
            if (pt == 5) br->bridge_rd = 1;
            if (++pt == p_period) {
                pt = 0; pfirst = false;
                if (pa >= FILE_BYTES) {
                    for (int k = 0; k < NW; k++) sbuf[k] = (uint16_t)(pfile[2 * k] << 8 | pfile[2 * k + 1]);
                    write_state(p_resave ? resave_path : save_path);
                    ps = P_WAITGO;
                }
                else if (pa == pchunk_end) { ps = P_STALL; pt = 0; }
                else pa += 4;
            }
            break;
        case P_STALL:
            // a chunk gone to the card: the next starts with the pair just read, again
            if (++pt >= P_STALL_CLKS) { pt = 0; pfirst = true; pchunk_end += P_CHUNK; ps = P_READ; }
            break;
        case P_WRITE:
            if (pt == 0) {
                br->bridge_addr = 0x40000000 + pa;
                br->bridge_wr_data = (uint32_t)(sbuf[pa / 2] << 16 | sbuf[pa / 2 + 1]);
            }
            if (pt == 5) br->bridge_wr = 1;
            if (++pt == p_period) {
                pt = 0; pa += 4;
                if (pa == FILE_BYTES) { ps = p_reset ? P_LRESET : P_LACK; br->savestate_load = p_reset ? 0 : 1; }
                else if (pa == pchunk_end) { pchunk_end += P_CHUNK; pt = -P_STALL_CLKS; }
            }
            break;
        case P_LRESET:
            // the Pocket's reset let go before Savestate Load
            if (++pt == 2000) { p_reset_n = true; br->reset_n = 1; }
            if (pt == 4000) { pt = 0; br->savestate_load = 1; ps = P_LACK; }
            break;
        case P_LACK:
            if (br->savestate_load_ack) { br->savestate_load = 0; ps = P_LPOLL; }
            break;
        case P_LPOLL:
            if (br->savestate_load_err) { fprintf(stderr, "state: Savestate Load answered an error; the game goes on\n"); ps = P_DONE; }
            else if (br->savestate_load_ok) {
                if (resave_path) { br->savestate_start = 1; ps = P_ACK; p_resave = true; }
                else ps = P_WAITGO;
            }
            break;
        default: break;
        }
        br->clk_74a = 1; br->eval();
        br->clk_74a = 0; br->eval();
    };
    bool p_letgo_seen = false;

    while (frame < frames) {
        if (br) {
            for (pphase += 74.25 / 48.0; pphase >= 1; pphase -= 1) p_clock();
            // the board's reset and pause as core_top makes them
            if (p_reset) t->rst = !p_reset_n && !br->hold_reset;
            // (the menu open from 5 frames before the save until it has let go)
            if (p_menu) t->pause = (save_path && !load_path && frame >= save_frame - 5 && !p_letgo_seen) && !br->pause_lift;
            if (ps == P_WAITGO && t->ss_status == 0 && !p_letgo_seen) { p_letgo_seen = true; let_go(); ps = P_DONE; }
        }
        // ---- the state window, a clock at a time
        if (!br) { t->ss_save = 0; t->ss_go = 0; t->ss_rd = 0; t->ss_wr = 0; }
        if (!br) switch (wst) {
        case W_IDLE:
            if (save_path && frame >= save_frame) { wst = W_ASK; reading_resave = 0; }
            else if (load_path && frame >= load_frame) { wst = W_WRITE; wk = 0; wc = 0; }
            break;
        case W_ASK:
            t->ss_save = 1; wc = 0; wst = W_ASKWAIT; break;
        case W_ASKWAIT:
            if (++wc < 12) break;
            if (t->ss_status == 3) { fprintf(stderr, "state: the save found no point (error)\n"); return 1; }
            if (t->ss_status == 2) { frz_busy = R.kaneko_gtmr__DOT__dbg_oki_busy; wst = W_READ; wk = 0; wc = 0; }
            break;
        case W_READ:
            if (wc == 0) {
                if (wk > 0) sbuf[wk - 1] = t->ss_do;
                if (wk == NW) {
                    write_state(reading_resave == 2 ? save2_path : reading_resave ? resave_path : save_path);
                    if (t->ss_status == 3) { fprintf(stderr, "state: error while reading\n"); return 1; }
                    wst = W_GO; break;
                }
                t->ss_addr = wk; t->ss_rd = 1;
            }
            if (++wc == 20) { wc = 0; wk++; }
            break;
        case W_GO:
            t->ss_go = 1; wc = 0; wst = W_GOWAIT; break;
        case W_GOWAIT:
            if (++wc < 4) break;
            if (t->ss_status == 3) { fprintf(stderr, "state: error at the let-go\n"); return 1; }
            if (t->ss_status == 0) let_go();
            break;
        case W_WRITE:
            if (wc == 0) {
                if (wk == 20 && !t->ss_loading) {
                    fprintf(stderr, "state: %s refused%s; the game goes on\n", load_path, t->ss_refused ? " (header)" : "");
                    wst = W_DONE; break;
                }
                if (wk == NW) { wst = W_LGO; wc = 0; break; }
                t->ss_addr = wk; t->ss_di = sbuf[wk]; t->ss_wr = 1;
            }
            if (++wc == 20) { wc = 0; wk++; }
            break;
        case W_LGO:
            if (++wc < 20) break;
            t->ss_go = 1; wc = 0; wst = W_LWAIT; break;
        case W_LWAIT:
            if (++wc < 4) break;
            if (t->ss_status == 3) { fprintf(stderr, "state: the load failed (error)\n"); return 1; }
            if (resave_path && t->ss_status == 2) {
                frz_busy = R.kaneko_gtmr__DOT__dbg_oki_busy;
                reading_resave = 1; wst = W_ASK; break;
            }
            if (t->ss_status == 0) let_go();
            break;
        case W_DONE:
            // --save2 F FILE: another save at frame F after the let-go (what has drifted)
            if (save2_path && after && frame >= save2_frame) { wst = W_ASK; reading_resave = 2; save2_frame = 1 << 30; }
            break;
        default: break;
        }

        // ---- inputs for the next edge, from the outputs of the last one
        uint32_t req = t->rom_req;
        uint32_t ack = 0;
        if (sdr_serial) {
            if (--refi <= 0 && srv_port < 0) { refi = 350; srv_port = NP; srv_cnt = 6; }
            for (int p = 0; p < NP; p++)
                if (!rp[p].busy && ((req >> p) & 1)) {
                    rp[p].busy = 1;
                    rp[p].addr = (uint32_t)getbits(t->rom_addr, p * SDR_AW, SDR_AW);
                }
            if (srv_port < 0)
                for (int p = 0; p < NP; p++)
                    if (rp[p].busy) { srv_port = p; srv_cnt = sdr_serial; break; }
            if (srv_port >= 0 && --srv_cnt <= 0) {
                if (srv_port < NP) {
                    Port& P = rp[srv_port];
                    ack |= 1u << srv_port;
                    uint32_t w = P.addr & ~3u;
                    for (int k = 0; k < 4; k++)
                        setbits(t->rom_dout, srv_port * 64 + k * 16, 16, rom_word(w + k));
                    P.busy = 0;
                }
                srv_port = -1;
            }
        }
        else for (int p = 0; p < NP; p++) {
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
        if (after || crcf) {
            uint16_t sv = t->snd; uint8_t b2[2] = { (uint8_t)sv, (uint8_t)(sv >> 8) };
            if (after) snd_crc = crc_add(snd_crc, b2, 2);
            if (crcf) snd_crc_all = crc_add(snd_crc_all, b2, 2);
        }

        {
            bool run = R.kaneko_gtmr__DOT__u_line__DOT__running;
            if (R.kaneko_gtmr__DOT__line_start && line_run_prev) late_lines++;
            if (run && !line_run_prev) line_t0 = cyc;
            if (!run && line_run_prev && cyc - line_t0 > max_line) max_line = cyc - line_t0;
            line_run_prev = run;
            bool so = R.kaneko_gtmr__DOT__u_spr__DOT__so_busy;
            if (R.kaneko_gtmr__DOT__u_spr__DOT__fetch_go && spr_run_prev) late_spr++;
            if (so && !spr_run_prev) spr_t0 = cyc;
            if (!so && spr_run_prev && cyc - spr_t0 > max_spr) max_spr = cyc - spr_t0;
            spr_run_prev = so;
        }
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
                    if (save_path || load_path)   // (a save state's: the clock from the let-go too)
                        fprintf(trace, "%06x %c %04x %04x %llu\n", a, rd ? 'R' : 'W', d & m, m, (unsigned long long)(cyc - letgo_cyc));
                    else
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
                fprintf(stats, "%d,%u,%u,%llu,%llu,%llu,%u,%u,%llu,%06x,%llu,%llu,%llu,%llu,%llu\n", frame,
                        (unsigned)R.kaneko_gtmr__DOT__spr_draw_clocks,
                        (unsigned)R.kaneko_gtmr__DOT__spr_overruns,
                        (unsigned long long)cyc,
                        (unsigned long long)(bus_cycles - bus_cycles_f),
                        (unsigned long long)(as_clocks - as_clocks_f),
                        (unsigned)R.kaneko_gtmr__DOT__u_spr__DOT__cap_tag,
                        (unsigned)R.kaneko_gtmr__DOT__u_spr__DOT__shown_tag,
                        (unsigned long long)max_wait, max_wait_addr,
                        (unsigned long long)hold_clocks,
                        (unsigned long long)late_lines, (unsigned long long)max_line,
                        (unsigned long long)late_spr, (unsigned long long)max_spr);
                late_lines = 0; max_line = 0; late_spr = 0; max_spr = 0;
                bus_cycles_f = bus_cycles; as_clocks_f = as_clocks;
                max_wait = 0; max_wait_addr = 0; hold_clocks = 0;
                fflush(stats);
                if (frame % 10 == 0) { fprintf(stderr, "frame %d  cycles %llu\n", frame, (unsigned long long)cyc); }
                if (crcf) {
                    fprintf(crcf, "%d %08x %08x\n", frame, crc_add(0, img.data(), img.size()), snd_crc_all);
                    snd_crc_all = 0;
                }
                if (after) {
                    uint32_t pc = crc_add(0, img.data(), img.size());
                    fprintf(after, "%d %08x %08x\n", after_k++, pc, snd_crc);
                    snd_crc = 0;
                    fflush(after);
                }
                frame++;
                apply_inputs(frame + plan_offset);
                y = 0; x = 0;
            }
            prev_hb = hb; prev_vb = vb;
        }
    }

    fclose(stats);
    if (after) fclose(after);
    if (crcf) fclose(crcf);
    t->final();
    delete t;
    return 0;
}
