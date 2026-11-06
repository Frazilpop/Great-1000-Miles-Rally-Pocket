// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — save states for the gtmr board
//
// The board is saved at a clean point in vertical blank and loaded into a
// fresh run, and from the clock each lets go the two are the same.
//
// THE CLEAN POINT. In a frame whose swap at line 240 both showed the list just
// drawn and started the one just captured (kc_swap_full), from line 241: the
// 68000 parked at an instruction boundary with its bus idle, both OKIs' control
// machines idle, then at the OKIs' dead phase (no slot runs) on oki_div 13 the
// board freezes. The 68000's last enable was a phi2 and its next is a phi1; the
// OKIs' last cen came 13 clocks before. Video runs on, the picture held: the
// freeze stops the KC-002's capture and swap, the layers' latch, the scanline
// the interrupts see and the random numbers. A draw in hand finishes, and then
// the state can be read. A save or a load lets go in the one clock where the
// raster is back at the position of the freeze, on oki_div 13, a frame edge or
// more later.
//
// THE WINDOW. ss_addr is a word of the file (its byte offset / 2). ss_rd puts
// that word on ss_do within SS_CLOCKS clocks, ss_wr writes ss_di there; one at
// a time, SS_CLOCKS apart at the fastest. ss_save asks for a clean point;
// ss_status says 0 running, 1 busy, 2 ok (frozen, or a load restored and
// waiting to let go), 3 error. ss_go ends a save's read-out, or a load's
// writes. A load starts by itself: words 0 to 15 written while running are
// the header, and if words 0 to 11 match this board and its ROM the board
// stops at word 15 for the rest (ss_loading); if not, nothing is touched and
// ss_refused says so.
//
// THE FILE (byte offsets; memories in the 68000's byte order):
//   00000 header          00040 the board's words      00080 the 68000
//   00100 VIEW2 regs 0    00110 VIEW2 regs 1           00130 the hit chip's eight
//   00140 sprite regs     00180 the EEPROM             00400 the OKIs' chain
//   01000 sprite RAM      04000 VIEW2 RAM 0            08000 VIEW2 RAM 1
//   0C000 the KC-002's two lists                       10000 work RAM
//   20000 palette         30000 MCU-shared RAM         40000 the RAM at 310000
// Everything through the 68000's bus is read and written at its own address,
// with ordinary bus cycles (ss_bus): no RAM array is touched for this.
//
// THE 68000 (fx68k with tools/patches/fx68k-state.patch) is put back as it was
// on the Genesis core this port's method comes from: held in extReset with its
// clock run alone a while, its registers through the register file's port,
// let out of reset with the reset vectors answered from the state (the saved
// SSP, and the PC less the prefetch's 2, less 6 in STOP's loop), parked at the
// reset's dispatch where the exception latches and SR are set, let go to the
// boundary and parked again, and there the SR, the latches, inl, intPend,
// prevNmi, Tpend, tState, eCntr and rVma loaded.

`timescale 1ns/1ps
`default_nettype none

