// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (gtmr board) for Analogue Pocket — RndMnkIII's Analogizer in the
// cartridge slot
//
// The board's own raster (15.625 kHz, 384 dots by 264 lines, 320 x 240
// shown) goes out of the adapter's VGA connector, and SNAC controllers come
// in for the two players, through RndMnkIII's openFPGA_Pocket_Analogizer
// (pocket/src/fpga/analogizer/).
//
// CLOCKS. The board runs on clk_core (48 MHz) with a dot every eighth clock
// (ce_pix, 6 MHz). The module wants a clock four times the dot, which it
// also puts on the cartridge pin that clocks the adapter's DAC (bank1[5]):
// clk_anz, 24 MHz, the PLL's sixth output (864 MHz / 36). The two come from
// one VCO, every clk_anz edge on a clk_core rising edge, so the crossing is
// synchronous and timed, as pocket_video's is: each dot is held on ce_pix in
// clk_core for its eight clocks, which are four clk_anz clocks, and clk_anz
// takes the held dot on every edge. A free divide-by-four in clk_anz (ce4)
// then lands once in every dot, whatever its phase against ce_pix, so no dot
// is dropped or doubled. The scandoubler's own divider (ce_divider 3,
// clk / 4) does the same.
//
// HSYNC. The board's raster has a short back porch: hsync dots 336-367 of
// 384, the picture from dot 0, 16 dots (64 clk_anz clocks) after hsync ends.
// yc_out starts its colour burst 40 clocks after hsync ends and, at 24 MHz,
// keeps it to 115, so with the board's hsync the burst would run some dozen
// dots into the picture. The adapter gets an hsync of its own instead, made
// here from hblank: dots 328-351 (8 after the picture ends, 24 wide, 4 us),
// which leaves 32 dots (128 clocks) of back porch, the burst inside it and
// the line close to NTSC's (sync 4 us, burst 5.7-8.8 us from its leading
// edge, the picture at 9.3). Every mode takes the same sync. The Pocket's
// screen keeps the board's.
//
// SETTINGS come from analogizer.bin, the file Pupdate and RndMnkIII's
// AnalogizerConfigurator write to Assets/analogizer/common/ and every
// Analogizer core that reads the file shares: data slot 330 (data.json),
// platform index 1 (core.json's second platform id, "analogizer"), loaded to
// 0xF7000000. It is one 32-bit word, written little-endian (BitConverter);
// the bridge is big-endian here (bridge_endian_little = 0), so the file's
// first byte arrives in [31:24] and the bytes are turned back round:
//
//   [4:0]   SNAC controller: 0 none, 1 DB15, 2 NES, 3 SNES, 4 PC Engine
//           2-button, 5 6-button, 6 multitap, 9 DB15 fast, 0xB SNES with A,B
//           and X,Y swapped (the ones taken here; the PS/2 and PlayStation
//           types and JVS are not, and leave the Pocket's controls in place)
//   [5]     Analogizer on
//   [9:6]   SNAC assignment: 0 SNAC 1 -> player 1, 1 SNAC 1 -> player 2,
//           2 SNAC 1, 2 -> players 1, 2, 3 SNAC 1, 2 -> players 2, 1,
//           4 SNAC 1, 2 -> players 3, 4 (there are only two: both stay the
//           Pocket's), 5 SNAC 1-4 -> players 1-4 (SNAC 1, 2 -> players 1, 2)
//   [13:10] video: 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5-8 the
//           scandoubler (31 kHz RGBHV) with scanlines of 0, 25, 50 and 75 %,
//           9 HQ2x, which this module has not got: the scandoubler without
//           scanlines. The module's own codes are older (5-7 the scandoubler,
//           its scanlines on fx; 8-F the same modes with the Pocket's screen
//           off), so the file's are turned into them below.
//   [14]    the Pocket's own screen black
//   [15]    OSD on the adapter's output, [19:16] region: nothing here uses
//           them
//
// No file, or [5] clear, is the Analogizer off: the module holds the pins
// idle, which is the template's tie-off for every pin but pin30 (the module
// lets it float as an input, the template drives it low and leaves its
// direction to the hardware), so pin30 is driven as the template has it here.
// A Pocket with no adapter, or no file, sees the slot exactly as before.
//
// SNAC words come out in the Pocket's controller order (key[15:0]: up, down,
// left, right, A, B, X, Y, L1, R1, L2, R2, L3, R3, select, start), so they
// stand in for cont1_key and cont2_key as they are: key1 and key2 are the
// players' controls, the Pocket's or a SNAC controller's as the assignment
// gives them (Select the coin, Start the start, as on the Pocket). Each bit
// is a level held for a frame or more, and core_top.v synchronises them into
// clk_core bit by bit, as it did the Pocket's alone.

