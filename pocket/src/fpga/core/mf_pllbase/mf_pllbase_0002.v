// Kaneko16 for Analogue Pocket — the core PLL.
//
// This is the template's Qsys-generated wrapper with its parameters edited by
// hand. The instance names (mf_pllbase -> mf_pllbase_inst -> altera_pll_i)
// are unchanged ON PURPOSE: core_constraints.sdc names the output counters
// by that path, and an .sdc that matches nothing constrains nothing without
// an error (upstream's Kaneko16.sdc tells that story at length).
//
// FREQUENCIES, FROM clk_74a = 74.25 MHz
//
// One VCO for everything, so every output is an integer divide of it and all
// of them are mutually synchronous:
//
//     VCO = 74.25 MHz x 128 / 11 = 864 MHz   (PFD 6.75 MHz, integer mode)
//
//   outclk_0   48 MHz  /18   core clock: the board, its servants, the loader
//   outclk_1   96 MHz  /9    SDRAM controller (kaneko_sdram), as upstream
//   outclk_2   96 MHz  /9    SDRAM pin clock, 180 degrees (5208 ps) behind
//   outclk_3    6 MHz  /144  APF video_rgb_clock (= the board's ce_pix rate)
//   outclk_4    6 MHz  /144  video_rgb_clock_90, 90 degrees (41667 ps)
//
// All are exact. 48 and 96 are the clocks upstream closes at, and the 2:1
// pair is what kaneko_sdram_x2 assumes (edges aligned, not a CDC). 6 MHz is
// the board's pixel rate, so the APF pixel clock carries exactly one pixel
// per cycle with no skip.
//
// WHY THE SDRAM PIN CLOCK IS ITS OWN OUTPUT
//
// Upstream drives SDRAM_CLK from a phase-shifted PLL output rather than
// `~clk_sdram`, because an inverter put the pin clock through general fabric
// with whatever skew the fitter left, while a PLL output has a fixed phase.
// The same holds here, with one more step: core_top.v forwards this clock
// through a DDIO output register (pin_ddio_clk, data 1/0), the same kind of
// I/O-cell register the command and address pins come from, so clock and
// command leave the FPGA through matched paths and the 180 degrees set here
// is the 180 degrees the device sees. The phase is 36 VCO eighth-steps
// (144.7 ps each), exact.
//
// fractional_vco_multiplier is "false": every ratio above is an integer, and
// integer mode avoids the fractional PLL's extra jitter.

`timescale 1ns/10ps
module  mf_pllbase_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'outclk3'
	output wire outclk_3,

	// interface 'outclk4'
	output wire outclk_4,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("normal"),
		.number_of_clocks(5),
		.output_clock_frequency0("48.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("96.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("96.000000 MHz"),
		.phase_shift2("5208 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("6.000000 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("6.000000 MHz"),
		.phase_shift4("41667 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

