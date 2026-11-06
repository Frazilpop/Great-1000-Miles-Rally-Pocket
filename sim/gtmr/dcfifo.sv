// SPDX-License-Identifier: GPL-3.0-or-later
// A stand-in for Intel's dcfifo, for the board harness's --pocket model only:
// two clocks, no showahead, rdempty straight from the pointers.
module dcfifo #(
    parameter clocks_are_synchronized = "FALSE",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_numwords = 4,
    parameter lpm_showahead = "OFF",
    parameter lpm_type = "dcfifo",
    parameter lpm_width = 8,
    parameter lpm_widthu = 2,
    parameter overflow_checking = "OFF",
    parameter rdsync_delaypipe = 5,
    parameter underflow_checking = "OFF",
    parameter use_eab = "OFF",
    parameter wrsync_delaypipe = 5
) (
    input  wire [lpm_width-1:0]  data,
    input  wire                  rdclk,
    input  wire                  rdreq,
    input  wire                  wrclk,
    input  wire                  wrreq,
    output reg  [lpm_width-1:0]  q,
    output wire                  rdempty,
    input  wire                  aclr,
    output wire                  eccstatus,
    output wire                  rdfull,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire                  wrempty,
    output wire                  wrfull,
    output wire [lpm_widthu-1:0] wrusedw
);
    reg [lpm_width-1:0] mem [0:255];
    reg [7:0] wp = 0, rp = 0;
    always @(posedge wrclk) if (wrreq) begin mem[wp] <= data; wp <= wp + 8'd1; end
    always @(posedge rdclk) if (rdreq && rp != wp) begin q <= mem[rp]; rp <= rp + 8'd1; end
    assign rdempty = rp == wp;
    assign eccstatus = 1'b0; assign rdfull = 1'b0; assign wrempty = rp == wp; assign wrfull = 1'b0;
    assign rdusedw = '0; assign wrusedw = '0;
endmodule
