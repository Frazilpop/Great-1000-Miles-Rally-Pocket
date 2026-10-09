// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 for Analogue Pocket — board video (48 MHz + ce_pix) to the APF
// video bus (6 MHz pixel clock)
//
// TWO PROBLEMS, KEPT APART
//
// 1. Getting each pixel from the 48 MHz domain into the 6 MHz one exactly
//    once.
//
//    Both clocks come from one PLL and one VCO (864 MHz, /18 and /144), so a
//    6 MHz rising edge always coincides with a 48 MHz rising edge. That makes
//    this a SYNCHRONOUS crossing, timed by the fitter like any other path —
//    there is no synchroniser here and none is wanted.
//
//    What the PLL cannot promise is WHICH of the eight 48 MHz edges in a pixel
//    the 6 MHz edge lands on: ce_pix is the board's own divide-by-eight, and
//    its counter starts wherever reset leaves it. So the pixel is captured
//    into `hold` on ce_pix and held for all eight cycles, and the 6 MHz edge
//    samples `hold` wherever it falls. Both run at exactly one event per 166.7
//    ns, so every pixel is sampled once — never dropped, never doubled —
//    whatever the phase. The phase only moves the latency, by up to one pixel.
//    The one alignment that needs thought, a 6 MHz edge on the same edge that
//    reloads `hold`, sees the OLD pixel, deterministically, because that is
//    an ordinary hold-time check the fitter closes. core_constraints.sdc says
//    why the path is timed rather than cut.
//
// 2. Meeting the APF's rules for the bus (Analogue: Bus Communication, VIDEO).
//
//      - VS is a single-cycle pulse once per frame, HS a single-cycle pulse
//        once per line: the board's levels are turned into rising-edge pulses.
//      - "HS may not be immediately sent until 3 cycles after VS": the board
//        raises vsync at the start of a line (hcnt 0) and hsync in horizontal
//        blanking, hundreds of pixels apart, so this never binds on today's
//        timing; it is enforced anyway, by holding an HS back until the third
//        cycle after VS, because the timing is per board and may move.
//      - DE high for the whole active line and RGB zero whenever DE is low.
//      - One clear cycle between HS and DE either way: the board's hsync sits
//        inside a 64-pixel blanking window, so this holds by construction and
//        is not re-checked here.

`default_nettype none

module pocket_video (
    input  wire        clk,            // 48 MHz core clock
    input  wire        ce_pix,
    input  wire        hs, vs, hblank, vblank,
    input  wire [7:0]  r, g, b,

    input  wire        clk_vid,        // 6 MHz, same PLL as clk
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_hs,
    output reg         video_vs,
    output wire        video_skip
);

    // ------------------------------------------------------------ 48 MHz
    reg [23:0] hold_rgb;
    reg        hold_de, hold_hs, hold_vs;

    always @(posedge clk) if (ce_pix) begin
        hold_rgb <= {r, g, b};
        hold_de  <= ~(hblank | vblank);
        hold_hs  <= hs;
        hold_vs  <= vs;
    end

    // ------------------------------------------------------------- 6 MHz
    reg [23:0] s_rgb;
    reg        s_de, s_hs, s_vs;
    reg        s_hs_d, s_vs_d;
    reg [1:0]  since_vs;               // saturates at 3
    reg        hs_pend;

    always @(posedge clk_vid) begin
        s_rgb  <= hold_rgb;
        s_de   <= hold_de;
        s_hs   <= hold_hs;
        s_vs   <= hold_vs;
        s_hs_d <= s_hs;
        s_vs_d <= s_vs;

        video_vs <= s_vs & ~s_vs_d;
        if (s_vs & ~s_vs_d) since_vs <= 2'd0;
        else if (since_vs != 2'd3) since_vs <= since_vs + 2'd1;

        // An HS that would land inside the three cycles after VS waits for
        // the third. `since_vs` is the count as of the previous cycle, so
        // `since_vs >= 2` here means this HS goes out three cycles after the
        // VS pulse.
        video_hs <= 1'b0;
        if ((s_hs & ~s_hs_d) || hs_pend) begin
            if (since_vs >= 2'd2 && !(s_vs & ~s_vs_d)) begin
                video_hs <= 1'b1;
                hs_pend  <= 1'b0;
            end else begin
                hs_pend  <= 1'b1;
            end
        end

        video_de  <= s_de;
        video_rgb <= s_de ? s_rgb : 24'h000000;
    end

    assign video_skip = 1'b0;

    initial begin
        since_vs = 2'd3;
        hs_pend  = 1'b0;
    end

endmodule

`default_nettype wire
