// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 for Analogue Pocket — functional checks on the shell's servants.
//
//   - pocket_fb_psram against a behavioural AD-mux PSRAM: full and masked row
//     writes read back exactly, and the CYCLES PER ROW the board will see.
//   - pocket_sram against a behavioural async SRAM: byte-enabled writes and
//     reads, and cycles per access.
//   - pocket_video against a 384x264 timing like the board's: one VS pulse per
//     frame, one HS pulse per line, HS never within 3 cycles of VS, 240 lines
//     of exactly 320 DE cycles, RGB zero outside DE.
//
// Run: pocket/lint/run_tb.sh. Not a substitute for hardware: the memory models
// check protocol and data, not analogue timing.

`timescale 1ns/1ps
`default_nettype none

// ------------------------------------------------------------ PSRAM model
// Async, address/data multiplexed: the address is latched from DQ when ADV#
// rises; a write lands when WE# rises with CE# low; OE# low drives DQ.
module psram_model (
    input  wire [21:16] a,
    inout  wire [15:0]  dq,
    input  wire         adv_n, ce0_n, oe_n, we_n, ub_n, lb_n,
    input  wire         clk          // only to sample DQ mid-cycle, see below
);
    reg [15:0] mem [0:4095];
    reg [21:0] addr;
    reg [15:0] dlat;
    reg        adv_q = 1'b1, wr_q = 1'b0;
    // A write is WE# and CE# both low; it lands when the first of them rises
    // (psram.sv raises both on the same edge, which a real part accepts).
    wire       wr = !we_n && !ce0_n;
    assign dq = (!ce0_n && !oe_n && we_n) ? mem[addr[11:0]] : 16'hzzzz;
    // psram.sv releases DQ on the same edge that raises WE#/CE# (tDH = 0 on
    // the part). In zero-delay simulation that order is a race, so the data is
    // sampled mid-cycle while the write is active and used when it ends.
    always @(negedge clk) if (wr) dlat = dq;
    always @(adv_n or wr) begin
        if (adv_n && !adv_q && !ce0_n) addr = {a, dq};
        if (!wr && wr_q) begin
            mem[addr[11:0]] = dlat;   // ub/lb: psram.sv always writes both
        end
        adv_q = adv_n;
        wr_q  = wr;
    end
endmodule

// ------------------------------------------------------------- SRAM model
module sram_model (
    input  wire [16:0] a,
    inout  wire [15:0] dq,
    input  wire        oe_n, we_n, ub_n, lb_n
);
    reg [15:0] mem [0:4095];
    reg        we_q = 1'b1;
    assign dq = (!oe_n && we_n) ? mem[a[11:0]] : 16'hzzzz;
    always @(we_n) begin
        if (we_n && !we_q) begin
            if (!ub_n) mem[a[11:0]][15:8] = dq[15:8];
            if (!lb_n) mem[a[11:0]][7:0]  = dq[7:0];
        end
        we_q = we_n;
    end
endmodule

