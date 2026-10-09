// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 for Analogue Pocket — the board's `ram` port on the Pocket's SRAM
//
// THE PART. AS6C2016-55: 128K x 16 asynchronous SRAM, 3.3 V, 55 ns. No chip
// select reaches the FPGA (it is tied active on the board), so a cycle is
// framed by OE# for reads and WE# for writes, with UB#/LB# picking the bytes.
//
// WHY IT COUNTS CYCLES INSTEAD OF BEING TIMED BY THE FITTER
//
// An async SRAM has no clock to time against, so the honest constraint is a
// cycle count with the margin written down, and the .sdc cuts these pins
// (see core_constraints.sdc). At 48 MHz (20.83 ns), every figure below has a
// whole cycle or more to spare:
//
//   read   address + OE# out at edge A, data sampled at edge A+4 = 83.3 ns.
//          Needs tAA 55 ns + FPGA clock-to-pin (~5 ns) + pin-to-register
//          (~2 ns) = ~62 ns. 21 ns spare. A+3 (62.5 ns) would be a coin toss,
//          which is why it is not A+3.
//   write  address, data and UB#/LB# out at edge A; WE# low from A+1 to A+4.
//            tAS 0       address settles a whole cycle before WE# falls
//            tWP 45 ns   WE# low for 3 cycles = 62.5 ns
//            tAW 50 ns   address valid 83 ns before WE# rises
//            tDW 25 ns   data valid 83 ns before WE# rises
//            tDH 0, tWR 0  data and address held one more cycle after WE# rises
//
// So a read or write is acknowledged at A+4 and the next request is taken no
// earlier than A+6 (see DEAD below): about 125 ns per access.
//
// HANDSHAKE (`ram`)
//
// The board holds req as a level until ack, and ack is a one-cycle pulse with
// dout valid in that same cycle. A requester that lowers req on the edge that
// SAMPLES ack still shows req high for that edge, so the servant spends one
// dead cycle after ack before it looks at req again — the same hazard
// kaneko_sdram_x2 documents as "a request held across its own acknowledge must
// not be taken twice". The contract allows exactly this: a new request is
// accepted no earlier than the cycle after ram_ack.

`default_nettype none

module pocket_sram (
    input  wire        clk,            // 48 MHz core clock
    input  wire        rst,

    // board side
    input  wire        req,
    input  wire        we,
    input  wire [16:0] addr,
    input  wire [15:0] din,
    input  wire [1:0]  be,             // [1] = upper byte
    output reg         ack,
    output reg  [15:0] dout,

    // pins
    output reg  [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n,
    output reg         sram_we_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_RD   = 3'd1,
                     S_WR   = 3'd2,
                     S_WREND= 3'd3,
                     S_DEAD = 3'd4;

    reg [2:0]  state;
    reg [2:0]  cnt;
    reg [15:0] dq_o;
    reg        dq_oe;

    assign sram_dq = dq_oe ? dq_o : 16'hzzzz;

    always @(posedge clk) begin
        ack <= 1'b0;
        if (rst) begin
            state     <= S_IDLE;
            cnt       <= 3'd0;
            dq_oe     <= 1'b0;
            sram_oe_n <= 1'b1;
            sram_we_n <= 1'b1;
            sram_ub_n <= 1'b1;
            sram_lb_n <= 1'b1;
        end else begin
            case (state)
            S_IDLE: if (req) begin
                // Edge A. Everything but WE# goes out now.
                sram_a <= addr;
                cnt    <= 3'd0;
                if (we) begin
                    dq_o      <= din;
                    dq_oe     <= 1'b1;
                    sram_ub_n <= ~be[1];
                    sram_lb_n <= ~be[0];
                    state     <= S_WR;
                end else begin
                    // Both bytes on a read: the board picks its half.
                    sram_oe_n <= 1'b0;
                    sram_ub_n <= 1'b0;
                    sram_lb_n <= 1'b0;
                    state     <= S_RD;
                end
            end

            S_RD: begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin                  // edge A+4
                    dout      <= sram_dq;
                    ack       <= 1'b1;
                    sram_oe_n <= 1'b1;
                    sram_ub_n <= 1'b1;
                    sram_lb_n <= 1'b1;
                    state     <= S_DEAD;
                end
            end

            S_WR: begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd0) sram_we_n <= 1'b0;    // edge A+1
                if (cnt == 3'd3) begin                  // edge A+4
                    sram_we_n <= 1'b1;
                    ack       <= 1'b1;
                    state     <= S_WREND;
                end
            end

            // One cycle of data and byte-lane hold after WE# rises (tDH, tWR).
            // This is also the dead cycle after ack, so the next request is
            // still not taken before A+6.
            S_WREND: begin
                dq_oe     <= 1'b0;
                sram_ub_n <= 1'b1;
                sram_lb_n <= 1'b1;
                state     <= S_IDLE;
            end

            S_DEAD: state <= S_IDLE;

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
