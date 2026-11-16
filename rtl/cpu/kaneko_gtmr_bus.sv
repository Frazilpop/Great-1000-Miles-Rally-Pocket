// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the gtmr board's 68000 bus
//
// gtmr_map and gtmr2_map from kaneko16.cpp. The two differ only in what the
// input words and the wheel read return, so one decoder serves both and
// `map2` picks the input wiring.
//
//   000000-0ffffd  ROM              SDRAM through a line cache with prefetch
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
    parameter int unsigned ROM_SETS  = 256
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
    input  wire         spr_soon,      // the line before the snapshot starts

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
    output logic        unmapped_hit,

    // Save states (kaneko_state): idle with nothing asked of the ROM or the
    // SRAM; no prefetch started while the 68000 is parked or frozen; the
    // line cache emptied; the display enable put back.
    output wire         idle,
    input  wire         pf_stop,
    input  wire         cinval,
    input  wire         de_we,
    input  wire  [15:0] de_d
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
    // The arcade's 68000 reads its ROM with no wait. Here a line not in the
    // cache costs an SDRAM burst, and in a race the program and its tables
    // stream through: with sixteen lines one read in five missed (MAME's
    // fetches, gtmrusa's race), enough to lose a fifth of a frame. So: 512
    // 64-bit lines in block RAM, two ways of 256 sets, and a tagged next-line
    // prefetch. A line filled by a miss asks for the line after it; so does
    // the first hit on a line the prefetch filled, so a run of code or a table
    // read in order stays a line ahead. The prefetch runs while the 68000
    // goes on with hits and every other device; only a miss, or a TOYBOX
    // command (which takes the ROM port), waits for it to land.
    //
    // Two ways because one wasn't enough: on gtmrusa's heaviest frames a loop
    // at 0x0c000 and the table it reads at 0x0e000 fall on the same sets, and
    // with the lines direct-mapped they put each other out, a miss in every
    // dozen reads (1,300 a frame). Each set keeps the way used last; a fill
    // takes an empty way, else the other one.
    //
    // ROM is 000000-0fffff, so a line is word address [19:3] of it: a set
    // and a tag. Each way's tag and data are one word of its `cmem`, both read
    // on the 68000's address every clock: the address is out a clock or more
    // before AS, so on the clock the FSM sees the cycle, cq0/cq1 already hold
    // the set. A second copy of the tags (`ptags`) is read by the prefetch, to
    // leave a line already there alone. A clock that writes a RAM makes the
    // next q unsure (`cq_ok`, `pq_ok`): it is read again.
    localparam int unsigned IDXW  = $clog2(ROM_SETS);
    localparam int unsigned TAGLO = 3 + IDXW;
    localparam int unsigned TAGW  = 20 - TAGLO;
    typedef logic [19:3] line_t;

    (* ramstyle = "M10K, no_rw_check" *) logic [TAGW+63:0] cmem0  [0:ROM_SETS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [TAGW+63:0] cmem1  [0:ROM_SETS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [TAGW-1:0]  ptags0 [0:ROM_SETS-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [TAGW-1:0]  ptags1 [0:ROM_SETS-1];
    logic [ROM_SETS-1:0]  cvalid0, cvalid1;  // the way holds what its tag says
    logic [ROM_SETS-1:0]  cpf0, cpf1;        // filled by the prefetch, not yet hit
    logic [ROM_SETS-1:0]  lru;               // the way a fill takes if both are full

    wire  [19:3]          cpu_line = a[19:3];
    wire  [IDXW-1:0]      cidx     = cpu_line[TAGLO-1:3];
    logic [TAGW+63:0]     cq0, cq1;
    line_t                cq_line;     // the line cq0/cq1 were read for
    logic                 cq_ok, cq_v0, cq_v1, cq_p0, cq_p1, cq_lru;

    // a fill: by a miss (demand) or the prefetch, written as it lands
    logic                 c_we, c_wway;
    logic [IDXW-1:0]      c_widx;
    logic [TAGW+63:0]     c_wdata;
    logic                 c_wpf;

    // the prefetch: a line it wants, then its tag read, then the fill
    logic                 pf_want, pf_busy, pq_ok, pq_v0, pq_v1, pq_lru;
    line_t                pf_line;
    logic [TAGW-1:0]      pq0, pq1;
    logic                 req_d;       // rom_req a clock ago: a request's edge needs a low clock
    line_t                pf_wline;    // the line in flight
    logic                 pf_wway, dem_way;
    wire  [IDXW-1:0]      pidx     = pf_line[TAGLO-1:3];

    always_ff @(posedge clk) begin
        if (c_we && !c_wway) begin
            cmem0[c_widx]  <= c_wdata;
            ptags0[c_widx] <= c_wdata[TAGW+63:64];
        end
        if (c_we && c_wway) begin
            cmem1[c_widx]  <= c_wdata;
            ptags1[c_widx] <= c_wdata[TAGW+63:64];
        end
        cq0     <= cmem0[cidx];
        cq1     <= cmem1[cidx];
        cq_line <= cpu_line;
        cq_v0   <= cvalid0[cidx];
        cq_v1   <= cvalid1[cidx];
        cq_p0   <= cpf0[cidx];
        cq_p1   <= cpf1[cidx];
        cq_lru  <= lru[cidx];
        cq_ok   <= !c_we && !cinval;
        pq0     <= ptags0[pidx];
        pq1     <= ptags1[pidx];
        pq_v0   <= cvalid0[pidx];
        pq_v1   <= cvalid1[pidx];
        pq_lru  <= lru[pidx];
        pq_ok   <= !c_we && !cinval;
    end

    wire [1:0]    lane       = a[2:1];
    wire          cq_here    = cq_ok && (cq_line == cpu_line);
    wire          hit0       = cq_v0 && (cq0[TAGW+63:64] == cpu_line[19:TAGLO]);
    wire          hit1       = cq_v1 && (cq1[TAGW+63:64] == cpu_line[19:TAGLO]);
    wire          line_hit   = cq_here && (hit0 || hit1);
    wire          line_miss  = cq_here && !(hit0 || hit1);
    wire [63:0]   hit_data   = hit0 ? cq0[63:0] : cq1[63:0];
    wire          hit_pf     = hit0 ? cq_p0 : cq_p1;
    wire [15:0]   line_word  = hit_data[{lane, 4'd0} +: 16];
    wire [15:0]   burst_word = rom_dout[{lane, 4'd0} +: 16];
    wire [SDR_AW:1] line_wa  = SDR_AW'({cpu_line, 2'b00});
    // the way a miss fills: an empty one, else the one not used last
    wire          dem_vict   = !cq_v0 ? 1'b0 : !cq_v1 ? 1'b1 : cq_lru;

    // the line after `l`, if there is one in ROM
    function automatic logic [17:0] next_line(input line_t l);
        return {1'b0, l} + 18'd1;
    endfunction
    wire [17:0]   cpu_next   = next_line(cpu_line);

    // the prefetch's tag read: pq0/pq1 hold pf_line's set when pq_line says so
    line_t        pq_line;
    always_ff @(posedge clk) pq_line <= pf_line;
    wire          pq_here    = pq_ok && (pq_line == pf_line);
    wire          pf_there   = pq_here && ((pq_v0 && (pq0 == pf_line[19:TAGLO]))
                                        || (pq_v1 && (pq1 == pf_line[19:TAGLO])));
    wire          pf_vict    = !pq_v0 ? 1'b0 : !pq_v1 ? 1'b1 : pq_lru;

    // ---------------------------------------------------------- the FSM
    typedef enum logic [2:0] { S_IDLE, S_ROM, S_RAM, S_MCU, S_PALRD, S_WDS, S_DONE } state_t;
    state_t state;
    assign idle = (state == S_IDLE) && !rom_req && !ram_req;

    // A miss goes out once the line's q is sure, the port is free and the
    // last request has been low a clock.
    wire port_free = !rom_req && !req_d && !pf_busy;
    wire dem_go    = (state == S_IDLE) && as && ds && sel_rom && line_miss && port_free;
    // The prefetch may go out alongside anything but a ROM read or a TOYBOX
    // command, which want the port themselves; nor in the clock that empties
    // the cache, the let-go, where pf_stop has just fallen and a want left by
    // the load's own run of the 68000 is not yet dropped: it went out in one
    // run of a save state and not the other, and the first miss after the
    // let-go waited 9 clocks for it (16 Nov).
    wire pf_go     = pf_want && pq_here && !pf_there && port_free && !pf_stop && !mcu_busy && !cinval
                   && (state == S_DONE || state == S_RAM || state == S_PALRD
                       || (state == S_IDLE && !(as && ds && (sel_rom || (wr && sel_com)))));
    // A WRITE IS ANSWERED ON AS. The 68000 drives a write's data strobes a
    // clock after AS and samples DTACK in S4; answered on AS and DS, every
    // write took a wait state the arcade's on-chip memories don't (a cycle of
    // 15 clocks, not 12: some 4,500 writes a frame in a race, work RAM and
    // sprite RAM mostly). So a write to anything that takes it at once gets
    // DTACK on AS and is done when the strobes come (S_WDS). Not the SRAM, a
    // TOYBOX command or ROM, which have waits of their own, nor sprite RAM
    // from the line before its snapshot, so a write can't fall into the copy.
    wire wr_fast = !sel_rom && !sel_ext && !sel_com && !(sel_spr && (spr_hold || spr_soon));
    // the strobes of a write that needs nothing else: from S_IDLE (a write
    // that went the slow way) or S_WDS
    wire wr_now  = as && ds && wr
                 && ((state == S_WDS)
                     || (state == S_IDLE && !sel_rom && !sel_ext && !sel_com
                         && !(sel_spr && spr_hold)));
    logic [15:0] hold_word;     // ROM or SRAM data, held for the rest of the cycle
    logic [1:0]  mcu_wait;

    always_ff @(posedge clk) begin
        vram0_we <= 1'b0; vram1_we <= 1'b0; spr_we <= 1'b0; pal_we <= 1'b0;
        v2r0_we  <= 1'b0; v2r1_we  <= 1'b0; sprreg_we <= 1'b0;
        oki0_we  <= 1'b0; oki1_we  <= 1'b0; okib0_we <= 1'b0; okib1_we <= 1'b0;
        mcu_com_we <= 1'b0; hit_we <= 1'b0;
        unmapped_hit <= 1'b0;

        req_d <= rom_req;
        c_we  <= 1'b0;

        if (wr_now) begin
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
            hit_we     <= sel_hit;
            if (sel_disp) begin
                if (~UDSn) disp_enable[15:8] <= oEdb[15:8];
                if (~LDSn) disp_enable[7:0]  <= oEdb[7:0];
            end
            if (!decoded) unmapped_hit <= 1'b1;
        end

        if (rst) begin
            state       <= S_IDLE;
            DTACKn      <= 1'b1;
            rom_req     <= 1'b0;
            ram_req     <= 1'b0;
            cvalid0     <= '0;
            cvalid1     <= '0;
            cpf0        <= '0;
            cpf1        <= '0;
            lru         <= '0;
            pf_want     <= 1'b0;
            pf_busy     <= 1'b0;
            disp_enable <= 16'h0001;   // MAME: enabled until a game says otherwise
        end else begin
            // the prefetch: drop a line already there, else fetch it (before
            // the FSM, so a line it asks for this clock wins over the drop)
            if (pf_want && pf_there) pf_want <= 1'b0;
            if (pf_go) begin
                rom_addr <= SDR_AW'({pf_line, 2'b00});
                rom_req  <= 1'b1;
                pf_busy  <= 1'b1;
                pf_wline <= pf_line;
                pf_wway  <= pf_vict;
                pf_want  <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    DTACKn <= 1'b1;
                    if (as && wr && !ds && wr_fast) begin
                        DTACKn <= 1'b0;
                        state  <= S_WDS;
                    end else if (as && ds) begin
                        if (sel_rom) begin
                            // a hit answers at once; a miss waits for the
                            // port; an unsure q is read again next clock
                            if (line_hit) begin
                                hold_word <= {line_word[7:0], line_word[15:8]};
                                DTACKn    <= 1'b0;
                                state     <= S_DONE;
                                lru[cidx] <= hit0;     // the other way next
                                if (hit_pf) begin
                                    if (hit0) cpf0[cidx] <= 1'b0;
                                    else      cpf1[cidx] <= 1'b0;
                                    if (!cpu_next[17]) begin pf_want <= 1'b1; pf_line <= cpu_next[16:0]; end
                                end
                            end else if (dem_go) begin
                                rom_addr <= line_wa;
                                rom_req  <= 1'b1;
                                dem_way  <= dem_vict;
                                state    <= S_ROM;
                            end
                        end else if (wr && sel_com && (pf_busy || rom_req)) begin
                            // a TOYBOX command takes the ROM port: let the
                            // prefetch land first
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
                            // (a write's strobes are wr_now's, above)
                            if (wr) mcu_com_we <= sel_com;
                            if (!wr && !decoded) unmapped_hit <= 1'b1;
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
                    rom_req   <= 1'b0;
                    c_we      <= 1'b1;
                    c_widx    <= cidx;
                    c_wway    <= dem_way;
                    c_wdata   <= {cpu_line[19:TAGLO], rom_dout};
                    c_wpf     <= 1'b0;
                    hold_word <= {burst_word[7:0], burst_word[15:8]};
                    DTACKn    <= 1'b0;
                    state     <= S_DONE;
                    if (!cpu_next[17]) begin pf_want <= 1'b1; pf_line <= cpu_next[16:0]; end
                end

                // a write answered on AS: its strobes (wr_now) end it
                S_WDS: begin
                    DTACKn <= 1'b0;
                    if (!as) begin
                        DTACKn <= 1'b1;
                        state  <= S_IDLE;
                    end else if (ds) state <= S_DONE;
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

            if (pf_busy && rom_ack) begin
                rom_req  <= 1'b0;
                pf_busy  <= 1'b0;
                c_we     <= 1'b1;
                c_widx   <= pf_wline[TAGLO-1:3];
                c_wway   <= pf_wway;
                c_wdata  <= {pf_wline[19:TAGLO], rom_dout};
                c_wpf    <= 1'b1;
            end
            // a fill lands with its RAM write
            if (c_we) begin
                if (c_wway) begin cvalid1[c_widx] <= 1'b1; cpf1[c_widx] <= c_wpf; end
                else        begin cvalid0[c_widx] <= 1'b1; cpf0[c_widx] <= c_wpf; end
                lru[c_widx] <= !c_wway;
            end
            // (lru too: a save state's two runs must choose the same ways)
            if (cinval) begin
                cvalid0 <= '0; cvalid1 <= '0; cpf0 <= '0; cpf1 <= '0; lru <= '0;
                pf_want <= 1'b0;
            end
            if (de_we)  disp_enable <= de_d;
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
