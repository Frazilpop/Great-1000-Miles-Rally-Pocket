// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the gtmr board (Great 1000 Miles Rally family)
//
// Platform-neutral: no pins, no framework. The Pocket shell (pocket/) and
// the simulation harness (sim/gtmr/) both host this module.
//
// What is on the board (kaneko16.cpp, gtmr() machine config):
//
//   68000 @ 16 MHz        fx68k, clock enables from the 48 MHz core clock
//   VIEW2 x 2             upstream's line renderer, four layers
//   KC-002                kaneko_kc002, bitmap in the two PSRAM chips
//   TOYBOX MCU            kaneko_toybox, MAME's simulation as RTL
//   93C46                 64 x 16, reached only through the TOYBOX
//   OKI M6295 x 2         jt6295 at 16 MHz / 8, PIN7 low
//   palette               32K x xGRB_555
//
// SDRAM ports: 0-3 tile layers, 4 68000 ROM (the TOYBOX
// borrows it while the 68000 waits on it), 5 OKI 0, 6 OKI 1, 7-8 sprite ROM.

`timescale 1ns/1ps
`default_nettype none

module kaneko_gtmr #(
    parameter int unsigned SDR_AW = 25,
    parameter int unsigned NP     = 9
)(
    input  wire        clk,            // 48 MHz
    input  wire        rst,            // core reset (OSD/host); the board adds !rom_loaded
    input  wire        rst_por,        // power-on only: the EEPROM survives rst

    input  wire [2:0]  game,           // 0 gtmr, 1 gtmre, 2 gtmrusa, 3 gtmr2, 4 gtmr2u

    // ROM read ports (SDRAM controller, slow side)
    output wire [NP-1:0]             rom_req,
    output wire [NP-1:0][SDR_AW:1]   rom_addr,
    input  wire [NP-1:0]             rom_ack,
    input  wire [NP-1:0][63:0]       rom_dout,

    // Loader snoop
    input  wire        dl_wr,
    input  wire [24:1] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        rom_loaded,

    // External SRAM
    output wire        ram_req,
    output wire        ram_we,
    output wire [16:0] ram_addr,
    output wire [15:0] ram_din,
    output wire [1:0]  ram_be,
    input  wire        ram_ack,
    input  wire [15:0] ram_dout,

    // Sprite bitmap, one buffer per PSRAM chip
    output wire        fb0_req,
    output wire        fb0_we,
    output wire [21:0] fb0_addr,
    output wire [255:0] fb0_wdata,
    output wire [15:0] fb0_wmask,
    input  wire        fb0_ack,
    input  wire [255:0] fb0_rdata,

    output wire        fb1_req,
    output wire        fb1_we,
    output wire [21:0] fb1_addr,
    output wire [255:0] fb1_wdata,
    output wire [15:0] fb1_wmask,
    input  wire        fb1_ack,
    input  wire [255:0] fb1_rdata,

    // Video
    output wire        ce_pix,
    output wire        hs, vs, hblank, vblank,
    output wire [7:0]  r, g, b,

    // Audio
    output wire [15:0] snd,

    // Inputs
    input  wire [7:0]  p1, p2,
    input  wire [1:0]  coin, start,
    input  wire        service, test,
    input  wire [15:0] dsw,

    // Freezes the game: the 68000 stops between bus cycles and the OKIs stop
    // where they are. Video keeps running, so the picture holds.
    input  wire        pause,

    // Keeps the game from drawing its speed lines (see "Speed lines" below).
    input  wire        hide_speed_lines,

    // EEPROM backup
    input  wire [5:0]  nv_addr,
    input  wire [15:0] nv_din,
    input  wire        nv_we,
    output wire [15:0] nv_dout,
    output wire        nv_dirty,
    input  wire        nv_dirty_clr,

    // Diagnostics for the platform's overlay: peaks since
    // diag_clr or reset. Nothing on the board depends on them.
    input  wire        diag_clr,
    output wire [31:0] diag_wait_max,      // longest 68000 bus cycle, clocks AS low
    output wire [23:0] diag_wait_addr,     // its byte address
    output wire [15:0] diag_idle_min,      // least spare 68000 time in a frame, clocks / 64
    output wire [15:0] diag_lag_frames,    // frames with no spare 68000 time at all
    output wire [15:0] diag_draw_max,      // longest KC-002 draw, clocks / 64
    output wire [7:0]  diag_spr_overruns,  // KC-002 draws that missed their swap

    // Save states: kaneko_state's window (see there)
    input  wire        ss_save,
    input  wire        ss_go,
    output wire [1:0]  ss_status,
    output wire        ss_loading,
    output wire        ss_refused,
    input  wire [17:0] ss_addr,
    input  wire        ss_rd,
    output wire [15:0] ss_do,
    input  wire        ss_wr,
    input  wire [15:0] ss_di
);

// ================================================================ game table
wire map2      = (game >= 3'd3);          // gtmr2_map and its ROM sizes
wire table_alt = (game != 3'd0);          // gtmre, gtmrusa, gtmr2: TABLE_ALT

// SDRAM regions, word addresses
localparam [SDR_AW:1] W_MAINCPU = SDR_AW'(25'h0000000);
localparam [SDR_AW:1] W_MCUDATA = SDR_AW'(25'h0080000);    // byte 0x0100000
localparam [SDR_AW:1] W_VIEW2   = SDR_AW'(25'h0100000);    // byte 0x0200000
localparam [SDR_AW:1] W_KANSPR  = SDR_AW'(25'h0380000);    // byte 0x0700000
localparam [SDR_AW:1] W_OKI1    = SDR_AW'(25'h0800000);    // byte 0x1000000
localparam [SDR_AW:1] W_OKI2    = SDR_AW'(25'h0880000);    // byte 0x1100000

