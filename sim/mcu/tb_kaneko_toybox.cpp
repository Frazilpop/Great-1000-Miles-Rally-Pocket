// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 Pocket — TOYBOX MCU (rtl/mcu/kaneko_toybox.sv) against MAME.
//
// Three layers, each one closer to MAME than the last:
//
//  1. SYNTHETIC — always runs, needs no ROM. A C++ port of MAME's mcu_run
//     (ref_run below: the same expressions, the same host-byte casts) is run
//     beside the RTL from random RAM, for every command, every subcommand
//     0..63, both tables, random destinations including odd ones and ones
//     that wrap the 64 KB. The whole 64 KB and the EEPROM are compared after
//     every command. The data ROM is random, with headers planted so lengths
//     run from 0 to several KB.
//
//  2. REAL DATA ROM — if build/roms/<set>_mcudata.bin exists
//     (sim/mcu/extract_mcudata.py), every subcommand against the real ROM. And
//     if MAME's own decrypted region was captured, the C++ decryption is
//     checked against it byte for byte — the step that ties the tables here,
//     and so the reference, to MAME rather than to a transcription.
//
//  3. MAME REPLAY — if build/mcu_mame/<set>/cap.bin exists
//     (sim/mcu/capture.sh), every command MAME ran, from MAME's before-state,
//     with the game's own com-register writes, compared to MAME's after-state.
//     The reference port is held to the same after-state, so a fault in it
//     cannot hide behind agreement with the RTL.
//
// The RAM and ROM servants answer after random delays and check that a
// request is held steady until it is acked; the EEPROM is a 64 x 16 array with
// one clock of read latency, like the board's. `busy` must rise in the very
// cycle of the triggering write (the board withholds DTACK on it) and nothing
// may touch RAM, ROM or EEPROM while it is low.
//
// ROM-derived inputs live under build/ and are never committed (hard rule 2);
// layers 2 and 3 SKIP with a message when they are absent.
//
// The two decryption tables below are data from MAME's kaneko_toybox.cpp,
// BSD-3-Clause, copyright-holders David Haywood, Luca Elia, Sebastien Volpe.

#include <verilated.h>
#include "Vkaneko_toybox.h"
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "ref_run is MAME's mcu_run on a little-endian host; build on one"
#endif

