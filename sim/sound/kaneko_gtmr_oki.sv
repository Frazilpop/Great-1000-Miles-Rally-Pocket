// SPDX-License-Identifier: GPL-3.0-only
// One OKI of the gtmr board, as rtl/top/kaneko_gtmr.sv wires it: jt6295 fed
// from SDRAM through kaneko_tilerom, behind the board's bank map. The SDRAM
// is the testbench's (tb_gtmr_oki.cpp), so the samples are the set's and the
// latency is what a run asks for. Built with SIMULATION for jt6295_adpcm's
// per-voice signals (sim/sound/build_gtmr_oki.sh).
`timescale 1ns/1ps
`default_nettype none

module kaneko_gtmr_oki #(parameter int unsigned SDR_AW = 25) (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,
    input  wire        chip,        // 0: OKI 0, 1: OKI 1
    input  wire        we,          // one clock, as kaneko_gtmr_bus makes it
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    input  wire [3:0]  okb,         // the chip's bank, held as the board holds it

    output wire        sdr_req,
    output wire [SDR_AW:1] sdr_addr,
    input  wire        sdr_ack,
    input  wire [63:0] sdr_dout,

    // What the serial unit does at each channel's turn
    output wire        slot,        // cen4: the turn ends on this clock
    output wire [3:0]  slot_ch,
    output wire        up_start,
    output wire        up_stop,
    output wire        busy_out,
    output wire        over,
    output wire [6:0]  phrase,
    output wire [17:0] start_addr,
    output wire [17:0] stop_addr,

    output wire        cen_sr,      // one a sample
    output wire signed [11:0] snd0,
    output wire signed [11:0] snd1,
    output wire signed [11:0] snd2,
    output wire signed [11:0] snd3
);
    localparam [SDR_AW:1] W_OKI1 = SDR_AW'(25'h0800000);    // byte 0x1000000
    localparam [SDR_AW:1] W_OKI2 = SDR_AW'(25'h0880000);    // byte 0x1100000

    wire [17:0] a;
    wire [7:0]  d;
    wire        ok;

    // kaneko_gtmr.sv's lines, as init_gtmr() installs the banks.
    wire [19:0] oki0_bank_base = (okb < 4'd3) ? 20'h30000 : {okb, 16'h0000};
    wire [23:0] oki0_region = (a < 18'h30000) ? {6'd0, a}
                            : {4'd0, oki0_bank_base + {2'b00, a - 18'h30000}};
    wire [23:0] oki1_region = {5'd0, okb[0], a};

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_rom (
        .clk(clk), .rst(rst),
        .req_addr(chip ? oki1_region : oki0_region),
        .base_addr(chip ? W_OKI2 : W_OKI1),
        .req_data(d), .port_ready(ok),
        .sdr_req(sdr_req), .sdr_addr(sdr_addr),
        .sdr_ack(sdr_ack), .sdr_dout(sdr_dout)
    );

    jt6295 u_oki (
        .rst(rst), .clk(clk), .cen(cen), .ss(1'b0),
        .wrn(~we), .din(din), .dout(dout),
        .rom_addr(a), .rom_data(d), .rom_ok(ok),
        .sound(), .sample()
    );

    assign slot       = u_oki.cen_sr4;
    assign slot_ch    = u_oki.u_serial.ch;
    assign up_start   = u_oki.u_serial.up_start;
    assign up_stop    = u_oki.u_serial.up_stop;
    assign busy_out   = u_oki.u_serial.busy_out;
    assign over       = u_oki.u_serial.over;
    assign phrase     = u_oki.u_ctrl.phrase;
    assign start_addr = u_oki.start_addr;
    assign stop_addr  = u_oki.stop_addr;
    assign cen_sr     = u_oki.cen_sr;
    assign snd0       = u_oki.u_adpcm.snd0;
    assign snd1       = u_oki.u_adpcm.snd1;
    assign snd2       = u_oki.u_adpcm.snd2;
    assign snd3       = u_oki.u_adpcm.snd3;
endmodule
`default_nettype wire
