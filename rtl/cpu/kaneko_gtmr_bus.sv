// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the gtmr board's 68000 bus
//
// gtmr_map and gtmr2_map from kaneko16.cpp. The two differ only in what the
// input words and the wheel read return, so one decoder serves both and
// `map2` picks the input wiring.
//
//   000000-0ffffd  ROM              SDRAM through a line cache (as kaneko_bus)
//   0ffffe-0fffff  wheel            0x00ff in joystick mode (gtmr), 0xffff (gtmr2)
//   100000-10ffff  work RAM         on-chip
//   200000-20ffff  MCU-shared RAM   external SRAM words 0x00000-0x07fff
//   2a0000..2d0000 MCU commands     to kaneko_toybox; the fourth 0xffff runs one
//   300000-30ffff  palette          32K entries, xGRB_555
//   310000-327fff  RAM              external SRAM words 0x08000-0x13fff
//   400000-401fff  sprite RAM
//   500000/580000  VIEW2 VRAM, chips 0 and 1 (16 KB each)
//   600000/680000  VIEW2 registers
//   700000-70001f  sprite registers
//   800001/880001  OKI M6295 0 and 1
//   900000-900039  hit calculator (gtmr reads only its random number)
//   a00000         watchdog
//   b00000-b00007  P1, P2, SYSTEM, UNK/EXTRA
//   b80000         coin lockout (byte, ignored)
//   c00000         display enable
//   d00000         MCU status, always 0
//   e00001/e80001  OKI bank select
//
// THE 68000 WAITS FOR THE MCU. MAME runs a TOYBOX command inside the write
// that triggers it, so the instruction after that write already sees the
// result. Here the command takes thousands of clocks, so the triggering write
// is not acknowledged until `mcu_busy` drops — the same thing, seen from the
// CPU. While it is held, the board hands the SRAM and ROM ports to the MCU.

`timescale 1ns/1ps
`default_nettype none