`default_nettype none

module pocket_analogizer (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,

    input  wire        clk_core,            // the board's clock, 48 MHz
    input  wire        ce_pix,              // its dot, one clk_core in eight
    input  wire        vs,                  // active high; all of these change
    input  wire        hblank, vblank,      //   with ce_pix and hold until the
    input  wire [7:0]  r, g, b,             //   next
    output wire        pocket_off,          // the Pocket's own screen to black (clk_core)

    input  wire        clk_anz,             // 24 MHz, four clocks a dot, same VCO

    input  wire [15:0] cont1_key, cont2_key, // the Pocket's controls (clk_74a)
    output wire [15:0] key1, key2,          // the players' controls

    inout  wire [7:0]  cart_tran_bank2,
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,
    output wire        cart_tran_pin31_dir
);

    // ------------------------------------------------------- the settings
    reg  [31:0] cfg_74 = 32'd0;
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr == 32'hF7000000)
            cfg_74 <= {bridge_wr_data[7:0], bridge_wr_data[15:8],
                       bridge_wr_data[23:16], bridge_wr_data[31:24]};

    /* verilator lint_off UNUSEDSIGNAL */   // [31:14]: the Pocket's side, the OSD, the region
    wire [31:0] cfg;
    /* verilator lint_on UNUSEDSIGNAL */
    pocket_sync_bus #(.W(32)) s_cfg (.clk (clk_anz), .d (cfg_74), .q (cfg));

    // the Pocket's screen is blacked in clk_core, before pocket_video
    wire [1:0]  off_core;
    pocket_sync_bus #(.W(2)) s_off (.clk (clk_core), .d ({cfg_74[14], cfg_74[5]}), .q (off_core));
    assign pocket_off = &off_core;

    wire        on      = cfg[5];
    wire [4:0]  ctype   = cfg[4:0];
    wire [3:0]  assign_ = cfg[9:6];
    wire [3:0]  vtype   = cfg[13:10];

    reg  [3:0]  m_vtype = 4'd0;             // the module's video code
    reg  [1:0]  m_lines = 2'd0;             // its scanlines (fx[1:0])
    reg         snac_ok = 1'b0;
    reg  [1:0]  p1_sel  = 2'd0;             // 0 the Pocket's controls, 1 SNAC 1,
    reg  [1:0]  p2_sel  = 2'd0;             //   2 SNAC 2
    always @(posedge clk_anz) begin
        m_vtype <= (vtype <= 4'd4) ? vtype : (vtype <= 4'd9) ? 4'd5 : 4'd0;
        m_lines <= (vtype >= 4'd5 && vtype <= 4'd8) ? vtype[1:0] - 2'd1 : 2'd0;
        case (ctype)
        5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h09, 5'h0B: snac_ok <= on;
        default:                                               snac_ok <= 1'b0;
        endcase
        p1_sel <= !snac_ok ? 2'd0 :
                  (assign_ == 4'd0 || assign_ == 4'd2 || assign_ == 4'd5) ? 2'd1 :
                  (assign_ == 4'd3) ? 2'd2 : 2'd0;
        p2_sel <= !snac_ok ? 2'd0 :
                  (assign_ == 4'd1 || assign_ == 4'd3) ? 2'd1 :
                  (assign_ == 4'd2 || assign_ == 4'd5) ? 2'd2 : 2'd0;
    end

    wire [15:0] snac1, snac2;
    /* verilator lint_off UNUSEDSIGNAL */   // the multitap's third and fourth pads: no players for them
    wire [15:0] snac3, snac4;
    /* verilator lint_on UNUSEDSIGNAL */
    assign key1 = (p1_sel == 2'd1) ? snac1 : (p1_sel == 2'd2) ? snac2 : cont1_key;
    assign key2 = (p2_sel == 2'd1) ? snac1 : (p2_sel == 2'd2) ? snac2 : cont2_key;

    // Y/C: the colour subcarrier as a step of a 40-bit phase per clk_anz
    // clock, f * 2^40 / 24 MHz (NTSC 3.579545 MHz, PAL 4.43361875 MHz)
    wire        pal = (m_vtype == 4'd4);
    wire [39:0] phase_inc = pal ? 40'd203117307031 : 40'd163989639569;

    // ----------------------------------------------------------- the dot
    // In clk_core: the dot taken whole on ce_pix (the overlay's colour is
    // combinational on registers that change then) and held for eight
    // clocks, so that only registers cross into clk_anz. hbd counts the dots
    // of hblank, for the adapter's hsync (above).
    reg  [7:0]  hr = 8'd0, hg = 8'd0, hb = 8'd0;
    reg         hhs = 1'b0, hvs = 1'b0, hhb = 1'b1, hvb = 1'b1;
    reg  [5:0]  hbd = 6'd0;
    always @(posedge clk_core) if (ce_pix) begin
        {hr, hg, hb} <= {r, g, b};
        {hvs, hhb, hvb} <= {vs, hblank, vblank};
        hhs <= hblank && hbd >= 6'd8 && hbd < 6'd32;
        hbd <= !hblank ? 6'd0 : (hbd == 6'd63) ? hbd : hbd + 6'd1;
    end

    // In clk_anz: the held dot on every edge, and ce4 once in each.
    reg  [7:0]  vr = 8'd0, vg = 8'd0, vb = 8'd0;
    reg         vhs = 1'b0, vvs = 1'b0, vhb = 1'b1, vvb = 1'b1;
    reg  [1:0]  div = 2'd0;
    always @(posedge clk_anz) begin
        {vr, vg, vb} <= {hr, hg, hb};
        {vhs, vvs, vhb, vvb} <= {hhs, hvs, hhb, hvb};
        div <= div + 2'd1;
    end
    wire        ce4 = (div == 2'd0);
    wire        vde = ~(vhb | vvb);

    // The scandoubler (MiST's) is the one part that reads vblank. It starts
    // its lines where hsync ends, notes where in a line vblank changed and
    // replays it there in the two lines it makes from it. The board's vblank
    // changes where its hblank ends, 32 dots after the adapter's hsync ends,
    // inside the line, so it goes in as it is (Cave 68000's changed on the
    // dot hsync ended and had to be moved a few dots in).

    // --------------------------------------------------------- the module
    wire        m_pin30, m_pin30_dir;

    openFPGA_Pocket_Analogizer #(
        .MASTER_CLK_FREQ (24_000_000),
        .LINE_LENGTH     (384)              // dots a line (the module doesn't use it)
    ) u_anz (
        .i_clk            (clk_anz),
        .i_rst            (1'b0),
        .i_ena            (on),
        .video_clk        (clk_anz),
        .analog_video_type(m_vtype),
        .R (vr), .G (vg), .B (vb),
        .Hblank (vhb),    .Vblank (vvb),    .BLANKn (vde),
        .Hsync  (vhs),    .Vsync  (vvs),
        .Csync  (~(vhs ^ vvs)),             // active low, serrated in vsync
        .CHROMA_PHASE_INC (phase_inc),
        .PALFLAG          (pal),
        .ce_pix           (ce4),
        .scandoubler      (1'b1),
        .fx               ({1'b0, m_lines}),
        .conf_AB          (1'b0),
        .game_cont_type   (snac_ok ? ctype : 5'd0),
        .p1_btn_state     (snac1), .p1_joy_state (),
        .p2_btn_state     (snac2), .p2_joy_state (),
        .p3_btn_state     (snac3), .p4_btn_state (snac4),
        .i_VIB_SW1 (2'b00), .i_VIB_DAT1 (8'h00), .i_VIB_SW2 (2'b00), .i_VIB_DAT2 (8'h00),
        .busy             (),
        .cart_tran_bank2  (cart_tran_bank2), .cart_tran_bank2_dir (cart_tran_bank2_dir),
        .cart_tran_bank3  (cart_tran_bank3), .cart_tran_bank3_dir (cart_tran_bank3_dir),
        .cart_tran_bank1  (cart_tran_bank1), .cart_tran_bank1_dir (cart_tran_bank1_dir),
        .cart_tran_bank0  (cart_tran_bank0), .cart_tran_bank0_dir (cart_tran_bank0_dir),
        .cart_tran_pin30  (m_pin30),         .cart_tran_pin30_dir (m_pin30_dir),
        .cart_pin30_pwroff_reset (cart_pin30_pwroff_reset),
        .cart_tran_pin31  (cart_tran_pin31), .cart_tran_pin31_dir (cart_tran_pin31_dir),
        .DBG_TX (), .o_stb ()
    );

    // pin30 is only ever an output with the adapter (its SNAC clock 2)
    assign cart_tran_pin30     = on ? m_pin30     : 1'b0;
    assign cart_tran_pin30_dir = on ? m_pin30_dir : 1'bz;

endmodule

`default_nettype wire
