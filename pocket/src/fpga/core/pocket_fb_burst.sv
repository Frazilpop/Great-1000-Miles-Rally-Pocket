// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 for Analogue Pocket — one sprite-bitmap port (fb0 or fb1) on one
// PSRAM chip, in synchronous bursts on clk_sdram
//
// WHY. The KC-002 draws every frame's sprites into the chip it is not
// showing, a 16-word row at a time. Driven asynchronously (agg23's psram.sv,
// the first servant) a word costs 6 clocks at 48 MHz and a full row 99, and
// on the busiest scenes (a finish line's crowd, gtmr2's grid) the draw ran
// past a frame, so the sprites kept the old list one frame or more and
// juddered against the tilemaps. pocket_psram_rows runs the part in
// synchronous burst mode at 48 MHz, on a 96 MHz clock: one address phase,
// the latency, then a word a device clock, so a full row is about 22 core
// clocks and a partial one a burst from its first word to its last.
//
// THE CROSSING. clk_fast is clk_sdram, from the same PLL as clk_core at
// exactly twice it, edges aligned: as kaneko_sdram_x2 says, not a
// clock-domain crossing but a pulse-width question, with the same two
// answers:
//
//   1. The servant's ack is one fast cycle. A slow edge falls on every
//      second fast edge, so it is widened to two: exactly one slow edge
//      sees it, whichever the alignment.
//   2. The board drops req on the slow edge that sees ack, so it may still
//      be high for two more fast cycles; `done` masks it from the ack until
//      the board lowers it (the KC-002 always does for at least one slow
//      cycle between rows).
//
// addr, we, wdata and wmask are held by the board with req and read by the
// servant as its burst goes, so they need nothing. rdata is the servant's
// register, written before its ack and held until the next request.
//
// The tri-state is at the top (core_top), as the servant wants it split.

`default_nettype none

module pocket_fb_burst (
    input  wire          clk_fast,      // clk_sdram, 96 MHz, 2x clk_core
    input  wire          rst,           // power-on only (rst_por)

    // board side, clk_core (fbN, as kaneko_kc002 drives it)
    input  wire          req,
    input  wire          we,
    input  wire [21:0]   addr,
    input  wire [255:0]  wdata,
    input  wire [15:0]   wmask,         // one bit a word
    output wire          ack,
    output wire [255:0]  rdata,

    // the servant's state, clk_fast, static once ready
    output wire          ready,
    output wire          cal_fail,
    output wire [6:0]    lats,          // {wr_lat, rd_ph, rd_lat}

    // pins
    output wire [21:16]  cram_a,
    output wire [15:0]   cram_dq_o,
    output wire          cram_dq_oe,
    input  wire [15:0]   cram_dq_i,
    output wire          cram_clk,
    output wire          cram_adv_n,
    output wire          cram_cre,
    output wire          cram_ce0_n,
    output wire          cram_ce1_n,
    output wire          cram_oe_n,
    output wire          cram_we_n,
    output wire          cram_ub_n,
    output wire          cram_lb_n
);

    wire f_ack;
    reg  f_ack_d = 1'b0;
    reg  done    = 1'b0;
    always @(posedge clk_fast) begin
        f_ack_d <= f_ack;
        if (!req)       done <= 1'b0;
        else if (f_ack) done <= 1'b1;
    end
    assign ack = f_ack | f_ack_d;
    wire f_req = req & ~done & ~f_ack;

    // A word's bit becomes its two bytes'.
    wire [31:0] bmask;
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : g_mask
        assign bmask[2*g +: 2] = {2{wmask[g]}};
    end endgenerate

    wire [2:0] rd_lat, wr_lat;
    wire       rd_ph;
    assign lats = {wr_lat, rd_ph, rd_lat};

    pocket_psram_rows #(.CLOCK_MHZ(96.0)) u_rows (
        .clk        (clk_fast),
        .rst        (rst),
        .req        (f_req),
        .we         (we),
        .addr       (addr),
        .wdata      (wdata),
        .wmask      (bmask),
        .ack        (f_ack),
        .rdata      (rdata),
        .ready      (ready),
        .cal_fail   (cal_fail),
        .rd_lat     (rd_lat),
        .rd_ph      (rd_ph),
        .wr_lat     (wr_lat),
        .cram_a     (cram_a),
        .cram_dq_o  (cram_dq_o),
        .cram_dq_oe (cram_dq_oe),
        .cram_dq_i  (cram_dq_i),
        .cram_clk   (cram_clk),
        .cram_adv_n (cram_adv_n),
        .cram_cre   (cram_cre),
        .cram_ce0_n (cram_ce0_n),
        .cram_ce1_n (cram_ce1_n),
        .cram_oe_n  (cram_oe_n),
        .cram_we_n  (cram_we_n),
        .cram_ub_n  (cram_ub_n),
        .cram_lb_n  (cram_lb_n)
    );

endmodule

`default_nettype wire
