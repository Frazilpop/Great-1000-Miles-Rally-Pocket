# Kaneko16 (gtmr board) for Analogue Pocket — core timing constraints
#
# Read by apf/apf_constraints.sdc (Analogue's, unmodified) after it has
# created clk_74a / clk_74b / bridge_spiclk and run derive_pll_clocks. Not
# listed in ap_core.qsf, so it is applied once.

# ------------------------------------------------------------------ clocks
#
# The PLL's output counters, by the path derive_pll_clocks gives them. The
# path is core_top's `mp1` -> mf_pllbase's `mf_pllbase_inst` -> `altera_pll_i`;
# renaming any level silently breaks every line below, so it is checked.
set pll_path {ic|mp1|mf_pllbase_inst|altera_pll_i}
set clk_core     [get_clocks -nowarn "${pll_path}|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_sdram    [get_clocks -nowarn "${pll_path}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_sdram_ps [get_clocks -nowarn "${pll_path}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_vid      [get_clocks -nowarn "${pll_path}|general\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_vid90    [get_clocks -nowarn "${pll_path}|general\[4\].gpll~PLL_OUTPUT_COUNTER|divclk"]

# An empty collection turns set_clock_groups and set_multicycle_path into
# silent no-ops and the build "passes" untimed — upstream's Kaneko16.sdc has
# the story. Here that is an error, not a warning.
foreach {name c} [list core $clk_core sdram $clk_sdram sdram_ps $clk_sdram_ps \
                       vid $clk_vid vid90 $clk_vid90] {
    if {[get_collection_size $c] == 0} {
        post_message -type error "core_constraints.sdc: PLL output '$name' not found under $pll_path. The constraints below would be no-ops; fix the path."
    }
}

# The SDRAM clock as the device sees it: clk_sdram_ps, forwarded through the
# DDIO output register in core_top (pin_ddio_clk, data 1/0) to the dram_clk
# pin. Quartus traces the path from the PLL counter through the I/O cell, so
# the pin-side clock carries the real output delay and the I/O constraints
# below are relative to the clock edge at the pin.
create_generated_clock -name dram_clk_pin \
    -source [get_pins "${pll_path}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    [get_ports {dram_clk}]

# ---------------------------------------------------------- clock groups
#
# clk_74a (bridge, pad bus, I2S) is the PLL's reference but is treated as
# unrelated to its outputs: 48/74.25 = 64/99, so a "synchronous" analysis
# would find a worst-case edge pair a fraction of a nanosecond apart and fail
# paths that are in fact crossed by synchronisers, dcfifos and dual-clock
# RAMs, and never by plain logic. Every one of them is listed in core_top.v.
#
# The PLL outputs are ONE group and are timed against each other, because
# three crossings depend on it:
#
#   48 <-> 96   kaneko_sdram_x2: the 2:1 pair from one VCO, edges aligned,
#               not a CDC. Cut these and the adapter's assumptions go untimed.
#   48 -> 6     pocket_video: `hold` (48 MHz, loaded on ce_pix) sampled on
#               every 6 MHz edge. Every 6 MHz edge coincides with a 48 MHz
#               edge, so this is a normal synchronous path with a 20.8 ns
#               setup relationship and a 0 ns hold relationship. Timing it is
#               what makes "a 6 MHz edge on the reload edge sees the old pixel"
#               true in silicon, not just in the RTL comment.
#   96 -> pin   the SDRAM I/O below, against dram_clk_pin.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {clk_74b}] \
    -group [get_clocks {bridge_spiclk}] \
    -group [add_to_collection [get_clocks "${pll_path}|*"] [get_clocks {dram_clk_pin}]]

# ------------------------------------------------------------------ SDRAM
#
# AS4C32M16MSA-6 (1.8 V mobile SDR). Figures from the -6 grade of the same
# family's sheet (AS4C16M16MSA-6, Rev 1.0), CL = 2 as kaneko_sdram programs:
#
#   tCMS/tCAS  command/address setup  2.0 ns     tCMH/tCAH  hold  1.0 ns
#   tCDS       data-in setup          2.0 ns     tCDH       hold  1.0 ns
#   tAC(2)     access from clock      6.0 ns max tOH        hold  2.5 ns min
#
# Board traces are short (the SDRAM sits beside the FPGA); 0.2 ns allowed for
# a flight each way.
set sdr_trace 0.2

set sdr_out [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max [expr {2.0 + $sdr_trace}] $sdr_out
set_output_delay -clock dram_clk_pin -min [expr {-1.0}]              $sdr_out

# Commands leave on a clk_sdram edge and are sampled by the device on the next
# dram_clk_pin edge, half a period later. That is the default relationship, so
# no exception is needed for outputs.

# READ DATA, AND WHY IT IS A TWO-CYCLE PATH.
#
# Data appears tAC after a device clock edge, and the device clock is half a
# period behind clk_sdram plus the I/O cell's output delay. The default
# analysis would latch it on the very next clk_sdram edge — half a period
# after launch — which nothing could meet. It is captured one full cycle later
# instead: a launch on dram_clk_pin at t is latched by clk_sdram at t + 1.5T.
# Measured from the READ command, that is the fourth clk_sdram edge into dq_r,
# which is cap_depth = CL + 3, i.e. kaneko_sdram's rd_lat_sel = 3 — the menu's
# default (core_top.v, RD_LAT_0). If this constraint passes, the default is
# the right edge on paper; the other menu entries move the edge by whole
# cycles for a board that disagrees with the paper, as upstream's did.
set_input_delay -clock dram_clk_pin -max [expr {6.0 + 2 * $sdr_trace}] [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clk_pin -min 2.5                           [get_ports {dram_dq[*]}]
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk_sdram -setup -end 2
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk_sdram -hold  -end 1

# CKE is a constant 1 from kaneko_sdram; it has no timing to meet.
set_false_path -to [get_ports {dram_cke}]

# ------------------------------------------------------------ SRAM, PSRAM
#
# Asynchronous parts: there is no clock at the device to time against, so the
# servants hold every signal for whole 48 MHz cycles and sample with at least
# a cycle of margin, and the numbers are written down beside the state
# machines (pocket_sram.sv; pocket_fb_psram.sv and agg23's psram.sv). The
# fitter is told not to second-guess them.
set_false_path -to   [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set_false_path -from [get_ports {sram_dq[*]}]
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]
