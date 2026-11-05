// SPDX-License-Identifier: GPL-3.0-only
// Three OKIs of the gtmr board on one clock, for the save-state chain
// (jt6295-state.patch): A and B play the game's writes, C its own. At a save
// point all three are stopped at the dead phase; A's chain is moved round
// once, fed back to itself, with C taking the same bits, so C becomes A while
// A stays as it was. B is only stopped, as long. From the let-go all three
// must give the same sound, sample and status on every clock
// (sim/sound/tb_oki_state3.cpp). Each has its own SDRAM port.
`timescale 1ns/1ps
`default_nettype none

module kaneko_oki_state3 #(parameter int unsigned SDR_AW = 25) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  cen,         // A, B, C
    input  wire [2:0]  we,
    input  wire [23:0] din,
    output wire [23:0] dout,
    input  wire [11:0] okb,

    output wire [2:0]          sdr_req,
    output wire [SDR_AW:1]     sdr_addr0, sdr_addr1, sdr_addr2,
    input  wire [2:0]          sdr_ack,
    input  wire [191:0]        sdr_dout,

    output wire [41:0] sound,
    output wire [2:0]  sample,
    output wire [2:0]  cen_sr,
    output wire [11:0] busy,        // each chip's busy bits, its status' low nibble

    input  wire [2:0]  ss_scan,
    input  wire [2:0]  ss_gsh,
    input  wire [2:0]  ss_gi,
    output wire [2:0]  ss_go,
    output wire [2:0]  ss_quiet,
    output wire [2:0]  ss_phase
);
    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : g_oki
            wire [SDR_AW:1] a;
            kaneko_gtmr_oki #(.SDR_AW(SDR_AW)) u (
                .clk(clk), .rst(rst), .cen(cen[i]), .chip(1'b0),
                .we(we[i]), .din(din[i*8 +: 8]), .dout(dout[i*8 +: 8]), .okb(okb[i*4 +: 4]),
                .sdr_req(sdr_req[i]), .sdr_addr(a),
                .sdr_ack(sdr_ack[i]), .sdr_dout(sdr_dout[i*64 +: 64]),
                .slot(), .slot_ch(), .up_start(), .up_stop(), .busy_out(), .over(),
                .phrase(), .start_addr(), .stop_addr(),
                .cen_sr(cen_sr[i]), .snd0(), .snd1(), .snd2(), .snd3(),
                .sound(sound[i*14 +: 14]), .sample(sample[i]),
                .ss_scan(ss_scan[i]), .ss_gsh(ss_gsh[i]), .ss_gi(ss_gi[i]), .ss_go(ss_go[i]),
                .ss_quiet(ss_quiet[i]), .ss_phase(ss_phase[i])
            );
            assign busy[i*4 +: 4] = u.u_oki.busy;
        end
    endgenerate
    assign sdr_addr0 = g_oki[0].a;
    assign sdr_addr1 = g_oki[1].a;
    assign sdr_addr2 = g_oki[2].a;
endmodule
`default_nettype wire
