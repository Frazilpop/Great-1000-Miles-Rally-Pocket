// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (Pocket) — the shell's sprite-bitmap memories as a model of their
// own for tb_gtmr's --fb-rtl: pocket_fb_burst (pocket_psram_rows inside) on
// each of fb0 and fb1, each on a psram_model, as core_top has them.
//
// The harness runs clk_core with the board's clock and gives clk_fast two
// rising edges a board clock, the first with clk_core's: the 2:1 of one PLL.
// The board's fbN outputs come in as they stood before each board edge, and
// its acks and read data go back the same way.

`default_nettype none

module fb_top #(
    parameter int unsigned LAT_W = 4,
    parameter int unsigned LAT_R = 4
) (
    input  wire          clk_fast,
    input  wire          rst,

    input  wire          fb0_req, fb0_we,
    input  wire [21:0]   fb0_addr,
    input  wire [255:0]  fb0_wdata,
    input  wire [15:0]   fb0_wmask,
    output wire          fb0_ack,
    output wire [255:0]  fb0_rdata,

    input  wire          fb1_req, fb1_we,
    input  wire [21:0]   fb1_addr,
    input  wire [255:0]  fb1_wdata,
    input  wire [15:0]   fb1_wmask,
    output wire          fb1_ack,
    output wire [255:0]  fb1_rdata,

    output wire          ready,
    output wire [1:0]    cal_fail,
    output wire [13:0]   lats,
    output wire [31:0]   violations
);

    wire [1:0]        rq  = {fb1_req, fb0_req};
    wire [1:0]        we  = {fb1_we, fb0_we};
    wire [1:0][21:0]  ad  = {fb1_addr, fb0_addr};
    wire [1:0][255:0] wd  = {fb1_wdata, fb0_wdata};
    wire [1:0][15:0]  wm  = {fb1_wmask, fb0_wmask};
    wire [1:0]        ak;
    wire [1:0][255:0] rd;
    wire [1:0]        rdy;
    int unsigned      viol [0:1];

    genvar c;
    generate for (c = 0; c < 2; c = c + 1) begin : g_chip
        wire [21:16] a;
        wire [15:0]  dq_o, dq_m;
        wire         dq_oe, oe_m;
        wire         ck, adv_n, cre, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n;
        wire [15:0]  bcr;
        // DQ as the pins would have it: whoever drives, else the last value
        wire [15:0]  dq = dq_oe ? dq_o : oe_m ? dq_m : 16'd0;

        pocket_fb_burst u_fb (
            .clk_fast (clk_fast), .rst (rst),
            .req (rq[c]), .we (we[c]), .addr (ad[c]), .wdata (wd[c]), .wmask (wm[c]),
            .ack (ak[c]), .rdata (rd[c]),
            .ready (rdy[c]), .cal_fail (cal_fail[c]), .lats (lats[7*c +: 7]),
            .cram_a (a), .cram_dq_o (dq_o), .cram_dq_oe (dq_oe), .cram_dq_i (dq),
            .cram_clk (ck), .cram_adv_n (adv_n), .cram_cre (cre),
            .cram_ce0_n (ce0_n), .cram_ce1_n (ce1_n), .cram_oe_n (oe_n),
            .cram_we_n (we_n), .cram_ub_n (ub_n), .cram_lb_n (lb_n)
        );

        psram_model #(.LAT_W (LAT_W), .LAT_R (LAT_R)) u_dev (
            .clk (clk_fast), .a (a), .dq_i (dq_o), .dq_oe_i (dq_oe),
            .dq_o (dq_m), .dq_oe_o (oe_m), .cram_clk (ck), .adv_n (adv_n),
            .cre (cre), .ce0_n (ce0_n), .oe_n (oe_n), .we_n (we_n),
            .ub_n (ub_n), .lb_n (lb_n), .violations (viol[c]), .bcr (bcr)
        );
    end endgenerate

    assign {fb1_ack, fb0_ack}     = ak;
    assign {fb1_rdata, fb0_rdata} = rd;
    assign ready      = &rdy;
    assign violations = viol[0] + viol[1];

endmodule

`default_nettype wire