module kaneko_gtmr_bus #(
    parameter int unsigned SDR_AW    = 25,
    parameter int unsigned ROM_LINES = 16
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        map2,          // gtmr2_map inputs

    // fx68k
    input  wire [23:1] eab,
    input  wire        ASn, LDSn, UDSn, eRWn,
    input  wire [15:0] oEdb,
    output logic [15:0] iEdb,
    output logic       DTACKn,
    input  wire        cpu_space,

    // ROM, 64-bit lines from SDRAM
    output logic            rom_req,
    output logic [SDR_AW:1] rom_addr,
    input  wire             rom_ack,
    input  wire  [63:0]     rom_dout,

    // External SRAM
    output logic        ram_req,
    output logic        ram_we,
    output logic [16:0] ram_addr,
    output logic [15:0] ram_din,
    output logic [1:0]  ram_be,
    input  wire         ram_ack,
    input  wire  [15:0] ram_dout,

    // Video memories (kaneko_gtmr_vmem)
    output logic        vram0_we, vram1_we, spr_we, pal_we,
    output wire  [14:0] vmem_addr,     // word address within the selected window
    output wire  [15:0] vmem_din,
    input  wire  [15:0] vram0_q, vram1_q, spr_q, pal_q,
    input  wire         spr_hold,      // sprite RAM is being snapshotted: writes wait

    // Register files
    output logic        v2r0_we, v2r1_we, sprreg_we,
    output wire  [3:0]  reg_addr,
    output wire  [15:0] reg_din,
    input  wire  [15:0] v2r0_q, v2r1_q, sprreg_q,

    // OKIs
    output logic        oki0_we, oki1_we,
    output wire  [7:0]  oki_din,
    input  wire  [7:0]  oki0_dout, oki1_dout,
    output logic        okib0_we, okib1_we,   // bank select, data on oki_din

    // TOYBOX
    output logic        mcu_com_we,
    output wire  [1:0]  mcu_com_sel,
    output wire  [15:0] mcu_com_din,
    output wire  [1:0]  mcu_com_be,
    input  wire         mcu_busy,

    // Hit calculator
    output logic        hit_we,
    output wire  [5:0]  hit_addr,
    input  wire  [15:0] hit_q,

    // Inputs, already in the PCB's active-low form
    input  wire [15:0]  in_p1, in_p2, in_sys, in_unk,

    output logic [15:0] disp_enable,
    output logic        unmapped_hit
);

    wire [23:1] a  = eab;
    wire        as = ~ASn && !cpu_space;
    wire        ds = ~LDSn | ~UDSn;
    wire        wr = ~eRWn;

    // ------------------------------------------------------------- decode
    wire sel_wheel = (a[23:1] == 23'h07ffff);
    wire sel_rom   = (a[23:20] == 4'h0) && !sel_wheel;
    wire sel_wram  = (a[23:16] == 8'h10);
    wire sel_mram  = (a[23:16] == 8'h20);
    wire sel_com   = (a[23:16] >= 8'h2a) && (a[23:16] <= 8'h2d) && (a[15:1] == 15'd0);
    wire sel_pal   = (a[23:16] == 8'h30);
    // 310000-327fff: 0x18000 bytes. a[23:15] runs 0x062..0x064.
    wire sel_xram  = (a[23:15] >= 9'h062) && (a[23:15] <= 9'h064);
    wire sel_spr   = (a[23:13] == 11'h200);                 // 400000-401fff
    wire sel_v2w0  = (a[23:14] == 10'h140);                 // 500000-503fff
    wire sel_v2w1  = (a[23:14] == 10'h160);                 // 580000-583fff
    wire sel_v2r0  = (a[23:4]  == 20'h60000);               // 600000-60000f
    wire sel_v2r1  = (a[23:5]  == 19'h34000);               // 680000-68001f
    wire sel_sprr  = (a[23:5]  == 19'h38000);               // 700000-70001f
    wire sel_oki0  = (a[23:1]  == 23'h400000);              // 800000/1
    wire sel_oki1  = (a[23:1]  == 23'h440000);              // 880000/1
    wire sel_hit   = (a[23:6]  == 18'h24000);               // 900000-90003f
    wire sel_wdog  = (a[23:1]  == 23'h500000);              // a00000
    wire sel_in    = (a[23:3]  == 21'h160000);              // b00000-b00007
    wire sel_coin  = (a[23:1]  == 23'h5c0000);              // b80000
    wire sel_disp  = (a[23:1]  == 23'h600000);              // c00000
    wire sel_mstat = (a[23:1]  == 23'h680000);              // d00000
    wire sel_okb0  = (a[23:1]  == 23'h700000);              // e00000/1
    wire sel_okb1  = (a[23:1]  == 23'h740000);              // e80000/1

    wire sel_ext   = sel_mram | sel_xram;
    wire decoded   = sel_wheel | sel_rom | sel_wram | sel_mram | sel_com | sel_pal
                   | sel_xram | sel_spr | sel_v2w0 | sel_v2w1 | sel_v2r0 | sel_v2r1
                   | sel_sprr | sel_oki0 | sel_oki1 | sel_hit | sel_wdog | sel_in
                   | sel_coin | sel_disp | sel_mstat | sel_okb0 | sel_okb1;

    // ------------------------------------------------------- work RAM
    // 64 KB, byte-wide halves so the byte strobes infer as block-RAM byte
    // enables. Read registered: the data is on iEdb the cycle after the
    // address, long before fx68k samples it.
    logic [7:0] wram_hi [0:32767];
    logic [7:0] wram_lo [0:32767];
    logic [7:0] wram_qh, wram_ql;
    wire [14:0] wram_a = a[15:1];
    always_ff @(posedge clk) begin
        if (as && ds && sel_wram && wr && ~UDSn) wram_hi[wram_a] <= oEdb[15:8];
        if (as && ds && sel_wram && wr && ~LDSn) wram_lo[wram_a] <= oEdb[7:0];
        wram_qh <= wram_hi[wram_a];
        wram_ql <= wram_lo[wram_a];
    end

    // ------------------------------------------------------ simple outputs
    assign vmem_addr   = a[15:1];
    assign vmem_din    = oEdb;
    assign reg_addr    = a[4:1];
    assign reg_din     = oEdb;
    assign oki_din     = oEdb[7:0];
    assign mcu_com_sel = 2'(a[17:16] - 2'd2);     // 2a->0, 2b->1, 2c->2, 2d->3
    assign mcu_com_din = oEdb;
    assign mcu_com_be  = {~UDSn, ~LDSn};
    assign hit_addr    = a[6:1];

    // SRAM word address is simply a[17:1] for both windows: 200000-20ffff
    // gives 0x00000-0x07fff and 310000-327fff gives 0x08000-0x13fff.
    wire [16:0] ext_addr = a[17:1];

    // ---------------------------------------------------------- the cache
    // As kaneko_bus: direct-mapped, 64-bit lines, ROM at SDRAM word 0.
    localparam int unsigned IDXW  = $clog2(ROM_LINES);
    localparam int unsigned TAGLO = 3 + IDXW;
    logic [63:0]          cdata  [0:ROM_LINES-1];
    logic [SDR_AW:TAGLO]  ctag   [0:ROM_LINES-1];
    logic [ROM_LINES-1:0] cvalid;
    wire [SDR_AW:1]   rom_wa   = SDR_AW'(a[23:1]);
    wire [IDXW-1:0]   cidx     = rom_wa[TAGLO-1:3];
    wire              line_hit = cvalid[cidx] && (ctag[cidx] == rom_wa[SDR_AW:TAGLO]);
    wire [1:0]        lane     = rom_wa[2:1];
    wire [15:0]       line_word  = cdata[cidx][{lane, 4'd0} +: 16];
    wire [15:0]       burst_word = rom_dout[{lane, 4'd0} +: 16];

    // ---------------------------------------------------------- the FSM
    typedef enum logic [2:0] { S_IDLE, S_ROM, S_RAM, S_MCU, S_PALRD, S_DONE } state_t;
    state_t state;
    logic [15:0] hold_word;     // ROM or SRAM data, held for the rest of the cycle
    logic [1:0]  mcu_wait;

    always_ff @(posedge clk) begin
        vram0_we <= 1'b0; vram1_we <= 1'b0; spr_we <= 1'b0; pal_we <= 1'b0;
        v2r0_we  <= 1'b0; v2r1_we  <= 1'b0; sprreg_we <= 1'b0;
        oki0_we  <= 1'b0; oki1_we  <= 1'b0; okib0_we <= 1'b0; okib1_we <= 1'b0;
        mcu_com_we <= 1'b0; hit_we <= 1'b0;
        unmapped_hit <= 1'b0;

        if (rst) begin
            state       <= S_IDLE;
            DTACKn      <= 1'b1;
            rom_req     <= 1'b0;
            ram_req     <= 1'b0;
            cvalid      <= '0;
            disp_enable <= 16'h0001;   // MAME: enabled until a game says otherwise
        end else begin
            case (state)
                S_IDLE: begin
                    DTACKn <= 1'b1;
                    if (as && ds) begin
                        if (sel_rom) begin
                            if (line_hit) begin
                                hold_word <= {line_word[7:0], line_word[15:8]};
                                DTACKn    <= 1'b0;
                                state     <= S_DONE;
                            end else begin
                                rom_addr <= {rom_wa[SDR_AW:3], 2'b00};
                                rom_req  <= 1'b1;
                                state    <= S_ROM;
                            end
                        end else if (sel_ext) begin
                            ram_req  <= 1'b1;
                            ram_we   <= wr;
                            ram_addr <= ext_addr;
                            ram_din  <= oEdb;
                            ram_be   <= {~UDSn, ~LDSn};
                            state    <= S_RAM;
                        end else if (sel_pal && !wr) begin
                            // The palette's read port is shared with the
                            // video (kaneko_gtmr_vmem); four clocks covers a
                            // video read landing on the CPU's turn.
                            mcu_wait <= 2'd3;
                            state    <= S_PALRD;
                        end else if (sel_spr && wr && spr_hold) begin
                            // Wait for the snapshot to finish; the cycle is
                            // re-evaluated next clock.
                        end else begin
                            if (wr) begin
                                vram0_we   <= sel_v2w0;
                                vram1_we   <= sel_v2w1;
                                spr_we     <= sel_spr;
                                pal_we     <= sel_pal;
                                v2r0_we    <= sel_v2r0;
                                v2r1_we    <= sel_v2r1;
                                sprreg_we  <= sel_sprr;
                                oki0_we    <= sel_oki0 && ~LDSn;
                                oki1_we    <= sel_oki1 && ~LDSn;
                                okib0_we   <= sel_okb0 && ~LDSn;
                                okib1_we   <= sel_okb1 && ~LDSn;
                                mcu_com_we <= sel_com;
                                hit_we     <= sel_hit;
                                if (sel_disp) begin
                                    if (~UDSn) disp_enable[15:8] <= oEdb[15:8];
                                    if (~LDSn) disp_enable[7:0]  <= oEdb[7:0];
                                end
                            end
                            if (!decoded) unmapped_hit <= 1'b1;
                            if (wr && sel_com) begin
                                // Only the write that completes the 0xffff
                                // quartet starts a command, but holding every
                                // command write for two clocks costs nothing
                                // and keeps one path through here.
                                mcu_wait <= 2'd2;
                                state    <= S_MCU;
                            end else begin
                                DTACKn <= 1'b0;
                                state  <= S_DONE;
                            end
                        end
                    end
                end

                S_ROM: if (rom_ack) begin
                    rom_req      <= 1'b0;
                    cdata[cidx]  <= rom_dout;
                    ctag[cidx]   <= rom_wa[SDR_AW:TAGLO];
                    cvalid[cidx] <= 1'b1;
                    hold_word    <= {burst_word[7:0], burst_word[15:8]};
                    DTACKn       <= 1'b0;
                    state        <= S_DONE;
                end

                S_RAM: if (ram_ack) begin
                    ram_req   <= 1'b0;
                    hold_word <= ram_dout;
                    DTACKn    <= 1'b0;
                    state     <= S_DONE;
                end

                // kaneko_toybox raises busy the clock after the strobe; give it
                // two before looking.
                S_MCU: begin
                    if (mcu_wait != 2'd0)  mcu_wait <= mcu_wait - 2'd1;
                    else if (!mcu_busy) begin
                        DTACKn <= 1'b0;
                        state  <= S_DONE;
                    end
                end

                S_PALRD: begin
                    if (mcu_wait != 2'd0) mcu_wait <= mcu_wait - 2'd1;
                    else begin
                        DTACKn <= 1'b0;
                        state  <= S_DONE;
                    end
                end

                S_DONE: begin
                    DTACKn <= 1'b0;
                    if (!as) begin
                        DTACKn <= 1'b1;
                        state  <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------- read mux
    // UNMAPPED READS RETURN ZERO. MAME's default unmap value for this space is
    // 0 and gtmr_map does not raise it; the bus trace is the arbiter.
    wire [15:0] wheel_q = map2 ? 16'hffff : 16'h00ff;
    always_comb begin
        if      (sel_rom || sel_ext) iEdb = hold_word;
        else if (sel_wram)  iEdb = {wram_qh, wram_ql};
        else if (sel_v2w0)  iEdb = vram0_q;
        else if (sel_v2w1)  iEdb = vram1_q;
        else if (sel_spr)   iEdb = spr_q;
        else if (sel_pal)   iEdb = pal_q;
        else if (sel_v2r0)  iEdb = v2r0_q;
        else if (sel_v2r1)  iEdb = v2r1_q;
        else if (sel_sprr)  iEdb = sprreg_q;
        else if (sel_oki0)  iEdb = {8'h00, oki0_dout};
        else if (sel_oki1)  iEdb = {8'h00, oki1_dout};
        else if (sel_hit)   iEdb = hit_q;
        else if (sel_wheel) iEdb = wheel_q;
        else if (sel_in)    iEdb = (a[2:1] == 2'd0) ? in_p1
                                 : (a[2:1] == 2'd1) ? in_p2
                                 : (a[2:1] == 2'd2) ? in_sys : in_unk;
        else                iEdb = 16'h0000;   // incl. watchdog, MCU status, disp
    end

endmodule

`default_nettype wire
