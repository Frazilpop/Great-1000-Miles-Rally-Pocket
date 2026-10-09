// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the TOYBOX MCU (TBSOP01/TBSOP02) of the gtmr board
//
// MAME's simulation of it, as RTL.
//
// The MCU is a NEC uPD78324 with 32 KB of internal ROM that has never been
// dumped. Nobody knows what it really does; what is known is what MAME's
// high-level simulation does, and that is enough for Great 1000 Miles Rally
// and its sequels to run. So kaneko_toybox.cpp IS the specification here, and
// this module is that file as hardware, behaviour for behaviour — including
// the parts that are only true because MAME runs on a little-endian host.
//
// The two 256-byte decryption tables at the bottom of this file are data from
// MAME's kaneko_toybox.cpp, BSD-3-Clause, copyright-holders David Haywood,
// Luca Elia, Sebastien Volpe. Transcribed mechanically from that source.
//
// THE PROTOCOL
//
// The 68000 writes 0xFFFF to four registers, 2a0000/2b0000/2c0000/2d0000. Each
// write is COMBINE_DATA'd (UDS/LDS respected) into its register, and the write
// that leaves all four at 0xFFFF clears them and runs the command at once. In
// MAME that run is instantaneous: it happens inside the write handler, so the
// 68000's next instruction already sees the result. Here it takes thousands of
// clocks, so `busy` rises COMBINATIONALLY with the triggering strobe and holds
// the bus (the board withholds DTACK) until the command is done. Registered,
// it would be a cycle late, and the board could finish the write cycle in that
// cycle and let the 68000 read stale RAM.
//
// The command block sits in MCU-shared RAM, read once at the start:
//
//     200010  command      high byte selects
//     200012  offset       a BYTE offset; halved for 02/42/03, used whole for 04
//     200014  data         04 only: subcommand, low six bits
//
//     02  EEPROM -> RAM    64 words to RAM word offset/2
//     42  RAM -> EEPROM    64 words from RAM word offset/2, then ee_dirty_set
//     43  restore defaults: Bonk only in MAME; on gtmr it does nothing
//     03  DSW1 -> RAM word offset/2
//     04  copy a block out of the (encrypted) data ROM, see below
//     anything else: nothing
//
// 02 AND 42 SWAP THE BYTES — BECAUSE MAME'S HOST IS LITTLE-ENDIAN
//
// mcu_run walks the RAM as `(uint8_t*)&m_mcuram[offset]` and puts the
// EEPROM word's HIGH byte at nvdat[0]. On a little-endian host nvdat[0] is
// the LOW byte of the 68000-visible word, so RAM word k = EEPROM word k with
// its bytes swapped, both ways. The game only ever reads back what it wrote,
// so either order would boot; this one is the order MAME's nvram files and
// RAM snapshots are in, which is what the core is checked against.
//
// 04: THE DATA ROM COPY
//
// mcudata is 128 KB, ROM_LOAD16_WORD_SWAP then decrypted in place by
//
//     m_mcudata[i] += table[(i ^ 1) & 0xff]
//
// The SDRAM holds it after the swap and BEFORE the add, so
// the add is done here on every byte as it is read, with SDRAM word w =
// {byte[2w+1], byte[2w]} — byte i of the region is byte (i & 7) of 64-bit line
// i >> 3, counting from the low end. Subcommand s names an eight-byte entry
// at region 0x10000 + s*8, little-endian:
//
//     +2 romstart   +4 romlength      (+0 and +6 unused outside Bonk)
//
// and the copy is
//
//     little_endian_cast<uint8_t>(mcuram)[ramdest + x] = src[romstart + x]
//
// with src = region + 0x10000 and ramdest = the RAW offset word, not halved.
// little_endian_cast byte b is the LOW byte of word b >> 1 when b is even —
// 68000 byte address b ^ 1. So a copy that starts on an even b fills words
// low byte first, and is written here a whole word at a time (two source
// bytes per RAM write) whenever both halves of the word are in the copy.
//
// WHERE MAME IS UNDEFINED, THIS WRAPS
//
// MAME indexes past the end of the 64 KB share when ramdest + romlength or
// offset/2 + 64 runs off the end, and past the 128 KB region when romstart +
// romlength > 0x10000. Both are undefined behaviour there and no game does
// either. Here RAM addresses wrap within the 64 KB, and ROM reads simply carry
// on into whatever SDRAM holds after the region (decrypted by the same rule).
//
// COST
//
// One 512 x 8 ROM (the two tables; one M10K), a 64-bit line buffer so that a
// copy reads each SDRAM line once, and a few counters: 239 ALMs and 319
// registers in Quartus 21.1 Analysis & Synthesis for 5CEBA4F23C8.
//
// Time, measured in sim/mcu with servants that answer in 1-4 (RAM) and 3-12
// (SDRAM) clocks: about five clocks a copied byte. The games only ever copy
// 18, 33 or 39 bytes (subcommands 3d/3e/3f — the other 61 table entries are
// empty), so the longest real command holds the 68000 for ~240 clocks (5 us)
// and 02/42 for ~320. All five of them come at boot; none during play.
module kaneko_toybox #(
    parameter int unsigned SDR_AW = 25
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        table_alt,        // 1: gtmre/gtmrusa/gtmr2/gtmr2u

    // 68000 side: mcu_com0..3 at 2a0000/2b0000/2c0000/2d0000
    input  wire        com_we,           // one cycle per 68000 write
    input  wire [1:0]  com_sel,
    input  wire [15:0] com_din,
    input  wire [1:0]  com_be,           // {UDS, LDS}
    output wire        busy,

    // MCU-shared RAM, granted by the board while busy
    output logic        ram_req,
    output logic        ram_we,
    output logic [14:0] ram_addr,        // word address in the 64 KB
    output logic [15:0] ram_din,
    output logic [1:0]  ram_be,          // [1] = upper byte = 68000 even address
    input  wire         ram_ack,
    input  wire  [15:0] ram_dout,

    // mcudata in SDRAM, 64-bit line reads
    input  wire  [SDR_AW:1] rom_base,    // word address of the region
    output logic            rom_req,
    output logic [SDR_AW:1] rom_addr,
    input  wire             rom_ack,
    input  wire  [63:0]     rom_dout,

    // 93C46 contents, 64 x 16, synchronous read with one cycle of latency
    output logic        ee_we,
    output wire  [5:0]  ee_addr,
    output logic [15:0] ee_din,
    input  wire  [15:0] ee_dout,
    output logic        ee_dirty_set,

    input  wire  [15:0] dsw
);

    // ------------------------------------------------------------ mcu_com_w
    //
    // COMBINE_DATA into the addressed register, then compare all four — the
    // comparison uses the value being written, so it is made on the next
    // state of the registers, not the current one.
    logic [15:0] com [4];
    logic [15:0] com_nx [4];
    wire  [15:0] com_mask = {{8{com_be[1]}}, {8{com_be[0]}}};

    always_comb begin
        for (int i = 0; i < 4; i++)
            com_nx[i] = (com_we && com_sel == 2'(i))
                      ? ((com[i] & ~com_mask) | (com_din & com_mask)) : com[i];
    end

    wire all_ff = (com_nx[0] == 16'hffff) && (com_nx[1] == 16'hffff) &&
                  (com_nx[2] == 16'hffff) && (com_nx[3] == 16'hffff);

    // The 68000 is held for the whole run, so no write can arrive while busy.
    // If one did, it would still be combined (and cleared on all-0xFFFF) as
    // MAME does, but could not start a second run on top of the first.
    typedef enum logic [3:0] {
        S_IDLE,
        S_PRM_REQ, S_PRM_WAIT,           // read 200010/12/14
        S_DISP,
        S_EE_ADR, S_EE_DAT,              // 02: EEPROM word k -> RAM
        S_RD_REQ, S_RD_WAIT, S_EE_WR,    // 42: RAM -> EEPROM word k
        S_FETCH, S_LINE, S_DEC,          // 04: one decrypted ROM byte
        S_COPY,
        S_WR_WAIT                        // any RAM write
    } state_t;
    state_t st;

    wire start = all_ff && com_we && (st == S_IDLE);
    assign busy = start || (st != S_IDLE);

    // ------------------------------------------------------------ registers
    logic [7:0]  cmd;          // command high byte
    logic [15:0] off;          // raw offset word; the byte destination for 04
    logic [5:0]  sub;          // subcommand & 0x3f
    logic [5:0]  k;            // word counter for 02/42, header step for 04
    logic [1:0]  pk;           // parameter word being read
    logic        copying;      // 04: past the header, into the copy
    logic [15:0] rem;          // 04: bytes still to copy
    logic [17:0] src;          // 04: region byte index (up to 0x2fffe)
    logic [7:0]  lo;           // 04: low byte waiting for its high half
    logic        have_lo;

    // The SDRAM line last read. Cleared at each command, although the ROM
    // cannot change underneath it — one bit is cheaper than an argument about
    // whether the loader can run while the 68000 is held.
    logic [63:0] line;
    logic [14:0] line_tag;     // src[17:3]
    logic        line_ok;
    wire         hit = line_ok && (line_tag == src[17:3]);

    // ROM-byte decryption. The table is addressed by the byte's region index,
    // XOR 1 — the index MAME used in the WORD_SWAPped array — and read one
    // clock after src settles, which S_FETCH always provides.
    logic [7:0] dk;
    wire  [7:0] raw = line[{src[2:0], 3'b000} +: 8];
    wire  [7:0] dec = raw + dk;

    // The EEPROM is addressed straight from the word counter: k is stable for
    // the whole of each read (S_EE_ADR, data in S_EE_DAT) and each write
    // (S_EE_WR), which is all the 1-cycle-latency array needs.
    assign ee_addr = k;

    wire [14:0] woff = off[15:1] + 15'(k);   // 02/42/03: word offset/2 + k

    always_ff @(posedge clk) begin
        ee_we        <= 1'b0;
        ee_dirty_set <= 1'b0;

        for (int i = 0; i < 4; i++) com[i] <= com_nx[i];
        if (com_we && all_ff)
            for (int i = 0; i < 4; i++) com[i] <= 16'h0000;

        case (st)
        S_IDLE: if (start) begin
            pk      <= 2'd0;
            line_ok <= 1'b0;
            st      <= S_PRM_REQ;
        end

        // -------------------------------------------- the command block
        S_PRM_REQ: begin
            ram_req  <= 1'b1;
            ram_we   <= 1'b0;
            ram_addr <= 15'h0008 + 15'(pk);
            st       <= S_PRM_WAIT;
        end
        S_PRM_WAIT: if (ram_ack) begin
            ram_req <= 1'b0;
            case (pk)
                2'd0:    cmd <= ram_dout[15:8];
                2'd1:    off <= ram_dout;
                default: sub <= ram_dout[5:0];
            endcase
            pk <= pk + 2'd1;
            st <= (pk == 2'd2) ? S_DISP : S_PRM_REQ;
        end

        S_DISP: begin
            k <= 6'd0;
            case (cmd)
            8'h02: st <= S_EE_ADR;
            8'h42: st <= S_RD_REQ;
            8'h03: begin
                ram_req  <= 1'b1;
                ram_we   <= 1'b1;
                ram_addr <= off[15:1];
                ram_din  <= dsw;
                ram_be   <= 2'b11;
                st       <= S_WR_WAIT;
            end
            8'h04: begin
                // Header first: length (+4, +5), then start (+2, +3). The
                // order is free, and ending on the start lets its last byte go
                // straight into src.
                copying <= 1'b0;
                have_lo <= 1'b0;
                src     <= {2'b01, 7'd0, sub, 3'd4};
                st      <= S_FETCH;
            end
            default: st <= S_IDLE;           // 43 and the unknowns: nothing
            endcase
        end

        // -------------------------------------------- 02: EEPROM -> RAM
        S_EE_ADR: st <= S_EE_DAT;
        S_EE_DAT: begin
            ram_req  <= 1'b1;
            ram_we   <= 1'b1;
            ram_addr <= woff;
            ram_din  <= {ee_dout[7:0], ee_dout[15:8]};
            ram_be   <= 2'b11;
            st       <= S_WR_WAIT;
        end

        // -------------------------------------------- 42: RAM -> EEPROM
        S_RD_REQ: begin
            ram_req  <= 1'b1;
            ram_we   <= 1'b0;
            ram_addr <= woff;
            st       <= S_RD_WAIT;
        end
        S_RD_WAIT: if (ram_ack) begin
            ram_req <= 1'b0;
            ee_din  <= {ram_dout[7:0], ram_dout[15:8]};
            ee_we   <= 1'b1;
            // With the last word, so the pulse lands while busy is still
            // high: a board that samples it alongside busy cannot miss it.
            ee_dirty_set <= (k == 6'd63);
            st      <= S_EE_WR;
        end
        S_EE_WR: begin                       // ee_we is high in this cycle
            k  <= k + 6'd1;
            st <= (k == 6'd63) ? S_IDLE : S_RD_REQ;
        end

        // -------------------------------------------- 04: one ROM byte
        S_FETCH: if (hit)
            st <= S_DEC;
        else begin
            rom_req  <= 1'b1;
            rom_addr <= rom_base + SDR_AW'({src[17:3], 2'b00});
            st       <= S_LINE;
        end
        S_LINE: if (rom_ack) begin
            rom_req  <= 1'b0;
            line     <= rom_dout;
            line_tag <= src[17:3];
            line_ok  <= 1'b1;
            st       <= S_DEC;               // dk is already valid: src held
        end

        S_DEC: if (!copying) begin
            st <= S_FETCH;
            k  <= k + 6'd1;
            case (k[1:0])
            2'd0: begin rem[7:0]  <= dec; src[2:0] <= 3'd5; end
            2'd1: begin rem[15:8] <= dec; src[2:0] <= 3'd2; end
            2'd2: begin lo        <= dec; src[2:0] <= 3'd3; end
            default: begin
                src     <= 18'h10000 + 18'({dec, lo});
                copying <= 1'b1;
                st      <= S_COPY;
            end
            endcase
        end else begin
            src <= src + 18'd1;
            off <= off + 16'd1;
            rem <= rem - 16'd1;
            if (!off[0] && rem != 16'd1) begin
                // Low half of a word whose high half is also in the copy:
                // hold it and write the word once.
                lo      <= dec;
                have_lo <= 1'b1;
                st      <= S_FETCH;
            end else begin
                have_lo  <= 1'b0;
                ram_req  <= 1'b1;
                ram_we   <= 1'b1;
                ram_addr <= off[15:1];
                ram_din  <= have_lo ? {dec, lo} : {dec, dec};
                ram_be   <= have_lo ? 2'b11 : (off[0] ? 2'b10 : 2'b01);
                st       <= S_WR_WAIT;
            end
        end

        S_COPY: st <= (rem == 16'd0) ? S_IDLE : S_FETCH;

        // -------------------------------------------- any RAM write
        S_WR_WAIT: if (ram_ack) begin
            ram_req <= 1'b0;
            case (cmd)
            8'h02: begin
                k  <= k + 6'd1;
                st <= (k == 6'd63) ? S_IDLE : S_EE_ADR;
            end
            8'h04:   st <= S_COPY;
            default: st <= S_IDLE;           // 03
            endcase
        end

        default: st <= S_IDLE;
        endcase

        if (rst) begin
            st           <= S_IDLE;
            ram_req      <= 1'b0;
            rom_req      <= 1'b0;
            ee_we        <= 1'b0;
            ee_dirty_set <= 1'b0;
            line_ok      <= 1'b0;
            for (int i = 0; i < 4; i++) com[i] <= 16'h0000;
        end
    end

    // ------------------------------------------------------------ the tables
    //
    // decryption_table (gtmr) at 0x000, decryption_table_alt (gtmre onward)
    // at 0x100. A registered case with no reset, so Quartus makes it a ROM in
    // one M10K rather than 512 x 8 bits of LUT logic.
    always_ff @(posedge clk) begin
        case ({table_alt, src[7:0] ^ 8'h01})
            9'h000: dk <= 8'h7b; 9'h001: dk <= 8'h82; 9'h002: dk <= 8'hf0; 9'h003: dk <= 8'hbc; 9'h004: dk <= 8'h7f; 9'h005: dk <= 8'h1d; 9'h006: dk <= 8'ha2; 9'h007: dk <= 8'hc5;
            9'h008: dk <= 8'h2a; 9'h009: dk <= 8'hfa; 9'h00a: dk <= 8'h55; 9'h00b: dk <= 8'hee; 9'h00c: dk <= 8'h1a; 9'h00d: dk <= 8'hd0; 9'h00e: dk <= 8'h59; 9'h00f: dk <= 8'h76;
            9'h010: dk <= 8'h5e; 9'h011: dk <= 8'h75; 9'h012: dk <= 8'h79; 9'h013: dk <= 8'h16; 9'h014: dk <= 8'ha5; 9'h015: dk <= 8'hf6; 9'h016: dk <= 8'h84; 9'h017: dk <= 8'hed;
            9'h018: dk <= 8'h0f; 9'h019: dk <= 8'h2e; 9'h01a: dk <= 8'hf2; 9'h01b: dk <= 8'h36; 9'h01c: dk <= 8'h61; 9'h01d: dk <= 8'hac; 9'h01e: dk <= 8'hcd; 9'h01f: dk <= 8'hab;
            9'h020: dk <= 8'h01; 9'h021: dk <= 8'h3b; 9'h022: dk <= 8'h01; 9'h023: dk <= 8'h87; 9'h024: dk <= 8'h73; 9'h025: dk <= 8'hab; 9'h026: dk <= 8'hce; 9'h027: dk <= 8'h5d;
            9'h028: dk <= 8'hd4; 9'h029: dk <= 8'h1d; 9'h02a: dk <= 8'h68; 9'h02b: dk <= 8'h2a; 9'h02c: dk <= 8'h35; 9'h02d: dk <= 8'hea; 9'h02e: dk <= 8'h13; 9'h02f: dk <= 8'h27;
            9'h030: dk <= 8'h00; 9'h031: dk <= 8'haa; 9'h032: dk <= 8'h46; 9'h033: dk <= 8'h36; 9'h034: dk <= 8'h6e; 9'h035: dk <= 8'h65; 9'h036: dk <= 8'h80; 9'h037: dk <= 8'h7e;
            9'h038: dk <= 8'h19; 9'h039: dk <= 8'he2; 9'h03a: dk <= 8'h96; 9'h03b: dk <= 8'hab; 9'h03c: dk <= 8'hac; 9'h03d: dk <= 8'ha5; 9'h03e: dk <= 8'h6c; 9'h03f: dk <= 8'h63;
            9'h040: dk <= 8'h4a; 9'h041: dk <= 8'h6f; 9'h042: dk <= 8'h87; 9'h043: dk <= 8'hf6; 9'h044: dk <= 8'h6a; 9'h045: dk <= 8'hac; 9'h046: dk <= 8'h38; 9'h047: dk <= 8'he2;
            9'h048: dk <= 8'h1f; 9'h049: dk <= 8'h87; 9'h04a: dk <= 8'hf9; 9'h04b: dk <= 8'haa; 9'h04c: dk <= 8'hf5; 9'h04d: dk <= 8'h41; 9'h04e: dk <= 8'h60; 9'h04f: dk <= 8'ha6;
            9'h050: dk <= 8'h42; 9'h051: dk <= 8'hb9; 9'h052: dk <= 8'h30; 9'h053: dk <= 8'hf2; 9'h054: dk <= 8'hc3; 9'h055: dk <= 8'h1c; 9'h056: dk <= 8'h4e; 9'h057: dk <= 8'h4b;
            9'h058: dk <= 8'h08; 9'h059: dk <= 8'h10; 9'h05a: dk <= 8'h42; 9'h05b: dk <= 8'h32; 9'h05c: dk <= 8'hbf; 9'h05d: dk <= 8'hb2; 9'h05e: dk <= 8'hc5; 9'h05f: dk <= 8'h0f;
            9'h060: dk <= 8'h7a; 9'h061: dk <= 8'hab; 9'h062: dk <= 8'h97; 9'h063: dk <= 8'hf6; 9'h064: dk <= 8'he7; 9'h065: dk <= 8'hb3; 9'h066: dk <= 8'h46; 9'h067: dk <= 8'hf8;
            9'h068: dk <= 8'hec; 9'h069: dk <= 8'h2b; 9'h06a: dk <= 8'h7d; 9'h06b: dk <= 8'h5f; 9'h06c: dk <= 8'hb1; 9'h06d: dk <= 8'h10; 9'h06e: dk <= 8'h03; 9'h06f: dk <= 8'he4;
            9'h070: dk <= 8'h0f; 9'h071: dk <= 8'h22; 9'h072: dk <= 8'hdf; 9'h073: dk <= 8'h8d; 9'h074: dk <= 8'h10; 9'h075: dk <= 8'h66; 9'h076: dk <= 8'ha7; 9'h077: dk <= 8'h7e;
            9'h078: dk <= 8'h96; 9'h079: dk <= 8'hbd; 9'h07a: dk <= 8'h5a; 9'h07b: dk <= 8'haf; 9'h07c: dk <= 8'haa; 9'h07d: dk <= 8'h43; 9'h07e: dk <= 8'hdf; 9'h07f: dk <= 8'h10;
            9'h080: dk <= 8'h7c; 9'h081: dk <= 8'h04; 9'h082: dk <= 8'he2; 9'h083: dk <= 8'h9d; 9'h084: dk <= 8'h66; 9'h085: dk <= 8'hd7; 9'h086: dk <= 8'hf0; 9'h087: dk <= 8'h02;
            9'h088: dk <= 8'h58; 9'h089: dk <= 8'h8a; 9'h08a: dk <= 8'h55; 9'h08b: dk <= 8'h17; 9'h08c: dk <= 8'h16; 9'h08d: dk <= 8'he2; 9'h08e: dk <= 8'he2; 9'h08f: dk <= 8'h52;
            9'h090: dk <= 8'haf; 9'h091: dk <= 8'hd9; 9'h092: dk <= 8'hf9; 9'h093: dk <= 8'h0d; 9'h094: dk <= 8'h59; 9'h095: dk <= 8'h70; 9'h096: dk <= 8'h86; 9'h097: dk <= 8'h3c;
            9'h098: dk <= 8'h05; 9'h099: dk <= 8'hd1; 9'h09a: dk <= 8'h52; 9'h09b: dk <= 8'ha7; 9'h09c: dk <= 8'hf0; 9'h09d: dk <= 8'hbf; 9'h09e: dk <= 8'h17; 9'h09f: dk <= 8'hd0;
            9'h0a0: dk <= 8'h23; 9'h0a1: dk <= 8'h15; 9'h0a2: dk <= 8'hfe; 9'h0a3: dk <= 8'h23; 9'h0a4: dk <= 8'hf2; 9'h0a5: dk <= 8'h80; 9'h0a6: dk <= 8'h60; 9'h0a7: dk <= 8'h6f;
            9'h0a8: dk <= 8'h95; 9'h0a9: dk <= 8'h89; 9'h0aa: dk <= 8'h67; 9'h0ab: dk <= 8'h65; 9'h0ac: dk <= 8'hc9; 9'h0ad: dk <= 8'h0e; 9'h0ae: dk <= 8'hfc; 9'h0af: dk <= 8'h16;
            9'h0b0: dk <= 8'hd6; 9'h0b1: dk <= 8'h8a; 9'h0b2: dk <= 8'h9f; 9'h0b3: dk <= 8'h25; 9'h0b4: dk <= 8'h2c; 9'h0b5: dk <= 8'h0f; 9'h0b6: dk <= 8'h2d; 9'h0b7: dk <= 8'he4;
            9'h0b8: dk <= 8'h51; 9'h0b9: dk <= 8'hb2; 9'h0ba: dk <= 8'ha8; 9'h0bb: dk <= 8'h18; 9'h0bc: dk <= 8'h3a; 9'h0bd: dk <= 8'h5d; 9'h0be: dk <= 8'h66; 9'h0bf: dk <= 8'ha0;
            9'h0c0: dk <= 8'h9f; 9'h0c1: dk <= 8'hb0; 9'h0c2: dk <= 8'h58; 9'h0c3: dk <= 8'hea; 9'h0c4: dk <= 8'h78; 9'h0c5: dk <= 8'h72; 9'h0c6: dk <= 8'h08; 9'h0c7: dk <= 8'h6a;
            9'h0c8: dk <= 8'h90; 9'h0c9: dk <= 8'hb6; 9'h0ca: dk <= 8'ha4; 9'h0cb: dk <= 8'hf5; 9'h0cc: dk <= 8'h08; 9'h0cd: dk <= 8'h19; 9'h0ce: dk <= 8'h60; 9'h0cf: dk <= 8'h4e;
            9'h0d0: dk <= 8'h92; 9'h0d1: dk <= 8'hbd; 9'h0d2: dk <= 8'hf1; 9'h0d3: dk <= 8'h05; 9'h0d4: dk <= 8'h67; 9'h0d5: dk <= 8'h4f; 9'h0d6: dk <= 8'h24; 9'h0d7: dk <= 8'h99;
            9'h0d8: dk <= 8'h69; 9'h0d9: dk <= 8'h1d; 9'h0da: dk <= 8'h0c; 9'h0db: dk <= 8'h6d; 9'h0dc: dk <= 8'he7; 9'h0dd: dk <= 8'h74; 9'h0de: dk <= 8'h88; 9'h0df: dk <= 8'h22;
            9'h0e0: dk <= 8'h2d; 9'h0e1: dk <= 8'h15; 9'h0e2: dk <= 8'h7a; 9'h0e3: dk <= 8'ha2; 9'h0e4: dk <= 8'h37; 9'h0e5: dk <= 8'ha9; 9'h0e6: dk <= 8'ha0; 9'h0e7: dk <= 8'hb0;
            9'h0e8: dk <= 8'h2c; 9'h0e9: dk <= 8'hfb; 9'h0ea: dk <= 8'h27; 9'h0eb: dk <= 8'he5; 9'h0ec: dk <= 8'h4f; 9'h0ed: dk <= 8'hb6; 9'h0ee: dk <= 8'hcd; 9'h0ef: dk <= 8'h75;
            9'h0f0: dk <= 8'hdc; 9'h0f1: dk <= 8'h39; 9'h0f2: dk <= 8'hce; 9'h0f3: dk <= 8'h6f; 9'h0f4: dk <= 8'h1f; 9'h0f5: dk <= 8'hfe; 9'h0f6: dk <= 8'hcc; 9'h0f7: dk <= 8'hb5;
            9'h0f8: dk <= 8'he6; 9'h0f9: dk <= 8'hda; 9'h0fa: dk <= 8'hd8; 9'h0fb: dk <= 8'hee; 9'h0fc: dk <= 8'h85; 9'h0fd: dk <= 8'hee; 9'h0fe: dk <= 8'h2f; 9'h0ff: dk <= 8'h04;
            9'h100: dk <= 8'h26; 9'h101: dk <= 8'h17; 9'h102: dk <= 8'hb9; 9'h103: dk <= 8'hcf; 9'h104: dk <= 8'h1a; 9'h105: dk <= 8'hf5; 9'h106: dk <= 8'h14; 9'h107: dk <= 8'h1e;
            9'h108: dk <= 8'h0c; 9'h109: dk <= 8'h35; 9'h10a: dk <= 8'hb3; 9'h10b: dk <= 8'h66; 9'h10c: dk <= 8'ha0; 9'h10d: dk <= 8'h17; 9'h10e: dk <= 8'he9; 9'h10f: dk <= 8'he4;
            9'h110: dk <= 8'h90; 9'h111: dk <= 8'hf6; 9'h112: dk <= 8'hd5; 9'h113: dk <= 8'h35; 9'h114: dk <= 8'hac; 9'h115: dk <= 8'h95; 9'h116: dk <= 8'h49; 9'h117: dk <= 8'h43;
            9'h118: dk <= 8'h64; 9'h119: dk <= 8'h0c; 9'h11a: dk <= 8'h03; 9'h11b: dk <= 8'h75; 9'h11c: dk <= 8'h4d; 9'h11d: dk <= 8'hda; 9'h11e: dk <= 8'hb6; 9'h11f: dk <= 8'hdf;
            9'h120: dk <= 8'h06; 9'h121: dk <= 8'hcf; 9'h122: dk <= 8'h83; 9'h123: dk <= 8'h9e; 9'h124: dk <= 8'h35; 9'h125: dk <= 8'h2c; 9'h126: dk <= 8'h71; 9'h127: dk <= 8'h2a;
            9'h128: dk <= 8'hab; 9'h129: dk <= 8'hcc; 9'h12a: dk <= 8'h65; 9'h12b: dk <= 8'hd4; 9'h12c: dk <= 8'h1f; 9'h12d: dk <= 8'hb0; 9'h12e: dk <= 8'h88; 9'h12f: dk <= 8'h3c;
            9'h130: dk <= 8'hb7; 9'h131: dk <= 8'h87; 9'h132: dk <= 8'h35; 9'h133: dk <= 8'hc0; 9'h134: dk <= 8'h41; 9'h135: dk <= 8'h65; 9'h136: dk <= 8'h9f; 9'h137: dk <= 8'ha0;
            9'h138: dk <= 8'hd5; 9'h139: dk <= 8'h8c; 9'h13a: dk <= 8'h3e; 9'h13b: dk <= 8'h06; 9'h13c: dk <= 8'h53; 9'h13d: dk <= 8'hdb; 9'h13e: dk <= 8'h45; 9'h13f: dk <= 8'h64;
            9'h140: dk <= 8'h09; 9'h141: dk <= 8'h1e; 9'h142: dk <= 8'hc5; 9'h143: dk <= 8'h8d; 9'h144: dk <= 8'h50; 9'h145: dk <= 8'h24; 9'h146: dk <= 8'he2; 9'h147: dk <= 8'h4a;
            9'h148: dk <= 8'h9b; 9'h149: dk <= 8'h99; 9'h14a: dk <= 8'h77; 9'h14b: dk <= 8'h25; 9'h14c: dk <= 8'h43; 9'h14d: dk <= 8'ha9; 9'h14e: dk <= 8'h1d; 9'h14f: dk <= 8'hac;
            9'h150: dk <= 8'h99; 9'h151: dk <= 8'h31; 9'h152: dk <= 8'h75; 9'h153: dk <= 8'hb5; 9'h154: dk <= 8'h53; 9'h155: dk <= 8'hab; 9'h156: dk <= 8'had; 9'h157: dk <= 8'h5a;
            9'h158: dk <= 8'h42; 9'h159: dk <= 8'h14; 9'h15a: dk <= 8'ha1; 9'h15b: dk <= 8'h52; 9'h15c: dk <= 8'hac; 9'h15d: dk <= 8'hec; 9'h15e: dk <= 8'h5f; 9'h15f: dk <= 8'hf8;
            9'h160: dk <= 8'h8c; 9'h161: dk <= 8'h78; 9'h162: dk <= 8'h05; 9'h163: dk <= 8'h47; 9'h164: dk <= 8'hea; 9'h165: dk <= 8'hb8; 9'h166: dk <= 8'hde; 9'h167: dk <= 8'h69;
            9'h168: dk <= 8'h98; 9'h169: dk <= 8'h2d; 9'h16a: dk <= 8'h8f; 9'h16b: dk <= 8'h9d; 9'h16c: dk <= 8'hfc; 9'h16d: dk <= 8'h05; 9'h16e: dk <= 8'hea; 9'h16f: dk <= 8'hee;
            9'h170: dk <= 8'h77; 9'h171: dk <= 8'hbb; 9'h172: dk <= 8'ha9; 9'h173: dk <= 8'h31; 9'h174: dk <= 8'h01; 9'h175: dk <= 8'h00; 9'h176: dk <= 8'hea; 9'h177: dk <= 8'hd8;
            9'h178: dk <= 8'h9c; 9'h179: dk <= 8'h43; 9'h17a: dk <= 8'hb5; 9'h17b: dk <= 8'h2f; 9'h17c: dk <= 8'h4e; 9'h17d: dk <= 8'hb5; 9'h17e: dk <= 8'h1b; 9'h17f: dk <= 8'hd2;
            9'h180: dk <= 8'h01; 9'h181: dk <= 8'h4b; 9'h182: dk <= 8'hc4; 9'h183: dk <= 8'hf8; 9'h184: dk <= 8'h76; 9'h185: dk <= 8'h92; 9'h186: dk <= 8'h59; 9'h187: dk <= 8'h4f;
            9'h188: dk <= 8'h20; 9'h189: dk <= 8'h52; 9'h18a: dk <= 8'hd9; 9'h18b: dk <= 8'h7f; 9'h18c: dk <= 8'ha9; 9'h18d: dk <= 8'h19; 9'h18e: dk <= 8'he9; 9'h18f: dk <= 8'h7c;
            9'h190: dk <= 8'h8d; 9'h191: dk <= 8'h3b; 9'h192: dk <= 8'hec; 9'h193: dk <= 8'he0; 9'h194: dk <= 8'h60; 9'h195: dk <= 8'h08; 9'h196: dk <= 8'h2e; 9'h197: dk <= 8'hbd;
            9'h198: dk <= 8'h27; 9'h199: dk <= 8'h8b; 9'h19a: dk <= 8'hb2; 9'h19b: dk <= 8'hfc; 9'h19c: dk <= 8'h29; 9'h19d: dk <= 8'hd8; 9'h19e: dk <= 8'h39; 9'h19f: dk <= 8'h8a;
            9'h1a0: dk <= 8'h4f; 9'h1a1: dk <= 8'h2f; 9'h1a2: dk <= 8'h6b; 9'h1a3: dk <= 8'h04; 9'h1a4: dk <= 8'h10; 9'h1a5: dk <= 8'hbd; 9'h1a6: dk <= 8'ha1; 9'h1a7: dk <= 8'h04;
            9'h1a8: dk <= 8'hde; 9'h1a9: dk <= 8'hc0; 9'h1aa: dk <= 8'hd5; 9'h1ab: dk <= 8'h0f; 9'h1ac: dk <= 8'h04; 9'h1ad: dk <= 8'h86; 9'h1ae: dk <= 8'hd6; 9'h1af: dk <= 8'hd8;
            9'h1b0: dk <= 8'hfd; 9'h1b1: dk <= 8'hb1; 9'h1b2: dk <= 8'h3c; 9'h1b3: dk <= 8'h4c; 9'h1b4: dk <= 8'hd1; 9'h1b5: dk <= 8'hc4; 9'h1b6: dk <= 8'hf1; 9'h1b7: dk <= 8'h5b;
            9'h1b8: dk <= 8'hf5; 9'h1b9: dk <= 8'h8b; 9'h1ba: dk <= 8'he3; 9'h1bb: dk <= 8'hc4; 9'h1bc: dk <= 8'h89; 9'h1bd: dk <= 8'h3c; 9'h1be: dk <= 8'h39; 9'h1bf: dk <= 8'h86;
            9'h1c0: dk <= 8'hd2; 9'h1c1: dk <= 8'h92; 9'h1c2: dk <= 8'hc9; 9'h1c3: dk <= 8'he5; 9'h1c4: dk <= 8'h2c; 9'h1c5: dk <= 8'h4f; 9'h1c6: dk <= 8'he2; 9'h1c7: dk <= 8'h2f;
            9'h1c8: dk <= 8'h2d; 9'h1c9: dk <= 8'hc5; 9'h1ca: dk <= 8'h35; 9'h1cb: dk <= 8'h09; 9'h1cc: dk <= 8'h94; 9'h1cd: dk <= 8'h47; 9'h1ce: dk <= 8'h3c; 9'h1cf: dk <= 8'h04;
            9'h1d0: dk <= 8'h40; 9'h1d1: dk <= 8'h8b; 9'h1d2: dk <= 8'h57; 9'h1d3: dk <= 8'h08; 9'h1d4: dk <= 8'hf6; 9'h1d5: dk <= 8'h74; 9'h1d6: dk <= 8'he9; 9'h1d7: dk <= 8'hb8;
            9'h1d8: dk <= 8'h36; 9'h1d9: dk <= 8'h4d; 9'h1da: dk <= 8'hc5; 9'h1db: dk <= 8'h26; 9'h1dc: dk <= 8'h13; 9'h1dd: dk <= 8'h3d; 9'h1de: dk <= 8'h75; 9'h1df: dk <= 8'ha0;
            9'h1e0: dk <= 8'ha8; 9'h1e1: dk <= 8'h29; 9'h1e2: dk <= 8'h09; 9'h1e3: dk <= 8'h8c; 9'h1e4: dk <= 8'h87; 9'h1e5: dk <= 8'hf7; 9'h1e6: dk <= 8'h13; 9'h1e7: dk <= 8'haf;
            9'h1e8: dk <= 8'h4c; 9'h1e9: dk <= 8'h38; 9'h1ea: dk <= 8'h0b; 9'h1eb: dk <= 8'h8a; 9'h1ec: dk <= 8'h7f; 9'h1ed: dk <= 8'h2c; 9'h1ee: dk <= 8'h62; 9'h1ef: dk <= 8'h27;
            9'h1f0: dk <= 8'h47; 9'h1f1: dk <= 8'haa; 9'h1f2: dk <= 8'hda; 9'h1f3: dk <= 8'h07; 9'h1f4: dk <= 8'h92; 9'h1f5: dk <= 8'h8d; 9'h1f6: dk <= 8'hfd; 9'h1f7: dk <= 8'h1f;
            9'h1f8: dk <= 8'hee; 9'h1f9: dk <= 8'h48; 9'h1fa: dk <= 8'h1a; 9'h1fb: dk <= 8'h53; 9'h1fc: dk <= 8'h3b; 9'h1fd: dk <= 8'h98; 9'h1fe: dk <= 8'h6a; 9'h1ff: dk <= 8'h72;
        endcase
    end

endmodule