namespace {

const uint8_t TABLE_NORMAL[256] = {
    0x7b,0x82,0xf0,0xbc,0x7f,0x1d,0xa2,0xc5,0x2a,0xfa,0x55,0xee,0x1a,0xd0,0x59,0x76,
    0x5e,0x75,0x79,0x16,0xa5,0xf6,0x84,0xed,0x0f,0x2e,0xf2,0x36,0x61,0xac,0xcd,0xab,
    0x01,0x3b,0x01,0x87,0x73,0xab,0xce,0x5d,0xd4,0x1d,0x68,0x2a,0x35,0xea,0x13,0x27,
    0x00,0xaa,0x46,0x36,0x6e,0x65,0x80,0x7e,0x19,0xe2,0x96,0xab,0xac,0xa5,0x6c,0x63,
    0x4a,0x6f,0x87,0xf6,0x6a,0xac,0x38,0xe2,0x1f,0x87,0xf9,0xaa,0xf5,0x41,0x60,0xa6,
    0x42,0xb9,0x30,0xf2,0xc3,0x1c,0x4e,0x4b,0x08,0x10,0x42,0x32,0xbf,0xb2,0xc5,0x0f,
    0x7a,0xab,0x97,0xf6,0xe7,0xb3,0x46,0xf8,0xec,0x2b,0x7d,0x5f,0xb1,0x10,0x03,0xe4,
    0x0f,0x22,0xdf,0x8d,0x10,0x66,0xa7,0x7e,0x96,0xbd,0x5a,0xaf,0xaa,0x43,0xdf,0x10,
    0x7c,0x04,0xe2,0x9d,0x66,0xd7,0xf0,0x02,0x58,0x8a,0x55,0x17,0x16,0xe2,0xe2,0x52,
    0xaf,0xd9,0xf9,0x0d,0x59,0x70,0x86,0x3c,0x05,0xd1,0x52,0xa7,0xf0,0xbf,0x17,0xd0,
    0x23,0x15,0xfe,0x23,0xf2,0x80,0x60,0x6f,0x95,0x89,0x67,0x65,0xc9,0x0e,0xfc,0x16,
    0xd6,0x8a,0x9f,0x25,0x2c,0x0f,0x2d,0xe4,0x51,0xb2,0xa8,0x18,0x3a,0x5d,0x66,0xa0,
    0x9f,0xb0,0x58,0xea,0x78,0x72,0x08,0x6a,0x90,0xb6,0xa4,0xf5,0x08,0x19,0x60,0x4e,
    0x92,0xbd,0xf1,0x05,0x67,0x4f,0x24,0x99,0x69,0x1d,0x0c,0x6d,0xe7,0x74,0x88,0x22,
    0x2d,0x15,0x7a,0xa2,0x37,0xa9,0xa0,0xb0,0x2c,0xfb,0x27,0xe5,0x4f,0xb6,0xcd,0x75,
    0xdc,0x39,0xce,0x6f,0x1f,0xfe,0xcc,0xb5,0xe6,0xda,0xd8,0xee,0x85,0xee,0x2f,0x04,
};
const uint8_t TABLE_ALT[256] = {
    0x26,0x17,0xb9,0xcf,0x1a,0xf5,0x14,0x1e,0x0c,0x35,0xb3,0x66,0xa0,0x17,0xe9,0xe4,
    0x90,0xf6,0xd5,0x35,0xac,0x95,0x49,0x43,0x64,0x0c,0x03,0x75,0x4d,0xda,0xb6,0xdf,
    0x06,0xcf,0x83,0x9e,0x35,0x2c,0x71,0x2a,0xab,0xcc,0x65,0xd4,0x1f,0xb0,0x88,0x3c,
    0xb7,0x87,0x35,0xc0,0x41,0x65,0x9f,0xa0,0xd5,0x8c,0x3e,0x06,0x53,0xdb,0x45,0x64,
    0x09,0x1e,0xc5,0x8d,0x50,0x24,0xe2,0x4a,0x9b,0x99,0x77,0x25,0x43,0xa9,0x1d,0xac,
    0x99,0x31,0x75,0xb5,0x53,0xab,0xad,0x5a,0x42,0x14,0xa1,0x52,0xac,0xec,0x5f,0xf8,
    0x8c,0x78,0x05,0x47,0xea,0xb8,0xde,0x69,0x98,0x2d,0x8f,0x9d,0xfc,0x05,0xea,0xee,
    0x77,0xbb,0xa9,0x31,0x01,0x00,0xea,0xd8,0x9c,0x43,0xb5,0x2f,0x4e,0xb5,0x1b,0xd2,
    0x01,0x4b,0xc4,0xf8,0x76,0x92,0x59,0x4f,0x20,0x52,0xd9,0x7f,0xa9,0x19,0xe9,0x7c,
    0x8d,0x3b,0xec,0xe0,0x60,0x08,0x2e,0xbd,0x27,0x8b,0xb2,0xfc,0x29,0xd8,0x39,0x8a,
    0x4f,0x2f,0x6b,0x04,0x10,0xbd,0xa1,0x04,0xde,0xc0,0xd5,0x0f,0x04,0x86,0xd6,0xd8,
    0xfd,0xb1,0x3c,0x4c,0xd1,0xc4,0xf1,0x5b,0xf5,0x8b,0xe3,0xc4,0x89,0x3c,0x39,0x86,
    0xd2,0x92,0xc9,0xe5,0x2c,0x4f,0xe2,0x2f,0x2d,0xc5,0x35,0x09,0x94,0x47,0x3c,0x04,
    0x40,0x8b,0x57,0x08,0xf6,0x74,0xe9,0xb8,0x36,0x4d,0xc5,0x26,0x13,0x3d,0x75,0xa0,
    0xa8,0x29,0x09,0x8c,0x87,0xf7,0x13,0xaf,0x4c,0x38,0x0b,0x8a,0x7f,0x2c,0x62,0x27,
    0x47,0xaa,0xda,0x07,0x92,0x8d,0xfd,0x1f,0xee,0x48,0x1a,0x53,0x3b,0x98,0x6a,0x72,
};

// ------------------------------------------------------------------ rng
uint64_t rng_s = 0x9e3779b97f4a7c15ull;
uint32_t rnd()
{
    rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17;
    return (uint32_t)(rng_s >> 11);
}
uint32_t rnd(uint32_t n) { return rnd() % n; }

long checks = 0, fails = 0;
void ck(bool ok, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void ck(bool ok, const char* fmt, ...)
{
    checks++;
    if (ok) return;
    if (++fails <= 30) {
        va_list ap; va_start(ap, fmt);
        std::printf("  FAIL ");
        std::vprintf(fmt, ap);
        std::printf("\n");
        va_end(ap);
    }
}

// ------------------------------------------------------------------ board
// The span of SDRAM the module may read: the 128 KB region and, because a
// header can point romstart + romlength past it, the 128 KB after it.
constexpr uint32_t SPAN = 0x40000;

struct Board {
    uint16_t ram[0x8000];
    uint16_t ee[64];
    std::vector<uint8_t> sdram = std::vector<uint8_t>(SPAN);  // region bytes
    uint32_t base = 0x80000;     // word address of the region
    uint16_t dsw = 0xff00;
    bool alt = false;
} B;

// The decrypted view, as MAME's m_mcudata would be after decrypt_rom() — and,
// past 0x20000 where MAME has no region, as the RTL reads it.
std::vector<uint8_t> decrypted()
{
    const uint8_t* t = B.alt ? TABLE_ALT : TABLE_NORMAL;
    std::vector<uint8_t> d(SPAN);
    for (uint32_t i = 0; i < SPAN; i++) d[i] = (uint8_t)(B.sdram[i] + t[(i ^ 1) & 0xff]);
    return d;
}

// ------------------------------------------------------------------ reference
// kaneko_toybox.cpp, mcu_com_w / mcu_run / handle_04_subcommand, GAME_NORMAL.
// Kept as close to the source as C++ allows: the byte views are host casts of
// the word array, exactly as MAME's are, and this file refuses to build on a
// big-endian host. The only addition is `& 0xffff` on RAM byte indices, where
// MAME runs off the end of the share (undefined) and the RTL wraps.
struct Ref {
    uint16_t com[4] = {0, 0, 0, 0};
    bool com_w(int n, uint16_t data, uint16_t mem_mask)
    {
        com[n] = (uint16_t)((com[n] & ~mem_mask) | (data & mem_mask));   // COMBINE_DATA
        for (int i = 0; i < 4; i++) if (com[i] != 0xffff) return false;
        std::memset(com, 0, sizeof com);
        return true;
    }
} REF;

void ref_run(uint16_t* m_mcuram, uint16_t* eeprom, uint16_t dsw, const uint8_t* m_mcudata)
{
    const uint16_t mcu_command = m_mcuram[0x0010 / 2];
    const uint16_t mcu_offset  = m_mcuram[0x0012 / 2] / 2;
    const uint16_t mcu_data    = m_mcuram[0x0014 / 2];
    uint8_t* const bytes = (uint8_t*)m_mcuram;

    switch (mcu_command >> 8) {
    case 0x02:      // uint8_t* nvdat = (uint8_t*)&m_mcuram[mcu_offset];
        for (int i = 0; i < 0x80; i += 2) {
            const uint16_t dat = eeprom[i / 2];
            bytes[(mcu_offset * 2 + i) & 0xffff]     = (dat & 0xff00) >> 8;
            bytes[(mcu_offset * 2 + i + 1) & 0xffff] = (dat & 0x00ff);
        }
        break;
    case 0x42:
        for (int i = 0; i < 0x80; i += 2)
            eeprom[i / 2] = (uint16_t)((bytes[(mcu_offset * 2 + i) & 0xffff] << 8) |
                                        bytes[(mcu_offset * 2 + i + 1) & 0xffff]);
        break;
    case 0x43:      // Bonk only
        break;
    case 0x03:
        m_mcuram[mcu_offset] = dsw;
        break;
    case 0x04: {
        const uint8_t mcu_subcmd = (uint8_t)mcu_data;
        const uint8_t* const src = &m_mcudata[0x10000];
        const int offs = (mcu_subcmd & 0x3f) * 8;
        const uint16_t romstart  = src[offs + 2] | (src[offs + 3] << 8);
        const uint16_t romlength = src[offs + 4] | (src[offs + 5] << 8);
        const uint16_t ramdest   = m_mcuram[0x0012 / 2];
        uint8_t* const dst = bytes;          // little_endian_cast<uint8_t>(mcu_ram)
        for (int x = 0; x < romlength; x++)
            dst[(ramdest + x) & 0xffff] = src[romstart + x];
        break;
    }
    default:
        break;
    }
}

// ------------------------------------------------------------------ DUT
Vkaneko_toybox* dut;
long cyc = 0;

struct Servant {
    int  cnt = -1;       // cycles left before the ack; -1 idle
    bool acked = false;  // acked last cycle: the request must drop now
    uint32_t addr = 0; uint16_t din = 0; uint8_t be = 0; bool we = false;
};
Servant rs, os_;
uint16_t ee_q = 0;
long ee_dirty = 0, ram_ops = 0, rom_ops = 0;

// One clock. Inputs for this cycle are decided from the registered outputs
// as they stand after the previous edge, the way a synchronous servant sees
// them; the board's EEPROM array samples on the edge.
void tick()
{
    dut->ram_ack = 0;
    dut->rom_ack = 0;
    dut->eval();

    // ---- RAM servant
    if (rs.acked) {
        ck(!dut->ram_req, "cycle %ld: ram_req still high the cycle after its ack", cyc);
        rs.acked = false;
    } else if (dut->ram_req) {
        if (rs.cnt < 0) {
            rs.cnt = (int)rnd(4);
            rs.addr = dut->ram_addr; rs.din = dut->ram_din; rs.be = dut->ram_be; rs.we = dut->ram_we;
            ck(rs.we ? rs.be != 0 : true, "cycle %ld: RAM write with no byte enabled", cyc);
        } else {
            ck(rs.addr == dut->ram_addr && rs.we == dut->ram_we &&
               (!rs.we || (rs.din == dut->ram_din && rs.be == dut->ram_be)),
               "cycle %ld: RAM request changed before its ack", cyc);
        }
        if (rs.cnt-- == 0) {
            const uint32_t a = rs.addr & 0x7fff;
            if (rs.we) {
                uint16_t m = (uint16_t)(((rs.be & 2) ? 0xff00 : 0) | ((rs.be & 1) ? 0x00ff : 0));
                B.ram[a] = (uint16_t)((B.ram[a] & ~m) | (rs.din & m));
            } else {
                dut->ram_dout = B.ram[a];
            }
            dut->ram_ack = 1;
            rs.acked = true;
            rs.cnt = -1;
            ram_ops++;
        }
    }

    // ---- ROM servant: 64-bit lines, word k at [16k +: 16], SDRAM word w =
    // {byte[2w+1], byte[2w]}, so the line is the region's bytes little-endian.
    if (os_.acked) {
        ck(!dut->rom_req, "cycle %ld: rom_req still high the cycle after its ack", cyc);
        os_.acked = false;
    } else if (dut->rom_req) {
        if (os_.cnt < 0) {
            os_.cnt = 2 + (int)rnd(10);
            os_.addr = dut->rom_addr;
            ck((os_.addr & 3) == 0, "cycle %ld: rom_addr %07x not line aligned", cyc, os_.addr);
        } else {
            ck(os_.addr == dut->rom_addr, "cycle %ld: rom_addr changed before its ack", cyc);
        }
        if (os_.cnt-- == 0) {
            const int64_t byte = ((int64_t)os_.addr - (int64_t)B.base) * 2;
            uint64_t q = 0;
            ck(byte >= 0 && byte + 8 <= (int64_t)SPAN, "cycle %ld: ROM read outside the region: %07x",
               cyc, os_.addr);
            if (byte >= 0 && byte + 8 <= (int64_t)SPAN)
                for (int i = 7; i >= 0; i--) q = (q << 8) | B.sdram[byte + i];
            dut->rom_dout = q;
            dut->rom_ack = 1;
            os_.acked = true;
            os_.cnt = -1;
            rom_ops++;
        }
    }

    dut->ee_dout = ee_q;
    dut->dsw = B.dsw;
    dut->eval();

    if (!dut->busy)
        ck(!dut->ram_req && !dut->rom_req && !dut->ee_we,
           "cycle %ld: memory activity while not busy", cyc);

    // ---- the edge
    const uint8_t ea = dut->ee_addr & 63;
    const bool    ew = dut->ee_we;
    const uint16_t ed = dut->ee_din;
    if (dut->ee_dirty_set) ee_dirty++;
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    ee_q = B.ee[ea];
    if (ew) B.ee[ea] = ed;
    cyc++;
}

void reset()
{
    dut->rst = 1;
    dut->com_we = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0;
    tick();
    REF = Ref();
    rs = Servant(); os_ = Servant();
}

long busy_max = 0, last_run = 0;   // clocks busy: longest so far, last command

// One 68000 write to mcu_com<sel>. Returns whether it ran a command. The
// reference decides whether it should; `busy` must agree IN THAT CYCLE.
bool com_write(int sel, uint16_t data, uint8_t be)
{
    const uint16_t mask = (uint16_t)(((be & 2) ? 0xff00 : 0) | ((be & 1) ? 0x00ff : 0));
    const bool fires = REF.com_w(sel, data, mask);
    dut->com_we = 1; dut->com_sel = (uint8_t)sel; dut->com_din = data; dut->com_be = be;
    dut->eval();
    ck(dut->busy == fires, "com%d <- %04x be %d: busy=%d in the write cycle, want %d",
       sel, data, be, dut->busy, fires);
    tick();
    dut->com_we = 0;
    if (!fires) {
        ck(!dut->busy, "busy after a non-triggering write");
        return false;
    }
    long n = 1;
    while (dut->busy && n < 4000000) { tick(); n++; }
    ck(!dut->busy, "command never finished");
    if (n > busy_max) busy_max = n;
    last_run = n;
    return true;
}

// The four 0xFFFF writes in a random order and in random shapes — two byte
// writes, or a wrong value first — so the trigger is reached only at the last.
void trigger()
{
    int order[4] = {0, 1, 2, 3};
    for (int i = 3; i > 0; i--) { int j = (int)rnd(i + 1); std::swap(order[i], order[j]); }
    for (int k = 0; k < 4; k++) {
        const int sel = order[k];
        switch (rnd(4)) {
        case 0:  com_write(sel, (uint16_t)rnd(0xffff), 3); com_write(sel, 0xffff, 3); break;
        case 1:  com_write(sel, 0xffff, 1); com_write(sel, 0xffff, 2); break;
        case 2:  com_write(sel, 0x00ff, 3); com_write(sel, 0xffff, 2); break;
        default: com_write(sel, 0xffff, 3); break;
        }
        for (int i = (int)rnd(3); i > 0; i--) tick();
    }
}

// Issue one command from the current RAM/EEPROM and compare everything.
uint16_t ram_ref[0x8000], ee_ref[64];
void run_and_compare(const char* what, const std::vector<uint8_t>& dec)
{
    std::memcpy(ram_ref, B.ram, sizeof ram_ref);
    std::memcpy(ee_ref, B.ee, sizeof ee_ref);
    const long dirty0 = ee_dirty;
    const bool save = (B.ram[8] >> 8) == 0x42;
    trigger();
    ref_run(ram_ref, ee_ref, B.dsw, dec.data());
    int bad = 0, first = -1;
    for (int i = 0; i < 0x8000; i++) if (B.ram[i] != ram_ref[i]) { if (first < 0) first = i; bad++; }
    ck(bad == 0, "%s: %d RAM words differ, first at word %04x: rtl %04x ref %04x",
       what, bad, first, first < 0 ? 0 : B.ram[first], first < 0 ? 0 : ram_ref[first]);
    bad = 0; first = -1;
    for (int i = 0; i < 64; i++) if (B.ee[i] != ee_ref[i]) { if (first < 0) first = i; bad++; }
    ck(bad == 0, "%s: %d EEPROM words differ, first %d: rtl %04x ref %04x",
       what, bad, first, first < 0 ? 0 : B.ee[first], first < 0 ? 0 : ee_ref[first]);
    ck(ee_dirty - dirty0 == (save ? 1 : 0), "%s: ee_dirty_set pulsed %ld times", what, ee_dirty - dirty0);
}

void set_cmd(uint16_t cmd, uint16_t off, uint16_t data)
{
    B.ram[8] = cmd; B.ram[9] = off; B.ram[10] = data;
}

void randomise_ram()
{
    for (auto& w : B.ram) w = (uint16_t)rnd();
}

// ------------------------------------------------------------------ layer 1
void plant_header(int sub, uint16_t start, uint16_t len)
{
    const uint8_t* t = B.alt ? TABLE_ALT : TABLE_NORMAL;
    const uint32_t e = 0x10000 + sub * 8;
    const uint8_t want[4] = {(uint8_t)start, (uint8_t)(start >> 8), (uint8_t)len, (uint8_t)(len >> 8)};
    for (int k = 0; k < 4; k++) {
        const uint32_t i = e + 2 + k;
        B.sdram[i] = (uint8_t)(want[k] - t[(i ^ 1) & 0xff]);   // so it decrypts to want
    }
}

uint16_t pick_len()
{
    switch (rnd(8)) {
    case 0:  return 0;
    case 1:  return (uint16_t)(1 + rnd(3));
    case 2:
    case 3:  return (uint16_t)rnd(64);
    case 4:
    case 5:  return (uint16_t)rnd(0x400);
    case 6:  return (uint16_t)rnd(0x2000);
    default: return (uint16_t)(0x8000 + rnd(0x8000));   // long; wraps RAM
    }
}

void layer_synthetic()
{
    const long f0 = fails;
    long cmds = 0;
    for (int alt = 0; alt < 2; alt++) {
        B.alt = alt;
        dut->table_alt = alt;
        // A region base other than the Pocket's, now and then, line aligned.
        B.base = alt ? 0x80000 : (0x10000 + (rnd(0x100000) & ~3u));
        dut->rom_base = B.base;
        for (auto& b : B.sdram) b = (uint8_t)rnd();
        for (int s = 0; s < 64; s++) plant_header(s, (uint16_t)rnd(), pick_len());
        const std::vector<uint8_t> dec = decrypted();
        reset();
        char what[64];

        for (int s = 0; s < 64; s++) {
            for (int rep = 0; rep < 3; rep++) {
                randomise_ram();
                uint16_t dest = (uint16_t)rnd();
                if (rep == 1) dest = (uint16_t)(0xfff0 + rnd(16));    // wraps
                set_cmd((uint16_t)(0x0400 | rnd(256)), dest, (uint16_t)((rnd(0x400) << 6) | s));
                std::snprintf(what, sizeof what, "table %d sub %02x dest %04x", alt, s, dest);
                run_and_compare(what, dec); cmds++;
            }
        }
        const uint8_t others[] = {0x02, 0x42, 0x03, 0x43, 0x00, 0x01, 0x05, 0x44, 0x82, 0xc2, 0xff};
        for (uint8_t c : others) {
            for (int rep = 0; rep < 12; rep++) {
                randomise_ram();
                for (auto& w : B.ee) w = (uint16_t)rnd();
                B.dsw = (uint16_t)rnd();
                uint16_t off = (uint16_t)rnd();
                if (rep == 0) off = (uint16_t)(0xffc0 + rnd(64));          // wraps
                set_cmd((uint16_t)((c << 8) | rnd(256)), off, (uint16_t)rnd());
                std::snprintf(what, sizeof what, "table %d cmd %02x off %04x", alt, c, off);
                run_and_compare(what, dec); cmds++;
            }
        }
        dut->com_we = 0;
    }
    std::printf("kaneko_toybox: synthetic  %ld commands, longest run %ld clocks, %s\n",
                cmds, busy_max, fails == f0 ? "ok" : "FAILED");
}

// ------------------------------------------------------------------ layer 2
struct Set { const char* name; bool alt; };
const Set SETS[] = {{"gtmr", false}, {"gtmrusa", true}, {"gtmr2u", true}};

bool load(const std::string& path, std::vector<uint8_t>& out)
{
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END); const long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    out.resize(n);
    const bool ok = std::fread(out.data(), 1, n, f) == (size_t)n;
    std::fclose(f);
    return ok;
}

bool use_rom(const Set& s, const std::string& root)
{
    std::vector<uint8_t> rom;
    if (!load(root + "/build/roms/" + s.name + "_mcudata.bin", rom) || rom.size() != 0x20000)
        return false;
    B.alt = s.alt;
    dut->table_alt = s.alt;
    B.base = 0x80000;
    dut->rom_base = B.base;
    for (auto& b : B.sdram) b = (uint8_t)rnd();   // what follows the region
    std::memcpy(B.sdram.data(), rom.data(), rom.size());
    return true;
}

void layer_real_rom(const std::string& root)
{
    for (const Set& s : SETS) {
        if (!use_rom(s, root)) {
            std::printf("kaneko_toybox: %-8s data ROM SKIP (no build/roms/%s_mcudata.bin — "
                        "run sim/mcu/extract_mcudata.py)\n", s.name, s.name);
            continue;
        }
        const long f0 = fails;
        const std::vector<uint8_t> dec = decrypted();
        std::vector<uint8_t> mame;
        const std::string mp = root + "/build/mcu_mame/" + s.name + "/mcudata_dec.bin";
        bool vs_mame = load(mp, mame);
        if (vs_mame) {
            long bad = 0;
            for (uint32_t i = 0; i < 0x20000; i++) bad += dec[i] != mame[i];
            ck(mame.size() == 0x20000 && bad == 0,
               "%s: decrypted region differs from MAME's in %ld bytes", s.name, bad);
        }
        reset();
        long cmds = 0, bytes = 0;
        char what[64];
        for (int sub = 0; sub < 64; sub++) {
            const uint32_t e = 0x10000 + sub * 8;
            bytes += dec[e + 4] | (dec[e + 5] << 8);
            for (int rep = 0; rep < 4; rep++) {
                randomise_ram();
                const uint16_t dest = (uint16_t)rnd();
                set_cmd((uint16_t)(0x0400 | rnd(256)), dest, (uint16_t)((rnd(0x400) << 6) | sub));
                std::snprintf(what, sizeof what, "%s sub %02x dest %04x", s.name, sub, dest);
                run_and_compare(what, dec); cmds++;
            }
        }
        std::printf("kaneko_toybox: %-8s data ROM  %ld commands (64 subcommands, %ld table bytes), "
                    "decryption %s, %s\n", s.name, cmds, bytes,
                    vs_mame ? "= MAME's region" : "not checked (no capture)",
                    fails == f0 ? "ok" : "FAILED");
    }
}

// ------------------------------------------------------------------ layer 3
struct Reader {
    const std::vector<uint8_t>& b; size_t p = 0;
    explicit Reader(const std::vector<uint8_t>& v) : b(v) {}
    bool more() const { return p < b.size(); }
    uint32_t u(int n) { uint32_t v = 0; for (int i = 0; i < n; i++) v |= (uint32_t)b[p++] << (8 * i); return v; }
};

void apply_diff(Reader& r, uint16_t* ram, uint16_t* ee)
{
    const uint32_t n = r.u(4);
    for (uint32_t i = 0; i < n; i++) { const uint32_t w = r.u(2); ram[w & 0x7fff] = (uint16_t)r.u(2); }
    const uint32_t m = r.u(1);
    for (uint32_t i = 0; i < m; i++) { const uint32_t w = r.u(1); ee[w & 63] = (uint16_t)r.u(2); }
}

void layer_mame(const std::string& root)
{
    for (const Set& s : SETS) {
        std::vector<uint8_t> cap;
        const std::string cp = root + "/build/mcu_mame/" + s.name + "/cap.bin";
        if (!load(cp, cap)) {
            std::printf("kaneko_toybox: %-8s MAME replay SKIP (no build/mcu_mame/%s/cap.bin — "
                        "run sim/mcu/capture.sh)\n", s.name, s.name);
            continue;
        }
        if (!use_rom(s, root)) {
            std::printf("kaneko_toybox: %-8s MAME replay SKIP (no data ROM)\n", s.name);
            continue;
        }
        const long f0 = fails;
        const std::vector<uint8_t> dec = decrypted();
        reset();

        static uint16_t m_ram[0x8000], m_ee[64];    // MAME's state, from the diffs
        std::memset(m_ram, 0, sizeof m_ram); std::memset(m_ee, 0, sizeof m_ee);
        std::map<std::string, int> kinds;
        long cmds = 0, writes = 0, ref_bad = 0, rtl_bad = 0, run_max = 0, ee_max = 0;
        bool armed = false, ran = false;
        uint16_t cmd = 0, off = 0, data = 0;
        Reader r(cap);
        bool ended = false;
        while (r.more() && !ended) {
            const char t = (char)r.u(1);
            if (t == 'W') {
                const int sel = (int)r.u(1);
                const uint16_t d = (uint16_t)r.u(2), mask = (uint16_t)r.u(2);
                const uint8_t be = (uint8_t)(((mask & 0xff00) ? 2 : 0) | ((mask & 0x00ff) ? 1 : 0));
                const long dirty0 = ee_dirty;
                const bool fired = com_write(sel, d, be);
                ck(fired == armed, "%s: com write %ld fired=%d, MAME's capture says %d",
                   s.name, writes, fired, armed);
                ck(ee_dirty - dirty0 == ((fired && (cmd >> 8) == 0x42) ? 1 : 0),
                   "%s: command %04x: ee_dirty_set pulsed %ld times", s.name, cmd, ee_dirty - dirty0);
                const bool eecmd = (cmd >> 8) == 0x42 || (cmd >> 8) == 0x02;
                if (fired && !eecmd && last_run > run_max) run_max = last_run;
                if (fired && eecmd && last_run > ee_max)   ee_max = last_run;
                if (fired) {
                    // The reference on MAME's before-state, for the A record.
                    ref_run(ram_ref, ee_ref, B.dsw, dec.data());
                    ran = true;
                }
                armed = false;
                writes++;
            } else if (t == 'U') {
                r.u(4); r.u(2); r.u(2);          // not a com register; ignored as MAME does
            } else if (t == 'B') {
                r.u(4);
                B.dsw = (uint16_t)r.u(2);
                apply_diff(r, m_ram, m_ee);
                std::memcpy(B.ram, m_ram, sizeof B.ram);
                std::memcpy(B.ee, m_ee, sizeof B.ee);
                std::memcpy(ram_ref, m_ram, sizeof ram_ref);
                std::memcpy(ee_ref, m_ee, sizeof ee_ref);
                cmd = m_ram[8]; off = m_ram[9]; data = m_ram[10];
                armed = true;
            } else if (t == 'A') {
                apply_diff(r, m_ram, m_ee);
                ck(ran, "%s: an after-state with no command run", s.name);
                ran = false;
                cmds++;
                char k[16];
                if ((cmd >> 8) == 4) std::snprintf(k, sizeof k, "04/%02x", data & 0x3f);
                else                 std::snprintf(k, sizeof k, "%02x", cmd >> 8);
                kinds[k]++;
                int bad = 0, rbad = 0, first = -1;
                for (int i = 0; i < 0x8000; i++) {
                    if (B.ram[i] != m_ram[i]) { if (first < 0) first = i; bad++; }
                    rbad += ram_ref[i] != m_ram[i];
                }
                for (int i = 0; i < 64; i++) { bad += B.ee[i] != m_ee[i]; rbad += ee_ref[i] != m_ee[i]; }
                ck(bad == 0, "%s: command %04x %04x %04x: RTL differs from MAME in %d words "
                   "(first RAM word %04x: rtl %04x mame %04x)", s.name, cmd, off, data, bad,
                   first, first < 0 ? 0 : B.ram[first], first < 0 ? 0 : m_ram[first]);
                ck(rbad == 0, "%s: command %04x %04x %04x: reference differs from MAME in %d words",
                   s.name, cmd, off, data, rbad);
                rtl_bad += bad != 0; ref_bad += rbad != 0;
            } else if (t == 'E') {
                ended = true;
            } else {
                ck(false, "%s: bad record '%c' in capture", s.name, t);
                ended = true;
            }
        }
        ck(ended, "%s: capture has no end record", s.name);
        // 04 is summarised: one line per subcommand would be 64 entries.
        std::string ks;
        int subs = 0, runs04 = 0;
        for (auto& kv : kinds) {
            if (kv.first.compare(0, 3, "04/") == 0) { subs++; runs04 += kv.second; continue; }
            ks += " " + kv.first + "x" + std::to_string(kv.second);
        }
        ks += " 04x" + std::to_string(runs04) + " (" + std::to_string(subs) + " subcommands)";
        std::printf("kaneko_toybox: %-8s MAME replay  %ld commands from %ld com writes, "
                    "rtl!=mame %ld, ref!=mame %ld, longest busy %ld clocks (02/42: %ld), %s\n"
                    "                         %s\n",
                    s.name, cmds, writes, rtl_bad, ref_bad, run_max, ee_max,
                    fails == f0 ? "ok" : "FAILED", ks.c_str());
    }
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const std::string root = (argc > 1 && argv[1][0] != '+') ? argv[1] : ".";
    dut = new Vkaneko_toybox;
    dut->clk = 0; dut->rst = 1; dut->com_we = 0; dut->dsw = 0;
    dut->eval();

    layer_synthetic();
    layer_real_rom(root);
    layer_mame(root);

    std::printf("kaneko_toybox: checks=%ld fails=%ld ram_ops=%ld rom_lines=%ld\n",
                checks, fails, ram_ops, rom_ops);
    delete dut;
    return fails ? 1 : 0;
}