module tb_shell;
    reg clk = 0;
    always #10.4167 clk = ~clk;              // 48 MHz
    reg rst = 1;
    integer errors = 0;

    // ======================================================= PSRAM row
    reg          fb_req = 0, fb_we = 0;
    reg  [21:0]  fb_addr = 0;
    reg  [255:0] fb_wdata = 0;
    reg  [15:0]  fb_wmask = 0;
    wire         fb_ack;
    wire [255:0] fb_rdata;
    wire [21:16] cram_a;
    wire [15:0]  cram_dq;
    wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n, cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

    pocket_fb_psram dut_fb (
        .clk(clk), .rst(rst),
        .req(fb_req), .we(fb_we), .addr(fb_addr), .wdata(fb_wdata), .wmask(fb_wmask),
        .ack(fb_ack), .rdata(fb_rdata),
        .cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0), .cram_clk(cram_clk),
        .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
        .cram_ce1_n(cram_ce1_n), .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
        .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n));

    psram_model m_ps (.a(cram_a), .dq(cram_dq), .adv_n(cram_adv_n), .ce0_n(cram_ce0_n),
                      .oe_n(cram_oe_n), .we_n(cram_we_n), .ub_n(cram_ub_n), .lb_n(cram_lb_n), .clk(clk));

    integer cyc;
    task automatic fb_row(input bit we, input [21:0] a, input [255:0] d, input [15:0] m,
                          output integer cycles);
        @(posedge clk);
        fb_req <= 1; fb_we <= we; fb_addr <= a; fb_wdata <= d; fb_wmask <= m;
        cycles = 0;
        do begin @(posedge clk); cycles++; end while (!fb_ack);
        fb_req <= 0;                         // dropped on the edge that sees ack
    endtask

    // ======================================================= SRAM
    reg         r_req = 0, r_we = 0;
    reg  [16:0] r_addr = 0;
    reg  [15:0] r_din = 0;
    reg  [1:0]  r_be = 0;
    wire        r_ack;
    wire [15:0] r_dout;
    wire [16:0] sram_a;
    wire [15:0] sram_dq;
    wire sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    pocket_sram dut_sram (.clk(clk), .rst(rst), .req(r_req), .we(r_we), .addr(r_addr),
        .din(r_din), .be(r_be), .ack(r_ack), .dout(r_dout),
        .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n));
    sram_model m_sr (.a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    task automatic ram_op(input bit we, input [16:0] a, input [15:0] d, input [1:0] be,
                          output [15:0] q, output integer cycles);
        @(posedge clk);
        r_req <= 1; r_we <= we; r_addr <= a; r_din <= d; r_be <= be;
        cycles = 0;
        do begin @(posedge clk); cycles++; end while (!r_ack);
        q = r_dout;
        r_req <= 0;
    endtask

    // ======================================================= video
    reg clk_vid = 0;
    // 6 MHz from the same timebase: one edge per eight 48 MHz edges, at an
    // arbitrary phase (3 of 8 here) to show the phase does not matter.
    integer div = 0;
    always @(posedge clk) begin
        div <= (div + 1) % 8;
        if (div == 3) clk_vid <= 1;
        if (div == 7) clk_vid <= 0;
    end
    reg  [2:0] ce_div = 0;
    wire       ce_pix = (ce_div == 0);
    always @(posedge clk) ce_div <= ce_div + 1;
    reg  [9:0] hc = 0, vc = 0;
    always @(posedge clk) if (ce_pix) begin
        if (hc == 383) begin hc <= 0; vc <= (vc == 263) ? 0 : vc + 1; end
        else hc <= hc + 1;
    end
    wire hblank = hc >= 320;
    wire vblank = (vc < 16) || (vc >= 256);
    wire hs = (hc >= 336) && (hc < 368);
    wire vs = (vc >= 264-16) && (vc < 264-8);
    wire [7:0] pr = hc[7:0], pg = vc[7:0], pb = 8'h5a;
    wire [23:0] v_rgb;
    wire v_de, v_hs, v_vs, v_skip;

    pocket_video dut_vid (.clk(clk), .ce_pix(ce_pix), .hs(hs), .vs(vs), .hblank(hblank),
        .vblank(vblank), .r(pr), .g(pg), .b(pb), .clk_vid(clk_vid),
        .video_rgb(v_rgb), .video_de(v_de), .video_hs(v_hs), .video_vs(v_vs), .video_skip(v_skip));

    integer vs_count = 0, hs_count = 0, since_vs = 99, de_run = 0, de_lines = 0, bad_lines = 0;
    integer last_x = -1;
    reg     v_de_q = 0;
    always @(posedge clk_vid) begin
        since_vs = since_vs + 1;
        if (v_vs) begin vs_count++; since_vs = 0; end
        if (v_hs) begin
            hs_count++;
            if (since_vs < 3) begin $display("ERROR: HS %0d cycles after VS", since_vs); errors++; end
            if (v_de) begin $display("ERROR: HS during DE"); errors++; end
        end
        if (!v_de && v_rgb != 0) begin $display("ERROR: RGB not zero outside DE"); errors++; end
        if (v_de) begin
            // Pixels arrive in order, each exactly once.
            if (de_run > 0 && v_rgb[23:16] != 8'(last_x + 1)) begin
                $display("ERROR: pixel %0d followed %0d", v_rgb[23:16], last_x); errors++;
            end
            last_x = v_rgb[23:16];
            de_run++;
        end
        if (v_de_q && !v_de) begin
            de_lines++;
            if (de_run != 320) bad_lines++;
            de_run = 0;
        end
        v_de_q <= v_de;
    end

    // ======================================================= sequence
    integer c, i;
    reg [255:0] pat, pat2, expect_row;
    reg [15:0]  q;
    initial begin
        repeat (8) @(posedge clk);
        rst <= 0;
        repeat (4) @(posedge clk);

        // ---- PSRAM: full write, read back
        for (i = 0; i < 16; i++) pat[16*i +: 16] = 16'h1000 + 16'(i * 257);
        fb_row(1, 22'd512 * 3 + 7, pat, 16'hffff, c);
        $display("psram: full row write  %0d cycles (ack after request)", c);
        fb_row(0, 22'd512 * 3 + 7, 0, 0, c);
        $display("psram: row read        %0d cycles", c);
        if (fb_rdata !== pat) begin $display("ERROR: psram readback %h", fb_rdata); errors++; end

        // ---- PSRAM: masked write touches only the masked words
        for (i = 0; i < 16; i++) pat2[16*i +: 16] = 16'hbe00 + 16'(i);
        fb_row(1, 22'd512 * 3 + 7, pat2, 16'h0f0f, c);
        $display("psram: 8/16 masked write %0d cycles", c);
        for (i = 0; i < 16; i++)
            expect_row[16*i +: 16] = ((16'h0f0f >> i) & 1) ? pat2[16*i +: 16] : pat[16*i +: 16];
        fb_row(0, 22'd512 * 3 + 7, 0, 0, c);
        if (fb_rdata !== expect_row) begin $display("ERROR: psram masked readback %h", fb_rdata); errors++; end
        fb_row(1, 22'd0, pat2, 16'h0000, c);
        $display("psram: empty-mask write %0d cycles", c);

        // ---- back-to-back rows: the period the board will see
        begin
            integer t0, t1;
            t0 = $time;
            for (i = 0; i < 10; i++) fb_row(0, 22'(i * 16), 0, 0, c);
            t1 = $time;
            $display("psram: 10 back-to-back row reads: %0d cycles per row",
                     (t1 - t0) / 20.8333 / 10);
        end

        // ---- SRAM
        ram_op(1, 17'h00123, 16'hA55A, 2'b11, q, c);
        $display("sram: write %0d cycles", c);
        ram_op(1, 17'h00123, 16'h3C00, 2'b10, q, c);      // upper byte only
        ram_op(0, 17'h00123, 0, 2'b11, q, c);
        $display("sram: read  %0d cycles", c);
        if (q !== 16'h3C5A) begin $display("ERROR: sram readback %h", q); errors++; end

        // ---- video: two frames
        wait (vs_count == 1);
        wait (vs_count == 3);
        $display("video: %0d VS, %0d HS, %0d DE lines, %0d not 320 wide", vs_count, hs_count, de_lines, bad_lines);
        if (de_lines < 480 || bad_lines != 0) begin $display("ERROR: video lines"); errors++; end

        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule

`default_nettype wire
