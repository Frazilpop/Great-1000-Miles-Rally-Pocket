// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (Pocket) — the shell's pocket_analogizer as a model of its own for
// tb_gtmr's --anz-* options (sim/gtmr/build.sh --anz).
//
// It stands where core_top has it: on the board's raster after the menu's
// black (`black` is core_top's inmenu_48 | ss_load_blank; the overlay is off
// here), with the Pocket's controls in and the players' controls out. The
// cartridge pins come out as plain outputs, with the SNAC pads' data lines
// driven onto bank0 and pin31 while those are inputs, as a pad would. The
// harness runs clk_core with the board's clock and toggles clk_anz on each of
// its rising edges (864 MHz / 18 and / 36); clk_74a, which only clocks the
// settings in, is clk_core here.

`default_nettype none

module anz_top (
    input  wire        clk_core,
    input  wire        clk_anz,
    input  wire        anz_wr,          // a bridge write to 0xF7000000
    input  wire [31:0] anz_data,
    input  wire        ce_pix, vs, hblank, vblank,
    input  wire [7:0]  r, g, b,
    input  wire        black,
    input  wire [15:0] cont1_key, cont2_key,
    input  wire [7:4]  bank0_in,        // onto bank0 while it is an input
    input  wire        pin31_in,        // and onto pin31
    output wire [15:0] key1, key2,
    output wire        pocket_off,
    output wire [7:0]  bank3, bank2, bank1,
    output wire [7:4]  bank0,
    output wire        bank3_dir, bank2_dir, bank1_dir, bank0_dir,
    output wire        pin30, pin30_dir, pwroff, pin31_dir,
    output wire [31:0] cfg              // the word as pocket_analogizer took it
);
    wire [7:0] mr = black ? 8'd0 : r;
    wire [7:0] mg = black ? 8'd0 : g;
    wire [7:0] mb = black ? 8'd0 : b;

    wire [7:0] c_b3, c_b2, c_b1;
    wire [7:4] c_b0;
    wire       c_p30, c_p31;
    assign c_b0  = bank0_dir ? 4'hz : bank0_in;
    assign c_p31 = pin31_dir ? 1'bz : pin31_in;

    pocket_analogizer u_anz (
        .clk_74a (clk_core), .bridge_wr (anz_wr), .bridge_addr (32'hF7000000),
        .bridge_wr_data (anz_data),
        .clk_core (clk_core), .ce_pix (ce_pix), .vs (vs),
        .hblank (hblank), .vblank (vblank), .r (mr), .g (mg), .b (mb),
        .pocket_off (pocket_off),
        .clk_anz (clk_anz),
        .cont1_key (cont1_key), .cont2_key (cont2_key),
        .key1 (key1), .key2 (key2),
        .cart_tran_bank2 (c_b2), .cart_tran_bank2_dir (bank2_dir),
        .cart_tran_bank3 (c_b3), .cart_tran_bank3_dir (bank3_dir),
        .cart_tran_bank1 (c_b1), .cart_tran_bank1_dir (bank1_dir),
        .cart_tran_bank0 (c_b0), .cart_tran_bank0_dir (bank0_dir),
        .cart_tran_pin30 (c_p30), .cart_tran_pin30_dir (pin30_dir),
        .cart_pin30_pwroff_reset (pwroff),
        .cart_tran_pin31 (c_p31), .cart_tran_pin31_dir (pin31_dir)
    );
    assign {bank3, bank2, bank1, bank0, pin30} = {c_b3, c_b2, c_b1, c_b0, c_p30};
    assign cfg = u_anz.cfg_74;
endmodule

`default_nettype wire
