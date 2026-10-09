// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the gtmr board's priority mixer
//
// kaneko_mixer with the KC-002 board's numbers. The layer arbitration is
// upstream's (verified pixel-exact against MAME on three games); what changes
// is the size of everything after it:
//
//   tiles    pen = colour * 16 + pixel, colour base 0      (10 bits)
//   sprites  pen = 0x4000 + ((colour * 256 + pixel) & 0x3fff)
//   nothing  pen 0x7f00 — fill_bitmap()'s background for type 1 sprite chips
//
// and the display-enable word at c00000: when it is zero, screen_update()
// returns after the fill, so the whole screen is the background pen.
//
// The sprite priorities are kaneko16_sprite_device's defaults, which gtmr
// never overrides: S0 over tile priority 0, S1 over 0-1, S2 over 0-2, S3 over
// everything ({1, 2, 3, 8} against the priority bitmap).

`timescale 1ns/1ps
`default_nettype none

module kaneko_gtmr_mixer (
    input  wire [3:0]   layer_solid,
    input  wire [11:0]  layer_cat_f,
    input  wire [23:0]  layer_colour_f,
    input  wire [15:0]  layer_pix_f,
    input  wire [13:0]  spr_pix,         // 0 = nothing here
    input  wire [1:0]   spr_prio,
    input  wire         view2_2_pri,
    input  wire         disp_en,
    input  wire         spr_en,          // debug: sprites on
    output wire [14:0]  pen
);
    function automatic [2:0] cat_of(input [1:0] i); cat_of = layer_cat_f[i*3 +: 3];    endfunction
    function automatic [5:0] col_of(input [1:0] i); col_of = layer_colour_f[i*6 +: 6]; endfunction
    function automatic [3:0] pix_of(input [1:0] i); pix_of = layer_pix_f[i*4 +: 4];    endfunction

    logic [1:0] win;
    logic       any_solid;
    always_comb begin
        win       = 2'd0;
        any_solid = 1'b0;
        for (int i = 0; i < 4; i++) begin
            if (layer_solid[i]) begin
                if (!any_solid || cat_of(2'(i)) >= cat_of(win)) win = 2'(i);
                any_solid = 1'b1;
            end
        end
    end

    wire        winner_chip1 = win[1];
    wire [2:0]  tile_prio    = (winner_chip1 && !view2_2_pri) ? 3'd0 : cat_of(win);
    wire [14:0] tile_pen     = {5'd0, col_of(win), pix_of(win)};

    wire [14:0] under_pen  = any_solid ? tile_pen  : 15'h7f00;
    wire [2:0]  under_prio = any_solid ? tile_prio : 3'd0;

    wire [3:0]  spr_level  = (spr_prio == 2'd0) ? 4'd1
                           : (spr_prio == 2'd1) ? 4'd2
                           : (spr_prio == 2'd2) ? 4'd3 : 4'd8;
    wire        sprite_won = spr_en && (|spr_pix) && (spr_level > {1'b0, under_prio});

    assign pen = !disp_en   ? 15'h7f00
               : sprite_won ? {1'b1, spr_pix}
               :              under_pen;
endmodule

`default_nettype wire
