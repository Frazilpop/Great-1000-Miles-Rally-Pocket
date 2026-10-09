// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 for Analogue Pocket — one sprite-bitmap port (fb0 or fb1) on one
// PSRAM chip (CRAM0 or CRAM1)
//
// THE PART. AS1C8M16PL-70: 16 MB cellular RAM, ADDRESS/DATA MULTIPLEXED — the
// low sixteen address bits share the DQ pins and are latched by ADV#, so every
// access starts with an address phase on the data bus. Two 8 MB dies sit
// behind one set of pins, selected by CE0#/CE1#. The bitmap is 240 lines of
// 512 words = 122,880 words, well inside die 0 (4M words), so CE1# is never
// used and `bank_sel` is tied low.
//
// THIS IS THE ASYNCHRONOUS SERVANT, DELIBERATELY FIRST.
//
// The chip powers up in asynchronous mode and agg23's psram.sv (MIT,
// third_party/pocket-utils) drives it there with no configuration register
// write at all, so this is the shortest path to a bitmap that works. The board
// does not care how a row is moved, only how long it takes (fbN),
// so a synchronous-burst servant can replace this one behind the same
// ports.
//
// WHAT A ROW COSTS, AT 48 MHz
//
// psram.sv derives its cycle counts from CLOCK_SPEED. At 48 MHz (20.83 ns):
//
//   write  ADV# low 1 cycle, address hold 1, bus turn 1, data + WE# to the
//          end of tWC (70 ns -> 4 cycles from ADV#): state 0 -> 5, then one
//          cycle back in idle.                                   = 6 cycles
//   read   ADV# 1, address hold 1, OE# at +3, data sampled at +5 (104 ns
//          after ADV#, against tAA 70 ns + pin delays):          = 6 cycles
//
// Words are issued back to back: the next one is presented the cycle psram.sv
// drops `busy`, so it is accepted on the very next edge. MEASURED in
// pocket/lint/tb_shell.sv (pocket/lint/run_tb.sh):
//
//   full row, read or write      99 cycles from req to ack   (2.06 us)
//   rows back to back           100 cycles per row, with the dead cycle
//   write, 8 of 16 words masked  51 cycles: a masked word is never issued
//   write, nothing masked in      3 cycles
//
// WHAT THAT MEANS FOR THE BOARD. Scan-out reads AND clears a 320-pixel line on
// the chip that is not being drawn: 20 rows read + 20 rows written = 40 x 100
// = 4,000 cycles, against a 384 x 8 = 3,072-cycle line. Asynchronous mode at
// this clock is about 30% short of keeping up with read-and-clear on its own,
// before the draw side has used the other chip at all. That is the number
// that decides when the synchronous-burst servant is needed.
//
// ONE THING ONLY HARDWARE WILL SETTLE. psram.sv ends a write by raising WE#
// and CE# and releasing DQ on the same clock edge. The part's tDH is 0 ns, so
// this is legal on paper and depends on the I/O cell turning DQ off no sooner
// than it raises WE#. agg23 runs this module on real Pockets; it is noted here
// because the bitmap is the first thing to look at if sprites tear.

`default_nettype none

module pocket_fb_psram (
    input  wire         clk,           // 48 MHz core clock
    input  wire         rst,

    // board side (fbN)
    input  wire         req,
    input  wire         we,
    input  wire [21:0]  addr,
    input  wire [255:0] wdata,
    input  wire [15:0]  wmask,
    output reg          ack,
    output reg  [255:0] rdata,

    // pins
    output wire [21:16] cram_a,
    inout  wire [15:0]  cram_dq,
    input  wire         cram_wait,
    output wire         cram_clk,
    output wire         cram_adv_n,
    output wire         cram_cre,
    output wire         cram_ce0_n,
    output wire         cram_ce1_n,
    output wire         cram_oe_n,
    output wire         cram_we_n,
    output wire         cram_ub_n,
    output wire         cram_lb_n
);

    // ---------------------------------------------------------------- row
    reg         run;          // a row is in progress
    reg         dead;         // the cycle after ack: req may still be the old one
    reg         row_we;
    reg [21:0]  row_addr;
    reg [255:0] row_wdata;
    reg [15:0]  todo;         // words not yet issued
    reg [3:0]   cur;          // word in flight, for the read capture

    // Lowest pending word. A priority encode rather than a counter so a masked
    // word is skipped for free instead of costing a cycle.
    reg [3:0] next;
    integer k;
    always @(*) begin
        next = 4'd0;
        for (k = 15; k >= 0; k = k - 1)
            if (todo[k]) next = k[3:0];
    end

    wire        busy;
    wire        read_avail;
    wire [15:0] data_out;

    // Issue as soon as psram.sv is idle. It raises `busy` on the same edge it
    // accepts, so a request held one cycle too long is never taken twice.
    wire issue = run && (todo != 16'd0) && !busy;

    psram #(.CLOCK_SPEED(48.0)) u_psram (
        .clk            (clk),
        .bank_sel       (1'b0),
        .addr           (row_addr + {18'd0, next}),
        .write_en       (issue &  row_we),
        .data_in        (row_wdata[16*next +: 16]),
        .write_high_byte(1'b1),
        .write_low_byte (1'b1),
        .read_en        (issue & ~row_we),
        .read_avail     (read_avail),
        .data_out       (data_out),
        .busy           (busy),
        .cram_a         (cram_a),
        .cram_dq        (cram_dq),
        .cram_wait      (cram_wait),
        .cram_clk       (cram_clk),
        .cram_adv_n     (cram_adv_n),
        .cram_cre       (cram_cre),
        .cram_ce0_n     (cram_ce0_n),
        .cram_ce1_n     (cram_ce1_n),
        .cram_oe_n      (cram_oe_n),
        .cram_we_n      (cram_we_n),
        .cram_ub_n      (cram_ub_n),
        .cram_lb_n      (cram_lb_n)
    );

    always @(posedge clk) begin
        ack  <= 1'b0;
        dead <= 1'b0;
        if (rst) begin
            run  <= 1'b0;
            todo <= 16'd0;
        end else if (!run) begin
            if (req && !dead && !ack) begin
                run       <= 1'b1;
                row_we    <= we;
                row_addr  <= addr;
                row_wdata <= wdata;
                // A write issues only the words its mask names; a read
                // always returns all sixteen.
                todo      <= we ? wmask : 16'hffff;
            end
        end else begin
            if (issue) begin
                todo[next] <= 1'b0;
                cur        <= next;
            end
            // read_avail is high for the one cycle after psram.sv samples the
            // pins, which is also the cycle the next word is issued; `cur`
            // still names the word that just returned until this edge.
            if (read_avail) rdata[16*cur +: 16] <= data_out;

            // Finished when nothing is left to issue and the last access has
            // retired. The final read's data lands on this same edge.
            if (todo == 16'd0 && !busy) begin
                run  <= 1'b0;
                ack  <= 1'b1;
                dead <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