// ================================================================ clocks
// One 24-clock counter sets every phase on the board: the OKIs' 2 MHz
// (oki_div 0), the pixel's 6 MHz (oki_div 0, 8, 16) and the 68000's three
// clocks a phase pair (cpu_ph, cleared at 23 so it can never drift from
// it). A frame is 33,792 of them, so the raster comes back to the same
// phase every frame, which is what lets a save state leave the dividers out.
reg [4:0] oki_div;
always @(posedge clk) oki_div <= (oki_div == 5'd23) ? 5'd0 : oki_div + 5'd1;

// Pixel: 48 / 8 = 6 MHz, as upstream. Everything video steps on it.
wire [2:0] ce_div   = oki_div[2:0];
wire       ce_pix_i = (ce_div == 3'd0);

// ================================================================ resets
// Held until the ROM is in SDRAM: fetching earlier reads whatever the memory
// powered up with as reset vectors.
//
// A load resets what it then writes (ss_sysrst), and holds the 68000 in
// extReset, but not the OKIs, whose whole state it writes by their chain, nor
// the 68000's register file (pwrUp clears it).
wire cpu_rst_real = rst | ~rom_loaded;
wire ss_sysrst, ss_rst68;
wire cpu_rst = cpu_rst_real | ss_sysrst;

// The raster lets go of reset only on one phase of the 24-clock counter, so
// on every launch hcnt steps at the same oki_div and a state's raster
// position lines up with the 68000's and the OKIs' phase. The phase is 8,
// a pixel clock, where the board harness has always released rst: there
// this changes nothing.
reg  rst_v_hold;
always @(posedge clk)
    if (rst)                  rst_v_hold <= 1'b1;
    else if (oki_div == 5'd8) rst_v_hold <= 1'b0;
wire rst_v = rst | (rst_v_hold & (oki_div != 5'd8));

// ================================================================ clocks (68000, OKI)
// 68000: 16 MHz from 48 is three clocks per CPU clock, one phase enable on
// each of two of them. fx68k is fully synchronous to `clk` and only cares
// that the phases alternate; the uneven spacing is invisible to it.
//
// Pause withholds both enables, so fx68k simply stands still. It takes hold
// only while AS is high, so no device is left part-way through a bus cycle
// (the 68000 is never more than one bus cycle from AS going high), and lets
// go within a phase pair. Never in reset: fx68k needs its enables to come out
// of one. It changes only at cpu_ph 2, so the last enable before a hold is a
// phi2 and the first after it a phi1: a hold landing between the two would
// give the 68000 two enables of the same phase.
wire      ASn, LDSn, UDSn, eRWn, DTACKn;
reg [1:0] cpu_ph;
reg       cpu_hold;
always @(posedge clk) begin
    cpu_ph <= (cpu_ph == 2'd2 || oki_div == 5'd23) ? 2'd0 : cpu_ph + 2'd1;
    if (cpu_ph == 2'd2) begin
        if (!pause || cpu_rst) cpu_hold <= 1'b0;
        else if (ASn)          cpu_hold <= 1'b1;
    end
end
// A save state's freeze withholds them as well, but for a load's own runs of
// the 68000 alone (ss_run68). The freeze rises and falls on oki_div 14, a
// cpu_ph 2, so here too the last enable is a phi2 and the next a phi1.
wire ss_freeze, ss_run68, ss_okirun;
wire cpu_stop = cpu_hold | (ss_freeze & ~ss_run68);
wire enPhi1 = (cpu_ph == 2'd0) & ~cpu_stop;
wire enPhi2 = (cpu_ph == 2'd1) & ~cpu_stop;

// OKIs: 16 MHz / 8 = 2 MHz, i.e. 48 / 24 (oki_div, above).
wire oki_cen = (oki_div == 5'd0) & ~cpu_hold & ~(ss_freeze & ~ss_okirun);

// ================================================================ timing
wire [9:0] hcnt, vcnt;
wire [8:0] screen_x, screen_y;
wire       hs_i, vs_i, hb_i, vb_i, de_i, vbl_rise;

// 320 x 240 from line 0, the gtmr machine config's visible area.
kaneko_video_timing u_timing
(
    .clk(clk), .rst(rst_v), .ce_pix(ce_pix_i),
    .h_vis(10'd320), .v_vis(10'd240),
    .v_start(10'd0), .h_sync_start(10'd336), .h_start(9'd0),
    .hcnt(hcnt), .vcnt(vcnt), .screen_x(screen_x), .screen_y(screen_y),
    .hsync(hs_i), .vsync(vs_i), .hblank(hb_i), .vblank(vb_i), .de(de_i),
    .vblank_rise(vbl_rise)
);

// ================================================================ 68000
wire [15:0] oEdb, iEdb, bus_iEdb;
wire [23:1] eab;
wire [2:0]  cpu_fc;
wire [2:0]  cpu_ipl_n;
wire        cpu_vpa_n, cpu_iack;

wire        fx_atstart, fx_atdisp, fx_busidle;
wire [9:0]  fx_uaddr;
wire [31:0] fx_regq, fx_pc, fx_regd;
wire [15:0] fx_sr, fx_misc, fx_grpdisp, fx_clk;
wire [4:0]  fx_rega;
wire        fx_regwe, fx_srwe, fx_miscwe, fx_grpwe, fx_clkwe;
wire [15:0] fx_srd, fx_miscd, fx_grpd, fx_clkd;
wire        ss_park68, ss_parkdisp68;

fx68k u_cpu
(
    .clk(clk), .HALTn(1'b1),
    .extReset(cpu_rst_real | ss_rst68), .pwrUp(cpu_rst_real),
    .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
    .E(), .VMAn(), .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(DTACKn), .VPAn(cpu_vpa_n), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(cpu_ipl_n[0]), .IPL1n(cpu_ipl_n[1]), .IPL2n(cpu_ipl_n[2]),
    .iEdb(iEdb), .oEdb(oEdb), .eab(eab),
    .ssPark(ss_park68), .ssParkDisp(ss_parkdisp68),
    .ssAtStart(fx_atstart), .ssAtDisp(fx_atdisp), .ssBusIdle(fx_busidle),
    .ssUaddr(fx_uaddr),
    .ssRegA(fx_rega), .ssRegQ(fx_regq), .ssRegWe(fx_regwe), .ssRegD(fx_regd),
    .ssPc(fx_pc), .ssSr(fx_sr),
    .ssMisc(fx_misc), .ssGrpDisp(fx_grpdisp), .ssClk(fx_clk),
    .ssSrWe(fx_srwe), .ssSrD(fx_srd),
    .ssMiscWe(fx_miscwe), .ssMiscD(fx_miscd),
    .ssGrpWe(fx_grpwe), .ssGrpD(fx_grpd),
    .ssClkWe(fx_clkwe), .ssClkD(fx_clkd)
);

// The bus as the simulation harness traces it (tools/pocket/diff_gtmr_trace.py
// compares the result with MAME's). Nothing on the board reads these.
wire        dbg_as    /*verilator public_flat_rd*/ = ~ASn & ~cpu_iack;
wire        dbg_dtack /*verilator public_flat_rd*/ = ~DTACKn;
wire        dbg_rw    /*verilator public_flat_rd*/ = eRWn;
wire [23:1] dbg_eab   /*verilator public_flat_rd*/ = eab;
wire [15:0] dbg_dout  /*verilator public_flat_rd*/ = oEdb;
wire [15:0] dbg_din   /*verilator public_flat_rd*/ = iEdb;
wire [1:0]  dbg_ds    /*verilator public_flat_rd*/ = {~UDSn, ~LDSn};

// Scanlines of the three interrupts. MAME's values; the harness can move them
// (+define+GTMR_IRQ4_LINE=..) to test timing hypotheses against MAME.
`ifndef GTMR_IRQ4_LINE
`define GTMR_IRQ4_LINE 64
`endif
`ifndef GTMR_IRQ3_LINE
`define GTMR_IRQ3_LINE 144
`endif

// Paused, the interrupt block sees the scanline stand still, so no level is
// raised for the lines that pass: the game resumes where it stopped instead of
// taking a pile of stale interrupts back to back. Unpaused it is vcnt itself.
// A save state's freeze holds it too, the whole of a load included.
wire        irq_hold = cpu_hold | ss_freeze;
logic [9:0] vcnt_frz;
always_ff @(posedge clk) if (!irq_hold) vcnt_frz <= vcnt;
wire  [9:0] irq_vcnt = irq_hold ? vcnt_frz : vcnt;
wire  [2:0] irq_ss_q;
wire        irq_ss_we;

kaneko_irq #(.LINE_IRQ4(`GTMR_IRQ4_LINE), .LINE_IRQ3(`GTMR_IRQ3_LINE)) u_irq
(
    .clk(clk), .rst(cpu_rst),
    .vcnt(irq_vcnt),
    .fc(cpu_fc), .as(~ASn), .a_level(eab[3:1]),
    .ipl_n(cpu_ipl_n), .vpa_n(cpu_vpa_n), .iack(cpu_iack),
    .ss_q(irq_ss_q), .ss_we(irq_ss_we), .ss_d(aux_d[2:0])
);

// ================================================================ speed lines
// Once the car's speed word reaches 0xC00 the game draws streaks along the
// road: thin lines from the object "OXspdlin" in gtmr, wider patches from
// "OXspdobj" in the other sets. Each object starts them at one CMPI.W #$C00,D0
// and ends them at another. Hiding them answers those two instructions'
// immediate word with 0xFFFF: the speed never reaches it, so they never start,
// and any already drawn are cleared by the routine's own exit.
//
// Program-space fetches only, so a ROM check reading the same address as data
// still sees the ROM. The addresses are each set's own. The compare is
// registered: the address settles at least one clock before the 68000 can take
// the data.
logic [23:1] spdl_a0, spdl_a1;
always_comb
    case (game)
    3'd0:    begin spdl_a0 = 23'h09906 >> 1; spdl_a1 = 23'h09992 >> 1; end  // gtmr
    3'd1:    begin spdl_a0 = 23'h10854 >> 1; spdl_a1 = 23'h109a2 >> 1; end  // gtmre
    3'd2:    begin spdl_a0 = 23'h1085c >> 1; spdl_a1 = 23'h109aa >> 1; end  // gtmrusa
    3'd3:    begin spdl_a0 = 23'h1dc90 >> 1; spdl_a1 = 23'h1ded6 >> 1; end  // gtmr2
    3'd4:    begin spdl_a0 = 23'h1dcb4 >> 1; spdl_a1 = 23'h1defa >> 1; end  // gtmr2u
    default: begin spdl_a0 = '1;             spdl_a1 = '1;             end
    endcase

logic spdl_hit;
always_ff @(posedge clk)
    spdl_hit <= hide_speed_lines && (cpu_fc[1:0] == 2'b10) &&
                (eab == spdl_a0 || eab == spdl_a1);

// A load's restore answers the 68000's reset vectors from the state.
wire        ss_vec;
wire [31:0] ss_vec_sp, ss_vec_pc;
wire [15:0] vec_word = (eab[2:1] == 2'd0) ? ss_vec_sp[31:16] : (eab[2:1] == 2'd1) ? ss_vec_sp[15:0]
                     : (eab[2:1] == 2'd2) ? ss_vec_pc[31:16] : ss_vec_pc[15:0];
assign iEdb = (ss_vec && eab[23:3] == 21'd0) ? vec_word : spdl_hit ? 16'hffff : bus_iEdb;

// ================================================================ bus
wire        bus_rom_req;  wire [SDR_AW:1] bus_rom_addr;
wire        bus_ram_req, bus_ram_we;
wire [16:0] bus_ram_addr; wire [15:0] bus_ram_din; wire [1:0] bus_ram_be;

wire        vram0_we, vram1_we, spr_we, pal_we, spr_hold;
wire [14:0] vmem_addr;    wire [15:0] vmem_din;
wire [15:0] q_vram0, q_vram1, q_spr, q_pal;
wire        v2r0_we, v2r1_we, sprreg_we;
wire [3:0]  reg_addr;     wire [15:0] reg_din;
wire [15:0] q_v2r0, q_v2r1, q_sprreg;
wire        oki0_we, oki1_we, okib0_we, okib1_we;
wire [7:0]  oki_din, oki0_dout, oki1_dout;
wire        mcu_com_we, mcu_busy;
wire [1:0]  mcu_com_sel, mcu_com_be;
wire [15:0] mcu_com_din;
wire        hit_we;       wire [5:0] hit_addr; wire [15:0] hit_q;
wire [15:0] disp_enable;
wire [15:0] in_p1, in_p2, in_sys, in_unk;

// The bus as the 68000 drives it, or as a save state does (word cycles,
// with the 68000 parked or in reset). Everything that takes the 68000's
// strobes or data takes these.
wire        ss_bus, ss_as, ss_rw;
wire [23:1] ss_a;
wire [15:0] ss_d;
wire [23:1] b_eab  = ss_bus ? ss_a   : eab;
wire        b_ASn  = ss_bus ? ~ss_as : ASn;
wire        b_UDSn = ss_bus ? ~ss_as : UDSn;
wire        b_LDSn = ss_bus ? ~ss_as : LDSn;
wire        b_eRWn = ss_bus ? ss_rw  : eRWn;
wire [15:0] b_oEdb = ss_bus ? ss_d   : oEdb;
wire        bus_idle, ss_cinval, de_we;

kaneko_gtmr_bus #(.SDR_AW(SDR_AW)) u_bus
(
    .clk(clk), .rst(cpu_rst), .map2(map2),
    .eab(b_eab), .ASn(b_ASn), .LDSn(b_LDSn), .UDSn(b_UDSn), .eRWn(b_eRWn),
    .oEdb(b_oEdb), .iEdb(bus_iEdb), .DTACKn(DTACKn), .cpu_space(cpu_iack & ~ss_bus),

    .rom_req(bus_rom_req), .rom_addr(bus_rom_addr),
    .rom_ack(rom_ack[4] & ~mcu_busy), .rom_dout(rom_dout[4]),

    .ram_req(bus_ram_req), .ram_we(bus_ram_we), .ram_addr(bus_ram_addr),
    .ram_din(bus_ram_din), .ram_be(bus_ram_be),
    .ram_ack(ram_ack & ~mcu_busy), .ram_dout(ram_dout),

    .vram0_we(vram0_we), .vram1_we(vram1_we), .spr_we(spr_we), .pal_we(pal_we),
    .vmem_addr(vmem_addr), .vmem_din(vmem_din),
    .vram0_q(q_vram0), .vram1_q(q_vram1), .spr_q(q_spr), .pal_q(q_pal),
    .spr_hold(spr_hold),

    .v2r0_we(v2r0_we), .v2r1_we(v2r1_we), .sprreg_we(sprreg_we),
    .reg_addr(reg_addr), .reg_din(reg_din),
    .v2r0_q(q_v2r0), .v2r1_q(q_v2r1), .sprreg_q(q_sprreg),

    .oki0_we(oki0_we), .oki1_we(oki1_we), .oki_din(oki_din),
    .oki0_dout(oki0_dout), .oki1_dout(oki1_dout),
    .okib0_we(okib0_we), .okib1_we(okib1_we),

    .mcu_com_we(mcu_com_we), .mcu_com_sel(mcu_com_sel),
    .mcu_com_din(mcu_com_din), .mcu_com_be(mcu_com_be), .mcu_busy(mcu_busy),

    .hit_we(hit_we), .hit_addr(hit_addr), .hit_q(hit_q),

    .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_unk(in_unk),
    .disp_enable(disp_enable), .unmapped_hit(),
    .idle(bus_idle), .pf_stop(ss_park68 | ss_freeze), .cinval(ss_cinval),
    .de_we(de_we), .de_d(aux_d)
);

// ================================================================ TOYBOX
wire        mcu_ram_req, mcu_ram_we;
wire [14:0] mcu_ram_addr;  wire [15:0] mcu_ram_din;  wire [1:0] mcu_ram_be;
wire        mcu_rom_req;   wire [SDR_AW:1] mcu_rom_addr;
wire        ee_we, ee_dirty_set;
wire [63:0] com_q;
wire        com_we_ss;
wire [5:0]  ee_addr;       wire [15:0] ee_din, ee_dout;

kaneko_toybox #(.SDR_AW(SDR_AW)) u_toybox
(
    .clk(clk), .rst(cpu_rst), .table_alt(table_alt),
    .com_we(mcu_com_we), .com_sel(mcu_com_sel), .com_din(mcu_com_din),
    .com_be(mcu_com_be), .busy(mcu_busy),
    .ram_req(mcu_ram_req), .ram_we(mcu_ram_we), .ram_addr(mcu_ram_addr),
    .ram_din(mcu_ram_din), .ram_be(mcu_ram_be),
    .ram_ack(ram_ack & mcu_busy), .ram_dout(ram_dout),
    .rom_base(W_MCUDATA),
    .rom_req(mcu_rom_req), .rom_addr(mcu_rom_addr),
    .rom_ack(rom_ack[4] & mcu_busy), .rom_dout(rom_dout[4]),
    .ee_we(ee_we), .ee_addr(ee_addr), .ee_din(ee_din), .ee_dout(ee_dout),
    .ee_dirty_set(ee_dirty_set),
    .dsw(dsw),
    .ss_com_q(com_q), .ss_com_we(com_we_ss), .ss_com_sel(2'(aux_i - 5'd7)), .ss_com_d(aux_d)
);

// The 68000 is parked in the bus's S_MCU while the MCU runs, so it has no
// request outstanding: the ports can simply change hands on `mcu_busy`.
assign ram_req  = mcu_busy ? mcu_ram_req  : bus_ram_req;
assign ram_we   = mcu_busy ? mcu_ram_we   : bus_ram_we;
assign ram_addr = mcu_busy ? {2'b00, mcu_ram_addr} : bus_ram_addr;
assign ram_din  = mcu_busy ? mcu_ram_din  : bus_ram_din;
assign ram_be   = mcu_busy ? mcu_ram_be   : bus_ram_be;

wire              p4_req  = mcu_busy ? mcu_rom_req  : bus_rom_req;
wire [SDR_AW:1]   p4_addr = mcu_busy ? mcu_rom_addr : bus_rom_addr;

// ---------------------------------------------------------------- EEPROM
// 64 x 16. The platform writes the save file before the 68000 leaves reset
// and reads it back whenever it likes; the TOYBOX reads and writes it while
// running commands 02 and 42. One write port, chosen by who is writing.
logic [15:0] ee_mem [0:63];
logic [15:0] ee_q, nv_q;
// A save state takes TOYBOX's side, idle then.
wire        ss_ee, ss_ee_we;
wire [5:0]  ss_ee_a;
wire [15:0] ss_ee_d;
wire [5:0]  ee_a_m  = ss_ee ? ss_ee_a  : ee_addr;
wire        ee_we_m = ss_ee ? ss_ee_we : ee_we;
wire [15:0] ee_d_m  = ss_ee ? ss_ee_d  : ee_din;
always_ff @(posedge clk) begin
    if (nv_we)        ee_mem[nv_addr] <= nv_din;
    else if (ee_we_m) ee_mem[ee_a_m] <= ee_d_m;
    ee_q <= ee_mem[ee_a_m];
    nv_q <= ee_mem[nv_addr];
end
assign ee_dout = ee_q;
assign nv_dout = nv_q;

logic nv_dirty_r;
always_ff @(posedge clk) begin
    if (rst_por)           nv_dirty_r <= 1'b0;
    else if (ee_dirty_set || (ss_ee && ss_ee_we)) nv_dirty_r <= 1'b1;
    else if (nv_dirty_clr) nv_dirty_r <= 1'b0;
end
assign nv_dirty = nv_dirty_r;

// ================================================================ hit
// gtmr only reads its random number (kaneko16.cpp: "only used for random
// number"). A free-running LFSR stands in for machine().rand().
logic [15:0] lfsr;
wire  lfsr_we;
always_ff @(posedge clk)
    lfsr <= rst_por   ? 16'hace1 :
            lfsr_we   ? aux_d :
            ss_freeze ? lfsr :
                        {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

// The harness can replay MAME's own random numbers, so a bus trace can be
// compared past the first time the game rolls a die.
`ifdef VERILATOR
logic [15:0] dbg_rnd     /*verilator public_flat_rw*/ = 16'd0;
logic        dbg_rnd_use /*verilator public_flat_rw*/ = 1'b0;
wire  [15:0] rnd = dbg_rnd_use ? dbg_rnd : lfsr;
`else
wire  [15:0] rnd = lfsr;
`endif

kaneko_hit u_hit
(
    .clk(clk), .rst(cpu_rst),
    .addr(hit_addr), .din(reg_din), .we(hit_we),
    .uds(~b_UDSn), .lds(~b_LDSn),
    .dout(hit_q), .rnd(rnd)
);

// ================================================================ video memory
// The pixel enable, one and two clocks late: the palette read for a pixel is
// made on the first and its colour leaves the board on the second.
reg [1:0] cep_d;

wire [9:0]  c0_t0_addr, c0_t1_addr, c1_t0_addr, c1_t1_addr;
wire [31:0] c0_t0_q,    c0_t1_q,    c1_t0_q,    c1_t1_q;
wire [10:0] c0_s0_addr, c0_s1_addr, c1_s0_addr, c1_s1_addr;
wire [15:0] c0_s0_q,    c0_s1_q,    c1_s0_q,    c1_s1_q;
wire [11:0] spr_ram_addr;
wire [15:0] spr_ram_q;
wire [14:0] pal_rd_addr;
wire [15:0] pal_rd_q;

kaneko_gtmr_vmem u_vmem
(
    .clk(clk),
    .cpu_addr(vmem_addr), .cpu_din(vmem_din),
    .we_vram0(vram0_we), .we_vram1(vram1_we),
    .we_spr(spr_we), .we_pal(pal_we),
    .uds(~b_UDSn), .lds(~b_LDSn),
    .q_vram0(q_vram0), .q_vram1(q_vram1), .q_spr(q_spr), .q_pal(q_pal),
    .c0_t0_addr(c0_t0_addr), .c0_t0_q(c0_t0_q),
    .c0_t1_addr(c0_t1_addr), .c0_t1_q(c0_t1_q),
    .c0_s0_addr(c0_s0_addr), .c0_s0_q(c0_s0_q),
    .c0_s1_addr(c0_s1_addr), .c0_s1_q(c0_s1_q),
    .c1_t0_addr(c1_t0_addr), .c1_t0_q(c1_t0_q),
    .c1_t1_addr(c1_t1_addr), .c1_t1_q(c1_t1_q),
    .c1_s0_addr(c1_s0_addr), .c1_s0_q(c1_s0_q),
    .c1_s1_addr(c1_s1_addr), .c1_s1_q(c1_s1_q),
    .spr_addr(spr_ram_addr), .spr_q(spr_ram_q),
    .pal_addr(pal_rd_addr), .pal_vid(cep_d[0]), .pal_vid_d(cep_d[1]),
    .pal_q(pal_rd_q)
);

wire [255:0] v2r0_flat, v2r1_flat, sprreg_flat;

kaneko_regs16 u_v2r0
(
    .clk(clk), .we(v2r0_we), .addr(reg_addr), .din(reg_din),
    .uds(~b_UDSn), .lds(~b_LDSn),
    .rd_addr(reg_addr), .rd_q(q_v2r0), .regs_flat(v2r0_flat)
);

kaneko_regs16 u_v2r1
(
    .clk(clk), .we(v2r1_we), .addr(reg_addr), .din(reg_din),
    .uds(~b_UDSn), .lds(~b_LDSn),
    .rd_addr(reg_addr), .rd_q(q_v2r1), .regs_flat(v2r1_flat)
);

kaneko_regs16 u_sprreg
(
    .clk(clk), .we(sprreg_we), .addr(reg_addr), .din(reg_din),
    .uds(~b_UDSn), .lds(~b_LDSn),
    .rd_addr(reg_addr), .rd_q(q_sprreg), .regs_flat(sprreg_flat)
);

// ================================================================ tilemaps
// As upstream's top level: the layer controls and scrolls are latched at the
// start of the frame, and each line is rendered during the one before it.
wire [15:0] c0r0 = v2r0_flat[ 0*16 +: 16];
wire [15:0] c0r1 = v2r0_flat[ 1*16 +: 16];
wire [15:0] c0r2 = v2r0_flat[ 2*16 +: 16];
wire [15:0] c0r3 = v2r0_flat[ 3*16 +: 16];
wire [15:0] c0r4 = v2r0_flat[ 4*16 +: 16];
wire [15:0] c1r0 = v2r1_flat[ 0*16 +: 16];
wire [15:0] c1r1 = v2r1_flat[ 1*16 +: 16];
wire [15:0] c1r2 = v2r1_flat[ 2*16 +: 16];
wire [15:0] c1r3 = v2r1_flat[ 3*16 +: 16];
wire [15:0] c1r4 = v2r1_flat[ 4*16 +: 16];

wire [3:0]  lay_en_live = { ~c1r4[4], ~c1r4[12], ~c0r4[4], ~c0r4[12] };
wire [3:0]  lay_ls_live = {  c1r4[3],  c1r4[11],  c0r4[3],  c0r4[11] };
wire [63:0] lay_sx_live = { c1r0, c1r2, c0r0, c0r2 };
wire [63:0] lay_sy_live = { c1r1, c1r3, c0r1, c0r3 };

// LATCHED AT THE START OF VBLANK, NOT AT THE START OF THE FRAME. MAME
// composes frame N at vblank with the registers as they stand then, and the
// beam shows that picture during the next frame. Latching at line 240 gives
// every line of the next frame exactly those values -- including line 0,
// which is rendered during line 263, before any "frame start" could latch.
wire frame_start = vbl_rise & ~ss_freeze;

reg [3:0]  lay_en, lay_ls;
reg [63:0] lay_sx, lay_sy;
wire       lay_we;
always @(posedge clk) begin
    if (rst) begin
        lay_en <= 4'd0; lay_ls <= 4'd0; lay_sx <= 64'd0; lay_sy <= 64'd0;
    end else if (lay_we) begin
        case (aux_i)
            5'd11: {lay_ls, lay_en} <= aux_d[7:0];
            5'd12: lay_sx[63:48] <= aux_d;
            5'd13: lay_sx[47:32] <= aux_d;
            5'd14: lay_sx[31:16] <= aux_d;
            5'd15: lay_sx[15:0]  <= aux_d;
            5'd16: lay_sy[63:48] <= aux_d;
            5'd17: lay_sy[47:32] <= aux_d;
            5'd18: lay_sy[31:16] <= aux_d;
            5'd19: lay_sy[15:0]  <= aux_d;
            default: ;
        endcase
    end else if (frame_start) begin
        lay_en <= lay_en_live;
        lay_ls <= lay_ls_live;
        lay_sx <= lay_sx_live;
        lay_sy <= lay_sy_live;
    end
end

// set_offset(0x33, 0x00, 320, 240); MAME's second tilemap of each chip sits
// two pixels further on (kaneko_tmap.cpp set_scrolldx(-(m_dx+2), ...)).
localparam signed [10:0] V2_DX = 11'sd51;
localparam signed [10:0] V2_DY = 11'sd0;
wire [43:0] lay_dx = { 11'(V2_DX + 11'sd2), V2_DX, 11'(V2_DX + 11'sd2), V2_DX };
wire [43:0] lay_dy = { V2_DY, V2_DY, V2_DY, V2_DY };

// Tile ROM. Both chips read the same region (ROM_COPY on the PCB's single
// mask ROM). Codes wrap at the region size as gfx_element does: 16384 tiles
// on gtmr, 34816 on gtmr2.
wire [95:0] trom_addr_raw;
wire [31:0] trom_data_f;
wire [3:0]  trom_ready;
logic [95:0] trom_addr_f;
always_comb begin
    for (int i = 0; i < 4; i++) begin
        logic [23:0] a;
        a = trom_addr_raw[i*24 +: 24];
        if (map2) trom_addr_f[i*24 +: 24] = (a >= 24'h440000) ? a - 24'h440000 : a;
        else      trom_addr_f[i*24 +: 24] = {3'd0, a[20:0]};
    end
end

kaneko_tilerom #(.NREQ(4), .SDR_AW(SDR_AW)) u_trom
(
    .clk(clk), .rst(rst),
    .req_addr(trom_addr_f),
    .base_addr({W_VIEW2, W_VIEW2, W_VIEW2, W_VIEW2}),
    .req_data(trom_data_f),
    .port_ready(trom_ready),
    .sdr_req({rom_req[3], rom_req[2], rom_req[1], rom_req[0]}),
    .sdr_addr({rom_addr[3], rom_addr[2], rom_addr[1], rom_addr[0]}),
    .sdr_ack({rom_ack[3], rom_ack[2], rom_ack[1], rom_ack[0]}),
    .sdr_dout({rom_dout[3], rom_dout[2], rom_dout[1], rom_dout[0]})
);

wire line_start = ce_pix_i && (hcnt == 10'd0);

wire [35:0]  ln_scr_addr;
wire [63:0]  ln_scr_data;
wire [39:0]  ln_vram_addr;
wire [127:0] ln_vram_data;
wire [3:0]   mix_solid;
wire [11:0]  mix_cat;
wire [23:0]  mix_colour;
wire [15:0]  mix_pix;

kaneko_tmap_line #(.H_VIS(320)) u_line
(
    .clk(clk), .rst(rst),
    .start(line_start), .h_active(10'd320),
    // The line after this one; line 0 is rendered during the last line.
    .line_y((vcnt == 10'd263) ? 9'd0 : screen_y + 9'd1), .busy(),
    .layer_en(lay_en), .dx_f(lay_dx), .dy_f(lay_dy),
    .scroll_x_f(lay_sx), .scroll_y_f(lay_sy), .linescroll_en(lay_ls),
    .scr_addr_f(ln_scr_addr),   .scr_data_f(ln_scr_data),
    .vram_addr_f(ln_vram_addr), .vram_data_f(ln_vram_data),
    .rom_addr_f(trom_addr_raw), .rom_data_f(trom_data_f),
    .rom_ready(trom_ready),
    .rd_x(screen_x),
    .out_solid(mix_solid), .out_cat_f(mix_cat),
    .out_colour_f(mix_colour), .out_pix_f(mix_pix)
);

assign c0_t0_addr = ln_vram_addr[ 0 +: 10];
assign c0_t1_addr = ln_vram_addr[10 +: 10];
assign c1_t0_addr = ln_vram_addr[20 +: 10];
assign c1_t1_addr = ln_vram_addr[30 +: 10];
assign ln_vram_data = { c1_t1_q, c1_t0_q, c0_t1_q, c0_t0_q };
assign c0_s0_addr = {2'b00, ln_scr_addr[ 0 +: 9]};
assign c0_s1_addr = {2'b00, ln_scr_addr[ 9 +: 9]};
assign c1_s0_addr = {2'b00, ln_scr_addr[18 +: 9]};
assign c1_s1_addr = {2'b00, ln_scr_addr[27 +: 9]};
assign ln_scr_data = { c1_s1_q, c1_s0_q, c0_s1_q, c0_s0_q };

// ================================================================ sprites
wire [13:0] spr_pix;
wire [1:0]  spr_prio;

kaneko_kc002 #(.SDR_AW(SDR_AW)) u_spr
(
    .clk(clk), .rst(cpu_rst),
    .ce_pix(ce_pix_i), .hcnt(hcnt), .vcnt(vcnt),
    .spr_addr(spr_ram_addr), .spr_q(spr_ram_q), .spr_hold(spr_hold),
    .regs_flat(sprreg_flat), .map2(map2),
    .rom_base(W_KANSPR),
    .rom_req({rom_req[8], rom_req[7]}),
    .rom_addr({rom_addr[8], rom_addr[7]}),
    .rom_ack({rom_ack[8], rom_ack[7]}),
    .rom_dout({rom_dout[8], rom_dout[7]}),
    .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data),
    .fb0_req(fb0_req), .fb0_we(fb0_we), .fb0_addr(fb0_addr),
    .fb0_wdata(fb0_wdata), .fb0_wmask(fb0_wmask),
    .fb0_ack(fb0_ack), .fb0_rdata(fb0_rdata),
    .fb1_req(fb1_req), .fb1_we(fb1_we), .fb1_addr(fb1_addr),
    .fb1_wdata(fb1_wdata), .fb1_wmask(fb1_wmask),
    .fb1_ack(fb1_ack), .fb1_rdata(fb1_rdata),
    .rd_x(screen_x),
    .spr_pix(spr_pix), .spr_prio(spr_prio),
    .draw_clocks(spr_draw_clocks), .overruns(spr_overruns),
    .ss_freeze(ss_freeze), .ss_swap_full(kc_swap_full), .ss_draw_busy(kc_draw_busy),
    .ss_disp(kc_disp), .ss_draw_snap_q(kc_draw_snap_q),
    .ss_snap_en(kc_snap_en), .ss_snap_a(kc_snap_a), .ss_snap_we(kc_snap_we),
    .ss_snap_d(kc_snap_d), .ss_snap_q(kc_snap_q),
    .ss_draw(kc_draw), .ss_draw_disp(kc_draw_disp), .ss_draw_snap(kc_draw_snap)
);

wire        kc_swap_full, kc_draw_busy, kc_disp, kc_draw_snap_q;
wire        kc_snap_en, kc_snap_we, kc_draw, kc_draw_disp, kc_draw_snap;
wire [12:0] kc_snap_a;
wire [15:0] kc_snap_d, kc_snap_q;

// Read by the simulation harness; nothing on the board uses them.
wire [15:0] spr_draw_clocks /*verilator public_flat_rd*/;
wire [7:0]  dbg_oki_busy    /*verilator public_flat_rd*/ = {oki1_dout[3:0], oki0_dout[3:0]};
wire [7:0]  spr_overruns    /*verilator public_flat_rd*/;

// ================================================================ mixer
// Layer switches for the simulation harness, which writes them directly.
`ifdef VERILATOR
logic dbg_spr_off /*verilator public_flat_rw*/ = 1'b0;
wire  spr_en = ~dbg_spr_off;
`else
wire  spr_en = 1'b1;
`endif

wire [14:0] mix_pen;
kaneko_gtmr_mixer u_mix
(
    .layer_solid(mix_solid), .layer_cat_f(mix_cat),
    .layer_colour_f(mix_colour), .layer_pix_f(mix_pix),
    .spr_pix(spr_pix), .spr_prio(spr_prio),
    .view2_2_pri(1'b1),                 // MACHINE_RESET gtmr
    .disp_en(disp_enable != 16'd0),
    .spr_en(spr_en),
    .pen(mix_pen)
);

assign pal_rd_addr = mix_pen;

// The sprite layer as the mixer saw it, lined up with r/g/b for the harness.
reg  [15:0] spr_word_d;
always @(posedge clk) spr_word_d <= {spr_prio, spr_pix};
wire [15:0] dbg_spr_word /*verilator public_flat_rd*/ = spr_word_d;

// xGRB_555
wire [7:0] pal_r = {pal_rd_q[9:5],   pal_rd_q[9:7]};
wire [7:0] pal_g = {pal_rd_q[14:10], pal_rd_q[14:12]};
wire [7:0] pal_b = {pal_rd_q[4:0],   pal_rd_q[4:2]};

// The colour is two clocks behind the counters (line buffer read, then the
// palette read), so the strobes are delayed to match.
reg [1:0] hs_d, vs_d, hb_d, vb_d2;
always @(posedge clk) begin
    hs_d  <= {hs_d[0],  hs_i};
    vs_d  <= {vs_d[0],  vs_i};
    hb_d  <= {hb_d[0],  hb_i};
    vb_d2 <= {vb_d2[0], vb_i};
    cep_d <= {cep_d[0], ce_pix_i};
end
assign ce_pix = cep_d[1];
assign hs     = hs_d[1];
assign vs     = vs_d[1];
assign hblank = hb_d[1];
assign vblank = vb_d2[1];
assign r = pal_r;
assign g = pal_g;
assign b = pal_b;

// ================================================================ inputs
// gtmr / gtmr2 INPUT_PORTS. Every defined bit is active low in the high
// byte; the low byte is not defined by either port and reads zero.
wire [5:0] p1_bits = { ~p1[5], ~p1[4], ~p1[3], ~p1[2], ~p1[1], ~p1[0] };
wire [5:0] p2_bits = { ~p2[5], ~p2[4], ~p2[3], ~p2[2], ~p2[1], ~p2[0] };
assign in_p1  = { 2'b11, p1_bits, 8'h00 };
assign in_p2  = { 2'b11, p2_bits, 8'h00 };
assign in_sys = { 1'b1, ~service, 1'b1, ~test, ~coin[1], ~coin[0], ~start[1], ~start[0], 8'h00 };
assign in_unk = 16'hff00;

// ================================================================ sound
// Two OKIs, banked as init_gtmr() installs them:
//   OKI 0: 00000-2ffff fixed; 30000-3ffff a 64 KB bank, bank b at b * 0x10000
//          for b >= 3 (entries 0-2 all point at 0x30000)
//   OKI 1: the whole 256 KB window banked, bank b at b * 0x40000, mask 1
logic [3:0] okb0;
logic       okb1;
wire okb_we;
always_ff @(posedge clk) begin
    if (cpu_rst) begin okb0 <= 4'd0; okb1 <= 1'b0; end
    else if (okb_we) begin okb0 <= aux_d[3:0]; okb1 <= aux_d[4]; end
    else begin
        if (okib0_we) okb0 <= oki_din[3:0];
        if (okib1_we) okb1 <= oki_din[0];
    end
end

wire [17:0] oki0_a, oki1_a;
wire [7:0]  oki0_d, oki1_d;
wire        oki0_ok, oki1_ok;
wire signed [13:0] oki0_snd, oki1_snd;

wire [19:0] oki0_bank_base = (okb0 < 4'd3) ? 20'h30000 : {okb0, 16'h0000};
wire [23:0] oki0_region = (oki0_a < 18'h30000) ? {6'd0, oki0_a}
                        : {4'd0, oki0_bank_base + {2'b00, oki0_a - 18'h30000}};
wire [23:0] oki1_region = {5'd0, okb1, oki1_a};

kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_oki0rom
(
    .clk(clk), .rst(rst),
    .req_addr(oki0_region), .base_addr(W_OKI1),
    .req_data(oki0_d), .port_ready(oki0_ok),
    .sdr_req(rom_req[5]), .sdr_addr(rom_addr[5]),
    .sdr_ack(rom_ack[5]), .sdr_dout(rom_dout[5])
);

kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_oki1rom
(
    .clk(clk), .rst(rst),
    .req_addr(oki1_region), .base_addr(W_OKI2),
    .req_data(oki1_d), .port_ready(oki1_ok),
    .sdr_req(rom_req[6]), .sdr_addr(rom_addr[6]),
    .sdr_ack(rom_ack[6]), .sdr_dout(rom_dout[6])
);

// PIN7 low: the sample-rate divider is 165, so 2 MHz gives 12.12 kHz.
// A save state's chain runs through both: kaneko_state, OKI 1, OKI 0, back.
wire       ss_scan, ss_gsh, ss_gi, oki1_go, oki0_go;
wire [1:0] oki_quiet, oki_phase;

jt6295 u_oki0
(
    .rst(cpu_rst_real), .clk(clk), .cen(oki_cen), .ss(1'b0),
    .wrn(~oki0_we), .din(oki_din), .dout(oki0_dout),
    .rom_addr(oki0_a), .rom_data(oki0_d), .rom_ok(oki0_ok),
    .sound(oki0_snd), .sample(),
    .ss_scan(ss_scan), .ss_gsh(ss_gsh), .ss_gi(oki1_go), .ss_go(oki0_go),
    .ss_quiet(oki_quiet[0]), .ss_phase(oki_phase[0])
);

jt6295 u_oki1
(
    .rst(cpu_rst_real), .clk(clk), .cen(oki_cen), .ss(1'b0),
    .wrn(~oki1_we), .din(oki_din), .dout(oki1_dout),
    .rom_addr(oki1_a), .rom_data(oki1_d), .rom_ok(oki1_ok),
    .sound(oki1_snd), .sample(),
    .ss_scan(ss_scan), .ss_gsh(ss_gsh), .ss_gi(ss_gi), .ss_go(oki1_go),
    .ss_quiet(oki_quiet[1]), .ss_phase(oki_phase[1])
);

// Each OKI is routed at 0.5 to one speaker. Summed, then doubled so a single
// chip at full scale reaches the 16-bit rail, and saturated rather than
// trusted (upstream's lesson: a silent wrap sounds like a broken chip).
wire signed [15:0] oki_sum  = 16'(oki0_snd) + 16'(oki1_snd);
wire signed [17:0] oki_gain = 18'(oki_sum) * 18'sd2;
assign snd = (oki_gain >  18'sd32767) ? 16'h7fff
           : (oki_gain < -18'sd32768) ? 16'h8000
           :                            oki_gain[15:0];

// ================================================================ p4 mux
assign rom_req[4]  = p4_req;
assign rom_addr[4] = p4_addr;

// ================================================================ diagnostics
// What a photograph of the overlay can say about a hitch in play: whether the
// 68000 was HELD (a bus cycle of millions of clocks, and the address says by
// what), how close the game came to running out of frame, and whether the
// sprite engine fell behind (overruns, and the longest draw). Peaks hold
// until diag_clr. A bus cycle is counted from AS going low, so the ordinary
// peak is the sprite snapshot's hold, about 4100 clocks at a 400000 address.
//
// Spare time: each set's main program, once running, is one `bra.b *` and
// the game happens in the interrupts. The clocks from a fetch there to the
// next bus cycle anywhere else are the 68000's spare time; a frame with none
// is one whose work ran past it, so the game falls a frame behind (MAME, a
// gtmrusa race: a fifth of every frame spare).
logic [31:0] dg_wait, dg_wait_max;
logic [23:0] dg_wait_addr;
logic [15:0] dg_idle_min, dg_lag_frames, dg_draw_max;
logic [19:0] dg_idle;
logic [7:0]  dg_over_base;   // KC-002 overruns at the last clear: the chip's count is since reset
logic        dg_as_q, dg_armed, dg_idling;
wire         dg_as = ~ASn & ~cpu_iack;
wire [23:1]  dg_ipc = (game == 3'd2) ? 23'h000585 :            // gtmrusa 000b0a
                      (game == 3'd3) ? 23'h000688 :            // gtmr2   000d10
                      (game == 3'd4) ? 23'h00069a : 23'h000572; // gtmr2u 000d34, gtmr/gtmre 000ae4
always_ff @(posedge clk) begin
    dg_as_q <= dg_as;
    if (cpu_rst || diag_clr) begin
        dg_wait <= '0; dg_wait_max <= '0; dg_wait_addr <= '0;
        dg_idle_min <= 16'hffff; dg_lag_frames <= '0; dg_draw_max <= '0;
        dg_idle <= '0; dg_idling <= 1'b0;
        dg_over_base <= spr_overruns;
        dg_armed <= 1'b0;
    end else begin
        if (dg_as && !dg_as_q) begin
            dg_wait   <= 32'd1;
            dg_idling <= eRWn && (eab == dg_ipc || eab == dg_ipc + 23'd1);
        end else if (dg_as && dg_wait != 32'hffffffff) begin
            dg_wait <= dg_wait + 32'd1;
        end
        if (dg_as && dg_wait > dg_wait_max) begin
            dg_wait_max  <= dg_wait;
            dg_wait_addr <= {eab, 1'b0};
        end
        if (dg_idling && dg_idle != 20'hfffff) dg_idle <= dg_idle + 20'd1;
        if (vbl_rise) begin
            dg_idle  <= '0;
            dg_armed <= ~irq_hold;   // the first frame after a clear, a pause or a save state is partial
            if (dg_armed && !irq_hold) begin
                if ({2'b00, dg_idle[19:6]} < dg_idle_min) dg_idle_min <= {2'b00, dg_idle[19:6]};
                if (dg_idle == '0 && dg_lag_frames != 16'hffff) dg_lag_frames <= dg_lag_frames + 16'd1;
            end
        end
        if (spr_draw_clocks > dg_draw_max) dg_draw_max <= spr_draw_clocks;
    end
end
assign diag_wait_max     = dg_wait_max;
assign diag_wait_addr    = dg_wait_addr;
assign diag_idle_min     = dg_idle_min;
assign diag_lag_frames   = dg_lag_frames;
assign diag_draw_max     = dg_draw_max;
assign diag_spr_overruns = spr_overruns - dg_over_base;

// ================================================================ save states
// The board's own words in the file (0x46-0x67), aux 3-19.
wire [15:0] aux_d;
wire [4:0]  aux_i;
wire        aux_we;
wire [319:0] aux_q;
assign aux_q[  0 +: 48] = '0;                       // 0-2: kaneko_state's own
assign aux_q[ 48 +: 16] = disp_enable;
assign aux_q[ 64 +: 16] = {11'd0, okb1, okb0};
assign aux_q[ 80 +: 16] = {13'd0, irq_ss_q};
assign aux_q[ 96 +: 16] = lfsr;
assign aux_q[112 +: 64] = com_q;                    // com[0] first
assign aux_q[176 +: 16] = {8'd0, lay_ls, lay_en};
assign aux_q[192 +: 16] = lay_sx[63:48];
assign aux_q[208 +: 16] = lay_sx[47:32];
assign aux_q[224 +: 16] = lay_sx[31:16];
assign aux_q[240 +: 16] = lay_sx[15:0];
assign aux_q[256 +: 16] = lay_sy[63:48];
assign aux_q[272 +: 16] = lay_sy[47:32];
assign aux_q[288 +: 16] = lay_sy[31:16];
assign aux_q[304 +: 16] = lay_sy[15:0];
assign de_we     = aux_we && aux_i == 5'd3;
assign okb_we    = aux_we && aux_i == 5'd4;
assign irq_ss_we = aux_we && aux_i == 5'd5;
assign lfsr_we   = aux_we && aux_i == 5'd6;
assign com_we_ss = aux_we && aux_i >= 5'd7 && aux_i <= 5'd10;
assign lay_we    = aux_we && aux_i >= 5'd11;

kaneko_state u_state
(
    // its own reset is power-up's: a wake's file may come while the Pocket
    // still holds the board in reset, and the load takes it out
    .clk(clk), .rst(rst_por | ~rom_loaded), .game(game),
    .ss_save(ss_save), .ss_go(ss_go), .ss_status(ss_status),
    .ss_loading(ss_loading), .ss_refused(ss_refused),
    .ss_addr(ss_addr), .ss_rd(ss_rd), .ss_do(ss_do), .ss_wr(ss_wr), .ss_di(ss_di),
    .dl_wr(dl_wr), .dl_data(dl_data),
    .vcnt(vcnt), .hcnt(hcnt), .line_start(line_start), .frame_edge(vbl_rise), .oki_div(oki_div),
    .ss_park68(ss_park68), .ss_parkdisp68(ss_parkdisp68), .ss_rst68(ss_rst68), .ss_run68(ss_run68),
    .fx_atstart(fx_atstart), .fx_atdisp(fx_atdisp), .fx_busidle(fx_busidle), .fx_uaddr(fx_uaddr),
    .fx_regq(fx_regq), .fx_pc(fx_pc), .fx_sr(fx_sr), .fx_misc(fx_misc),
    .fx_grpdisp(fx_grpdisp), .fx_clk(fx_clk),
    .fx_rega(fx_rega), .fx_regwe(fx_regwe), .fx_regd(fx_regd),
    .fx_srwe(fx_srwe), .fx_miscwe(fx_miscwe), .fx_grpwe(fx_grpwe), .fx_clkwe(fx_clkwe),
    .fx_srd(fx_srd), .fx_miscd(fx_miscd), .fx_grpd(fx_grpd), .fx_clkd(fx_clkd),
    .ss_vec(ss_vec), .ss_vec_sp(ss_vec_sp), .ss_vec_pc(ss_vec_pc),
    .cpu_asn(ASn), .cpu_vec3(eab == 23'd3), .bus_dtackn(DTACKn), .cpu_ipl_n(cpu_ipl_n),
    .bus_idle(bus_idle), .mcu_busy(mcu_busy),
    .ss_freeze(ss_freeze), .ss_okirun(ss_okirun), .ss_sysrst(ss_sysrst), .ss_cinval(ss_cinval),
    .ss_scan(ss_scan), .ss_gsh(ss_gsh), .ss_gi(ss_gi), .oki_go(oki0_go),
    .oki_quiet(oki_quiet), .oki_phase(oki_phase),
    .kc_swap_full(kc_swap_full), .kc_draw_busy(kc_draw_busy),
    .kc_disp(kc_disp), .kc_snap_sel(kc_draw_snap_q),
    .kc_snap_en(kc_snap_en), .kc_snap_a(kc_snap_a), .kc_snap_we(kc_snap_we),
    .kc_snap_d(kc_snap_d), .kc_snap_q(kc_snap_q),
    .kc_draw(kc_draw), .kc_draw_disp(kc_draw_disp), .kc_draw_snap(kc_draw_snap),
    .ss_bus(ss_bus), .ss_as(ss_as), .ss_a(ss_a), .ss_d(ss_d), .ss_rw(ss_rw), .bus_q(bus_iEdb),
    .ss_ee(ss_ee), .ss_ee_a(ss_ee_a), .ss_ee_we(ss_ee_we), .ss_ee_d(ss_ee_d), .ee_q(ee_q),
    .aux_q(aux_q), .aux_we(aux_we), .aux_i(aux_i), .aux_d(aux_d)
);

endmodule

`default_nettype wire