module kaneko_state #(
    parameter [15:0] CORE_VER_HI = 16'h0101,   // 1.1.0
    parameter [15:0] CORE_VER_LO = 16'h0000
)(
    input  wire        clk,
    input  wire        rst,             // power-up's, and until the ROM is in
    input  wire [2:0]  game,

    // ---- the window
    input  wire        ss_save,
    input  wire        ss_go,
    output wire [1:0]  ss_status,
    output wire        ss_loading,      // a load: the header matched, until it lets go
    output reg         ss_refused,      // the last header didn't match
    input  wire [17:0] ss_addr,
    input  wire        ss_rd,
    output reg  [15:0] ss_do,
    input  wire        ss_wr,
    input  wire [15:0] ss_di,

    // ---- the ROM image, as it loads (for the header's sum)
    input  wire        dl_wr,
    input  wire [15:0] dl_data,

    // ---- the raster
    input  wire [9:0]  vcnt,
    input  wire [9:0]  hcnt,
    input  wire        line_start,
    input  wire        frame_edge,
    input  wire [4:0]  oki_div,

    // ---- the 68000
    output reg         ss_park68,
    output reg         ss_parkdisp68,
    output reg         ss_rst68,
    output reg         ss_run68,
    input  wire        fx_atstart,
    input  wire        fx_atdisp,
    input  wire        fx_busidle,
    input  wire [9:0]  fx_uaddr,
    input  wire [31:0] fx_regq,
    input  wire [31:0] fx_pc,
    input  wire [15:0] fx_sr,
    input  wire [15:0] fx_misc,
    input  wire [15:0] fx_grpdisp,
    input  wire [15:0] fx_clk,
    output wire [4:0]  fx_rega,
    output wire        fx_regwe,
    output wire [31:0] fx_regd,
    output reg         fx_srwe, fx_miscwe, fx_grpwe, fx_clkwe,
    output reg  [15:0] fx_srd, fx_miscd, fx_grpd, fx_clkd,
    output reg         ss_vec,
    output reg  [31:0] ss_vec_sp,
    output reg  [31:0] ss_vec_pc,
    input  wire        cpu_asn,          // the 68000's AS
    input  wire        cpu_vec3,         // its address is word 3 (the reset PC's low word)
    input  wire        bus_dtackn,       // the bus's DTACK
    input  wire [2:0]  cpu_ipl_n,
    input  wire        bus_idle,         // kaneko_gtmr_bus idle, no ROM or SRAM request
    input  wire        mcu_busy,

    // ---- what is held
    output reg         ss_freeze,        // 68000 enables, OKIs' cen, lfsr, the scanline the IRQs see, KC-002 capture/swap, layer latch
    output reg         ss_okirun,        // (a load) the OKIs run on to their dead phase under the freeze
    output reg         ss_sysrst,        // (a load) bus, IRQs, hit, TOYBOX, KC-002, banks reset before they are written
    output reg         ss_cinval,        // (let-go) the 68000's line cache emptied, in both runs

    // ---- the OKIs: one chain, this module -> OKI 1 -> OKI 0 -> this module
    output reg         ss_scan,
    output wire        ss_gsh,
    output wire        ss_gi,
    input  wire        oki_go,
    input  wire [1:0]  oki_quiet,
    input  wire [1:0]  oki_phase,

    // ---- the KC-002
    input  wire        kc_swap_full,     // this frame's swap showed a drawn list and started a new one
    input  wire        kc_draw_busy,
    input  wire        kc_disp,
    input  wire        kc_snap_sel,      // the list being drawn, or last drawn
    output wire        kc_snap_en,
    output wire [12:0] kc_snap_a,
    output wire        kc_snap_we,
    output wire [15:0] kc_snap_d,
    input  wire [15:0] kc_snap_q,
    output reg         kc_draw,          // draw now: disp and draw_snap as given
    output reg         kc_draw_disp,
    output reg         kc_draw_snap,

    // ---- the bus, as the 68000 drives it (word cycles)
    output wire        ss_bus,
    output reg         ss_as,
    output reg  [23:1] ss_a,
    output reg  [15:0] ss_d,
    output reg         ss_rw,
    input  wire [15:0] bus_q,

    // ---- the EEPROM, TOYBOX's side of it
    output wire        ss_ee,
    output wire [5:0]  ss_ee_a,
    output wire        ss_ee_we,
    output wire [15:0] ss_ee_d,
    input  wire [15:0] ee_q,

    // ---- the board's words at 0x46-0x67 (aux 3-19), read and written by the top
    input  wire [319:0] aux_q,           // word i at [i*16 +: 16]; 0-2 are this module's
    output wire        aux_we,
    output wire [4:0]  aux_i,
    output wire [15:0] aux_d
);

    localparam int SS_CLOCKS = 20;
    localparam [17:0] LAST   = 18'h2BFFF;         // the file's last word
    localparam [31:0] SS_START_PC = 32'd2;
    localparam [31:0] SS_STOP_PC  = 32'd6;
    localparam  [9:0] SS_STOP_UA  = 10'h3A2;
    localparam  [9:0] CHAIN_BITS  = 10'd1010;

    // ================================================================ the ROM's sum
    /* verilator lint_off PROCASSINIT */
    logic [31:0] rom_words = '0, rom_sum = '0;     // from power-up: the ROM loads once
    logic [31:0] frames = '0;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge clk) begin
        if (dl_wr) begin
            rom_words <= rom_words + 32'd1;
            rom_sum   <= {rom_sum[30:0], rom_sum[31]} + {16'd0, dl_data};
        end
        if (frame_edge) frames <= frames + 32'd1;
    end

    // ================================================================ regions
    typedef enum logic [4:0] {
        E_RUN, E_SEEK, E_PARK, E_FROZEN, E_UNSCAN, E_WAIT,
        E_LSTOP, E_LOADING, E_R0, E_R1, E_R2, E_R3, E_R4,
        E_KC1, E_KC2, E_KC3, E_KC4
    } est_t;
    est_t st;

    logic        rd_busy, wr_busy;
    logic [4:0]  e_cnt;
    logic [17:0] e_a;
    logic [15:0] e_wd;

    wire [17:0] ea = e_a;
    wire in_hdr   = ea < 18'h20;
    wire in_aux   = ea >= 18'h20    && ea < 18'h34;
    wire in_68k   = ea >= 18'h40    && ea < 18'h80;
    wire in_v2r0  = ea >= 18'h80    && ea < 18'h88;
    wire in_v2r1  = ea >= 18'h88    && ea < 18'h98;
    wire in_hit   = ea >= 18'h98    && ea < 18'hA0;
    wire in_sprr  = ea >= 18'hA0    && ea < 18'hB0;
    wire in_ee    = ea >= 18'hC0    && ea < 18'h100;
    wire in_chain = ea >= 18'h200   && ea < 18'h240;
    wire in_spr   = ea >= 18'h800   && ea < 18'h1800;    // 8 KB, 4K words
    wire in_v2w0  = ea >= 18'h2000  && ea < 18'h4000;
    wire in_v2w1  = ea >= 18'h4000  && ea < 18'h6000;
    wire in_snap  = ea >= 18'h6000  && ea < 18'h8000;
    wire in_wram  = ea >= 18'h8000  && ea < 18'h10000;
    wire in_pal   = ea >= 18'h10000 && ea < 18'h18000;
    wire in_mram  = ea >= 18'h18000 && ea < 18'h20000;
    wire in_xram  = ea >= 18'h20000 && ea <= LAST;
    wire last_chain = ea == 18'h23F;              // 1010 = 63 x 16 + 2
    wire [17:0] o_aux = ea - 18'h20, o_68k = ea - 18'h40;

    // The 68000 address of a word reached through the bus
    logic        e_bus;
    logic [23:1] e_bus_a;
    always_comb begin
        e_bus = 1'b1;
        e_bus_a = '0;
        if (in_v2r0)      e_bus_a = 23'h300000 | 23'(ea[2:0]);                    // 600000
        else if (in_v2r1) e_bus_a = 23'h340000 | 23'(ea - 18'h88);                // 680000
        else if (in_hit)  e_bus_a = 23'h480000 | ((ea[2:0] < 3'd4) ? 23'h10 + 23'(ea[2:0])
                                                                   : 23'h16 + 23'(ea[2:0] - 3'd4)); // 900020-26, 90002c-32
        else if (in_sprr) e_bus_a = 23'h380000 | 23'(ea[3:0]);                    // 700000
        else if (in_spr)  e_bus_a = 23'h200000 | 23'(ea - 18'h800);               // 400000
        else if (in_v2w0) e_bus_a = 23'h280000 | 23'(ea - 18'h2000);              // 500000
        else if (in_v2w1) e_bus_a = 23'h2C0000 | 23'(ea - 18'h4000);              // 580000
        else if (in_wram) e_bus_a = 23'h080000 | 23'(ea - 18'h8000);              // 100000
        else if (in_pal)  e_bus_a = 23'h180000 | 23'(ea - 18'h10000);             // 300000
        else if (in_mram) e_bus_a = 23'h100000 | 23'(ea - 18'h18000);             // 200000
        else if (in_xram) e_bus_a = 23'h188000 + 23'(ea - 18'h20000);             // 310000
        else e_bus = 1'b0;
    end

    // ================================================================ bus cycles
    typedef enum logic [2:0] { B_IDLE, B_ADDR, B_AS, B_HOLD, B_END } bst_t;
    bst_t        b_st;
    logic [1:0]  b_cnt;
    logic [15:0] b_q;
    assign ss_bus = (b_st != B_IDLE);
    always_ff @(posedge clk) begin
        if (rst) begin
            b_st <= B_IDLE; ss_as <= 1'b0;
        end else case (b_st)
            B_IDLE: ;
            B_ADDR: begin ss_as <= 1'b1; b_st <= B_AS; end
            B_AS:   if (!bus_dtackn) begin b_cnt <= 2'd0; b_st <= B_HOLD; end
            B_HOLD: begin
                b_cnt <= b_cnt + 2'd1;
                if (b_cnt == 2'd1) begin b_q <= bus_q; ss_as <= 1'b0; b_st <= B_END; end
            end
            B_END:  if (bus_dtackn) b_st <= B_IDLE;
            default: b_st <= B_IDLE;
        endcase
        if ((rd_busy | wr_busy) && e_cnt == 5'd0 && e_bus && b_st == B_IDLE) begin
            ss_a  <= e_bus_a;
            ss_rw <= rd_busy;
            ss_d  <= e_wd;
            b_st  <= B_ADDR;
        end
    end

    // ================================================================ the chain
    logic [9:0]  ch_pos;          // bits moved, mod 1010
    logic        ch_done;         // (a load) its last word written
    logic [15:0] rd_sh;
    wire un_chain = st == E_UNSCAN && ch_pos != 10'd0;
    wire ch_move  = (rd_busy | wr_busy) && in_chain && e_cnt >= 5'd1 && e_cnt <= (last_chain ? 5'd2 : 5'd16);
    assign ss_gsh = ch_move || un_chain;
    assign ss_gi  = (wr_busy && in_chain) ? e_wd[4'(5'd16 - e_cnt)] : oki_go;

    // ================================================================ KC-002, EEPROM, the 68000's port
    assign kc_snap_en = (rd_busy | wr_busy) && in_snap;
    assign kc_snap_a  = 13'(ea - 18'h6000);
    assign kc_snap_we = wr_busy && in_snap && e_cnt == 5'd0;
    assign kc_snap_d  = e_wd;

    assign ss_ee    = (rd_busy | wr_busy) && in_ee;
    assign ss_ee_a  = 6'(ea - 18'hC0);
    assign ss_ee_we = wr_busy && in_ee && e_cnt <= 5'd1;     // twice: a .sav word may take the port on one
    assign ss_ee_d  = e_wd;

    logic [15:0] st_reghi;
    assign fx_rega  = o_68k[5:1];
    assign fx_regd  = {st_reghi, e_wd};
    assign fx_regwe = wr_busy && in_68k && e_cnt == 5'd0 && o_68k < 18'h22 && o_68k[0];

    assign aux_we = wr_busy && in_aux && e_cnt == 5'd0 && o_aux >= 18'd3;
    assign aux_i  = o_aux[4:0];
    assign aux_d  = e_wd;

    // ================================================================ staging
    logic [9:0]  sv_v, sv_h;      // the position at the freeze
    logic        sv_disp, sv_snap;
    logic        sv_stop;         // the 68000 was in STOP's loop
    logic [31:0] st_pc;
    logic [15:0] st_sr, st_misc, st_grpd, st_clk;

    // ================================================================ the header
    logic [15:0] hdr_word;
    always_comb
        case (ea[4:0])
            5'd0:  hdr_word = 16'h4B31;                 // "K16S"
            5'd1:  hdr_word = 16'h3653;
            5'd2:  hdr_word = 16'h0001;                 // the format's version
            5'd3:  hdr_word = {13'd0, game};
            5'd4:  hdr_word = 16'h0005;                 // its size, 0x58000
            5'd5:  hdr_word = 16'h8000;
            5'd6:  hdr_word = rom_words[31:16];
            5'd7:  hdr_word = rom_words[15:0];
            5'd8:  hdr_word = rom_sum[31:16];
            5'd9:  hdr_word = rom_sum[15:0];
            5'd12: hdr_word = CORE_VER_HI;              // the core's version: not checked
            5'd13: hdr_word = CORE_VER_LO;
            5'd14: hdr_word = frames[31:16];            // the frame since power-on: not checked
            5'd15: hdr_word = frames[15:0];
            default: hdr_word = 16'h0000;
        endcase
    // a load's header, as it comes: words 0 to 11 decide
    wire [15:0] ld_exp = hdr_word;
    logic       ld_bad;

    // ================================================================ the conditions
    wire ok68 = ss_park68 & fx_atstart & fx_busidle & cpu_asn & bus_dtackn & bus_idle & ~mcu_busy;
    wire stopirq = fx_uaddr == SS_STOP_UA &&
                   (fx_misc[1] || (~cpu_ipl_n == 3'd7) || ((~cpu_ipl_n) > fx_sr[10:8]));
    wire okis = &oki_quiet & &oki_phase;

    logic        err;
    logic [6:0]  tries;
    logic [7:0]  cnt;
    logic        retry, frame_seen, loaded, okiseek, vec3_seen;
    logic [19:0] wait_t;

    assign ss_status = err ? 2'd3 : st == E_RUN ? 2'd0 :
                       ((st == E_FROZEN && cnt > 8'd6 && !kc_draw_busy) || st == E_WAIT) ? 2'd2 : 2'd1;
    assign ss_loading = loaded || (st >= E_LSTOP);

    // ================================================================ the engine
    always_ff @(posedge clk) begin
        // pulses
        fx_srwe <= 1'b0; fx_miscwe <= 1'b0; fx_grpwe <= 1'b0; fx_clkwe <= 1'b0;
        ss_cinval <= 1'b0; kc_draw <= 1'b0;

        // ---- a word at a time
        if (ss_rd && (st == E_FROZEN && cnt > 8'd6)) begin
            rd_busy <= 1'b1; e_a <= ss_addr; e_cnt <= '0;
            if (ss_addr >= 18'h200 && ss_addr < 18'h240 && {ss_addr[5:0], 4'd0} != ch_pos) err <= 1'b1;
            if (rd_busy || wr_busy) err <= 1'b1;
        end else if (ss_wr && ((st == E_RUN && ss_addr < 18'd16) || st == E_LSTOP || st == E_LOADING)) begin
            wr_busy <= 1'b1; e_a <= ss_addr; e_wd <= ss_di; e_cnt <= '0;
            if (ss_addr >= 18'h200 && ss_addr < 18'h240 && {ss_addr[5:0], 4'd0} != ch_pos) err <= 1'b1;
            if (rd_busy || wr_busy) err <= 1'b1;
        end else if (rd_busy | wr_busy) begin
            e_cnt <= e_cnt + 5'd1;
            if (e_cnt == 5'(SS_CLOCKS - 2)) begin
                rd_busy <= 1'b0; wr_busy <= 1'b0;
                if (b_st != B_IDLE) err <= 1'b1;      // a bus word too slow
            end
        end

        if (ss_gsh) ch_pos <= (ch_pos == CHAIN_BITS - 10'd1) ? 10'd0 : ch_pos + 10'd1;
        if (rd_busy && ch_move) rd_sh <= {rd_sh[14:0], oki_go};

        // ---- what a read gives
        if (rd_busy && e_cnt == 5'(SS_CLOCKS - 3)) begin
            ss_do <= 16'h0000;
            if (in_hdr) ss_do <= hdr_word;
            if (in_aux) case (o_aux[4:0])
                5'd0:    ss_do <= {6'd0, sv_v};
                5'd1:    ss_do <= {6'd0, sv_h};
                5'd2:    ss_do <= {14'd0, kc_disp, kc_snap_sel};
                default: ss_do <= aux_q[o_aux[4:0]*16 +: 16];
            endcase
            if (in_68k) begin
                if (o_68k < 18'h22) ss_do <= o_68k[0] ? fx_regq[15:0] : fx_regq[31:16];
                else case (o_68k[5:0])
                    6'h22: ss_do <= fx_pc[31:16];
                    6'h23: ss_do <= fx_pc[15:0];
                    6'h24: ss_do <= fx_sr;
                    6'h25: ss_do <= fx_misc;
                    6'h26: ss_do <= fx_grpdisp;
                    6'h27: ss_do <= fx_clk;
                    6'h28: ss_do <= {15'd0, sv_stop};
                    6'h29: ss_do <= {6'd0, fx_uaddr};      // (to read, not loaded)
                    default: ;
                endcase
            end
            if (e_bus)    ss_do <= b_q;
            if (in_ee)    ss_do <= ee_q;
            if (in_snap)  ss_do <= kc_snap_q;
            if (in_chain) ss_do <= last_chain ? {rd_sh[1:0], 14'd0} : rd_sh;
        end

        // ---- what a write does
        if (wr_busy && e_cnt == 5'd0) begin
            if (in_hdr && st == E_RUN) begin
                if (ea == 18'd0) begin ld_bad <= (e_wd != ld_exp); ss_refused <= 1'b0; err <= 1'b0; end
                else if (ea < 18'd12) begin if (e_wd != ld_exp) ld_bad <= 1'b1; end
                else if (ea == 18'd15) begin
                    if (!ld_bad) begin
                        // the header fits: the board stops for the state
                        ss_freeze <= 1'b1; ss_rst68 <= 1'b1; ss_sysrst <= 1'b1;
                        ss_okirun <= 1'b1; okiseek <= 1'b1;
                        ss_park68 <= 1'b0; ss_parkdisp68 <= 1'b0; loaded <= 1'b0; ch_done <= 1'b0;
                        cnt <= '0; st <= E_LSTOP;
                    end else ss_refused <= 1'b1;
                end
            end
            if (in_aux) case (o_aux[4:0])
                5'd0: sv_v <= e_wd[9:0];
                5'd1: sv_h <= e_wd[9:0];
                5'd2: {sv_disp, sv_snap} <= e_wd[1:0];
                default: ;
            endcase
            if (in_68k) begin
                if (o_68k < 18'h22 && !o_68k[0]) st_reghi <= e_wd;
                if (o_68k == 18'h21) ss_vec_sp <= {st_reghi, e_wd};
                case (o_68k[5:0])
                    6'h22: st_pc[31:16] <= e_wd;
                    6'h23: st_pc[15:0]  <= e_wd;
                    6'h24: st_sr   <= e_wd;
                    6'h25: st_misc <= e_wd;
                    6'h26: st_grpd <= e_wd;
                    6'h27: st_clk  <= e_wd;
                    6'h28: sv_stop <= e_wd[0];
                    default: ;
                endcase
            end
            if (in_chain && last_chain) ch_done <= 1'b1;
        end

        // ---- the OKIs on a load: run on to their dead phase, then the scan
        if (okiseek && okis && oki_div == 5'd13) begin
            okiseek <= 1'b0; ss_okirun <= 1'b0; ss_scan <= 1'b1;
        end

        // ---- the 68000's reset vectors: done when the read of word 3 ends
        if (ss_vec && !cpu_asn && cpu_vec3) vec3_seen <= 1'b1;
        if (ss_vec && vec3_seen && cpu_asn) begin ss_vec <= 1'b0; vec3_seen <= 1'b0; end

        // ---- where it is
        case (st)
        E_RUN:
            if (ss_save) begin
                err <= 1'b0; tries <= '0; loaded <= 1'b0; st <= E_SEEK;
            end

        E_SEEK:
            // the window opens at line 241 of a frame whose swap did both jobs
            if (line_start && vcnt == 10'd241) begin
                if (kc_swap_full) begin ss_park68 <= 1'b1; retry <= 1'b0; st <= E_PARK; end
                else begin
                    tries <= tries + 7'd1;
                    if (tries == 7'd119) begin err <= 1'b1; st <= E_RUN; end
                end
            end

        E_PARK: begin
            // (parked in STOP with an interrupt waiting: a load would take it
            // going round STOP's loop, so let it run an instruction)
            if (retry) begin
                if (!fx_atstart) begin retry <= 1'b0; ss_park68 <= 1'b1; end
            end else if (ok68 && stopirq) begin
                retry <= 1'b1; ss_park68 <= 1'b0;
            end
            if (vcnt == 10'd256) begin
                // the window has closed: the next frame's
                ss_park68 <= 1'b0; retry <= 1'b0;
                tries <= tries + 7'd1;
                if (tries == 7'd119) begin err <= 1'b1; st <= E_RUN; end
                else st <= E_SEEK;
            end else if (ok68 && !stopirq && !retry && okis && oki_div == 5'd13) begin
                ss_freeze <= 1'b1;
                sv_v <= vcnt; sv_h <= hcnt;
                sv_stop <= fx_uaddr == SS_STOP_UA;
                ch_pos <= '0; cnt <= '0; st <= E_FROZEN;
            end
        end

        E_FROZEN: begin
            // readable once the OKIs are in their scan and the draw in hand is done
            if (cnt != 8'hff) cnt <= cnt + 8'd1;
            if (cnt == 8'd2) ss_scan <= 1'b1;
            if (ss_go && !rd_busy && cnt > 8'd6 && !kc_draw_busy) begin cnt <= '0; st <= E_UNSCAN; end
        end

        E_UNSCAN:
            if (!un_chain) begin
                frame_seen <= 1'b0; st <= E_WAIT;
            end

        E_WAIT:
            if (ss_save) begin
                // a save before a load has let go: the state as it was written
                ch_pos <= '0; cnt <= 8'd3; st <= E_FROZEN;
            end else begin
                if (frame_edge) frame_seen <= 1'b1;
                if (frame_seen && vcnt == sv_v && hcnt == sv_h && oki_div == 5'd13) begin
                    // let go, all in one clock
                    ss_freeze <= 1'b0; ss_park68 <= 1'b0; ss_scan <= 1'b0; ss_cinval <= 1'b1;
                    loaded <= 1'b0; st <= E_RUN;
                end
            end

        // ---------------------------------------------------------- a load
        E_LSTOP: begin
            // the 68000's clock run in its reset a while before its registers
            // are written: fx68k clears its bus cycle's latches only on its
            // enables, and the nanocode latched for the microword the reset
            // cut short writes a register on the first T3
            cnt <= cnt + 8'd1;
            if (cnt == 8'd2)   ss_run68 <= 1'b1;
            if (cnt == 8'd58)  ss_run68 <= 1'b0;
            if (cnt == 8'd128) ss_sysrst <= 1'b0;
            if (cnt == 8'd130) begin ch_pos <= '0; st <= E_LOADING; end
        end

        E_LOADING:
            if (ss_go && !wr_busy) begin
                if (ch_pos != 10'd0 || !ch_done || okiseek) err <= 1'b1;   // the chain not all written
                cnt <= '0; st <= E_R0;
            end

        E_R0: begin
            cnt <= cnt + 8'd1;
            if (cnt == 8'd0) ss_run68 <= 1'b1;
            if (cnt == 8'd4) begin
                // out of its reset, alone, to the dispatch the state was saved after
                ss_rst68 <= 1'b0; ss_parkdisp68 <= 1'b1; ss_vec <= 1'b1; vec3_seen <= 1'b0;
                ss_vec_pc <= st_pc - (sv_stop ? SS_STOP_PC : SS_START_PC);
                wait_t <= '0; st <= E_R1;
            end
        end

        E_R1: begin
            wait_t <= wait_t + 20'd1;
            if (fx_atdisp && !ss_vec) begin ss_run68 <= 1'b0; cnt <= '0; st <= E_R2; end
            else if (&wait_t) begin err <= 1'b1; cnt <= '0; st <= E_R4; end
        end

        E_R2: begin
            // the decision its dispatch takes, and the SR
            cnt <= cnt + 8'd1;
            if (cnt == 8'd3) begin fx_grpwe <= 1'b1; fx_grpd <= st_grpd; fx_srwe <= 1'b1; fx_srd <= st_sr; end
            if (cnt == 8'd5) begin
                ss_parkdisp68 <= 1'b0; ss_park68 <= 1'b1; ss_run68 <= 1'b1; retry <= 1'b0;
                wait_t <= '0; st <= E_R3;
            end
        end

        E_R3: begin
            wait_t <= wait_t + 20'd1;
            // (in STOP, round its loop until the PC is the saved one)
            if (retry) begin
                if (!fx_atstart) begin retry <= 1'b0; ss_park68 <= 1'b1; end
            end else if (fx_atstart && fx_busidle && cpu_asn && ss_park68) begin
                if (fx_pc == st_pc) begin ss_run68 <= 1'b0; cnt <= '0; st <= E_R4; end
                else begin retry <= 1'b1; ss_park68 <= 1'b0; end
            end
            if (&wait_t) begin err <= 1'b1; cnt <= '0; st <= E_R4; end
        end

        E_R4: begin
            // parked at its boundary: what it holds there
            cnt <= cnt + 8'd1;
            if (cnt == 8'd3) begin
                fx_srwe <= 1'b1;   fx_srd <= st_sr;
                fx_miscwe <= 1'b1; fx_miscd <= st_misc;
                fx_grpwe <= 1'b1;  fx_grpd <= {5'd0, st_misc[15:5]};
                fx_clkwe <= 1'b1;  fx_clkd <= st_clk;
            end
            if (cnt == 8'd5) st <= E_KC1;
        end

        // the sprite bitmap drawn again: the shown list, then the next
        E_KC1:
            if (line_start && vcnt == 10'd240) begin
                kc_draw <= 1'b1; kc_draw_disp <= ~sv_disp; kc_draw_snap <= ~sv_snap;
                cnt <= '0; st <= E_KC2;
            end
        E_KC2: begin
            if (cnt != 8'hff) cnt <= cnt + 8'd1;
            if (cnt > 8'd4 && !kc_draw_busy) st <= E_KC3;
        end
        E_KC3:
            if (line_start && vcnt == 10'd240) begin
                kc_draw <= 1'b1; kc_draw_disp <= sv_disp; kc_draw_snap <= sv_snap;
                cnt <= '0; st <= E_KC4;
            end
        E_KC4: begin
            if (cnt != 8'hff) cnt <= cnt + 8'd1;
            if (cnt > 8'd4 && !kc_draw_busy) begin loaded <= 1'b1; frame_seen <= 1'b0; st <= E_WAIT; end
        end

        default: st <= E_RUN;
        endcase

        if (rst) begin
            st <= E_RUN; err <= 1'b0; ld_bad <= 1'b1; ss_refused <= 1'b0;
            rd_busy <= 1'b0; wr_busy <= 1'b0;
            ss_freeze <= 1'b0; ss_okirun <= 1'b0; ss_sysrst <= 1'b0; ss_scan <= 1'b0;
            ss_park68 <= 1'b0; ss_parkdisp68 <= 1'b0; ss_rst68 <= 1'b0; ss_run68 <= 1'b0;
            ss_vec <= 1'b0; vec3_seen <= 1'b0; okiseek <= 1'b0; loaded <= 1'b0; retry <= 1'b0;
            ch_pos <= '0; ch_done <= 1'b0;
        end
    end

endmodule

`default_nettype wire
