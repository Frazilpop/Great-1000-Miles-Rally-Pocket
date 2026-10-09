// Lint-only behavioural stand-ins for the Intel primitives the shell uses.
`timescale 1ns/1ps
// Port lists match the instantiations; behaviour is just enough to elaborate.
// Never part of a Quartus build.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */
module altera_pll #(
    parameter fractional_vco_multiplier = "false",
    parameter reference_clock_frequency = "",
    parameter operation_mode = "",
    parameter number_of_clocks = 1,
    parameter output_clock_frequency0 = "", parameter phase_shift0 = "", parameter duty_cycle0 = 50,
    parameter output_clock_frequency1 = "", parameter phase_shift1 = "", parameter duty_cycle1 = 50,
    parameter output_clock_frequency2 = "", parameter phase_shift2 = "", parameter duty_cycle2 = 50,
    parameter output_clock_frequency3 = "", parameter phase_shift3 = "", parameter duty_cycle3 = 50,
    parameter output_clock_frequency4 = "", parameter phase_shift4 = "", parameter duty_cycle4 = 50,
    parameter output_clock_frequency5 = "", parameter phase_shift5 = "", parameter duty_cycle5 = 50,
    parameter output_clock_frequency6 = "", parameter phase_shift6 = "", parameter duty_cycle6 = 50,
    parameter output_clock_frequency7 = "", parameter phase_shift7 = "", parameter duty_cycle7 = 50,
    parameter output_clock_frequency8 = "", parameter phase_shift8 = "", parameter duty_cycle8 = 50,
    parameter output_clock_frequency9 = "", parameter phase_shift9 = "", parameter duty_cycle9 = 50,
    parameter output_clock_frequency10 = "", parameter phase_shift10 = "", parameter duty_cycle10 = 50,
    parameter output_clock_frequency11 = "", parameter phase_shift11 = "", parameter duty_cycle11 = 50,
    parameter output_clock_frequency12 = "", parameter phase_shift12 = "", parameter duty_cycle12 = 50,
    parameter output_clock_frequency13 = "", parameter phase_shift13 = "", parameter duty_cycle13 = 50,
    parameter output_clock_frequency14 = "", parameter phase_shift14 = "", parameter duty_cycle14 = 50,
    parameter output_clock_frequency15 = "", parameter phase_shift15 = "", parameter duty_cycle15 = 50,
    parameter output_clock_frequency16 = "", parameter phase_shift16 = "", parameter duty_cycle16 = 50,
    parameter output_clock_frequency17 = "", parameter phase_shift17 = "", parameter duty_cycle17 = 50,
    parameter pll_type = "", parameter pll_subtype = ""
)(
    input  wire rst,
    output wire [number_of_clocks-1:0] outclk,
    output wire locked,
    output wire fboutclk,
    input  wire fbclk,
    input  wire refclk
);
    assign outclk = {number_of_clocks{refclk}};
    assign locked = 1'b1;
    assign fboutclk = 1'b0;
endmodule

module altddio_out #(
    parameter extend_oe_disable = "", parameter intended_device_family = "",
    parameter invert_output = "", parameter lpm_hint = "", parameter lpm_type = "",
    parameter oe_reg = "", parameter power_up_high = "", parameter width = 1
)(
    input  wire [width-1:0] datain_h, datain_l,
    input  wire outclock, aclr, aset, oe, outclocken, sclr, sset,
    output wire oe_out,
    output wire [width-1:0] dataout
);
    assign dataout = outclock ? datain_h : datain_l;
    assign oe_out = oe;
endmodule

module dcfifo #(
    parameter clocks_are_synchronized = "", parameter intended_device_family = "",
    parameter lpm_numwords = 4, parameter lpm_showahead = "", parameter lpm_type = "",
    parameter lpm_width = 1, parameter lpm_widthu = 2, parameter overflow_checking = "",
    parameter rdsync_delaypipe = 5, parameter underflow_checking = "", parameter use_eab = "",
    parameter wrsync_delaypipe = 5
)(
    input  wire [lpm_width-1:0] data,
    input  wire rdclk, rdreq, wrclk, wrreq, aclr,
    output reg  [lpm_width-1:0] q,
    output wire rdempty, rdfull, wrempty, wrfull, eccstatus,
    output wire [lpm_widthu-1:0] rdusedw, wrusedw
);
    assign rdempty = 1'b1;
    always @(posedge rdclk) if (rdreq) q <= data;
endmodule

// apf/mf_datatable.v wraps altsyncram; stand in for the wrapper itself.
module mf_datatable (
    input  wire [7:0]  address_a, address_b,
    input  wire        clock_a, clock_b,
    input  wire [31:0] data_a, data_b,
    input  wire        wren_a, wren_b,
    output reg  [31:0] q_a, q_b
);
    reg [31:0] mem [256];
    always @(posedge clock_a) begin if (wren_a) mem[address_a] <= data_a; q_a <= mem[address_a]; end
    always @(posedge clock_b) begin if (wren_b) mem[address_b] <= data_b; q_b <= mem[address_b]; end
endmodule
