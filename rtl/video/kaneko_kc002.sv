// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — KC-002 sprites for the gtmr board
//
// The chip MAME calls 'type 1' (kaneko_spr.cpp): 1024 sprites of 16x16x8,
// drawn into a bitmap that the mixer reads back. On MiSTer this was out of
// reach: the bitmap fits neither block RAM nor the
// SDRAM bandwidth. On the Pocket it lives in the two PSRAM chips, one buffer
// per chip, so the buffer being drawn and the buffer being shown never share
// a bus.
//
// WHAT THE BITMAP HAS TO HOLD
//
// For KC-002 `keep_sprites` never applies (regs_w sets it for type 0 only), so
// every frame is: clear, then draw all 1024 sprites. MAME draws them last to
// first with an "already drawn" mask; drawing first to last and letting later
// sprites overwrite gives the same picture, so there is no mask plane. Only
// the visible 320x240 is ever touched, because MAME clips to the cliprect.
//
// NOTHING IS EVER CLEARED
//
// Clearing 76,800 words of PSRAM per frame costs more than drawing does. A
// 20-bit "dirty" word per line per buffer marks which aligned 16-pixel
// segments hold anything. Scan-out reads only dirty segments and treats the
// rest as transparent; a draw's first write to a clean segment writes all 16
// words (zeros where the sprite is transparent), later writes only the opaque
// ones. Stale PSRAM contents are therefore never visible, and starting a frame
// costs 240 writes to a small RAM instead of 76,800 to PSRAM.
//
// TIMING AGAINST MAME
//
// MAME, at scanline 224 of frame N: render the sprite list buffered at N-1's
// line 224, then buffer the live list. Its screen for frame N is composed at
// vblank from that render. The tilemap path here, like upstream's, shows
// MAME's frame N during the beam's frame N+1 (it latches scroll at the start
// of the frame). To match, the list captured at N-1@224 is drawn during frame
// N (between the swaps at line 240) and shown during frame N+1. That gives the
// draw a whole frame. If a draw overruns, the buffers do not swap: the old
// sprites stay up one more frame and the list that missed is shown late
// rather than torn.

`timescale 1ns/1ps
`default_nettype none

module kaneko_kc002 #(
    parameter int unsigned SDR_AW = 25
)(
    input  wire        clk,
    input  wire        rst,

    // Geometry: vcnt is the raw line (0 = first visible line on this board)
    input  wire        ce_pix,
    input  wire [9:0]  hcnt,
    input  wire [9:0]  vcnt,

    // Live sprite RAM read port (kaneko_gtmr_vmem), 1-clock latency
    output logic [11:0] spr_addr,
    input  wire  [15:0] spr_q,
    output wire         spr_hold,      // snapshot in progress: CPU writes wait

    input  wire [255:0] regs_flat,     // the 16 sprite registers
    input  wire         map2,          // gtmr2: 32768 sprite codes, else 33792

    // Sprite ROM, two 64-bit line ports (left and right half of a row)
    input  wire [SDR_AW:1]       rom_base,     // word address of kan_spr
    output logic [1:0]           rom_req,
    output logic [1:0][SDR_AW:1] rom_addr,
    input  wire  [1:0]           rom_ack,
    input  wire  [1:0][63:0]     rom_dout,

    // Loader snoop, for the blank-code table
    input  wire        dl_wr,
    input  wire [24:1] dl_addr,
    input  wire [15:0] dl_data,

    // PSRAM row ports
    output logic        fb0_req,
    output logic        fb0_we,
    output logic [21:0] fb0_addr,
    output logic [255:0] fb0_wdata,
    output logic [15:0] fb0_wmask,
    input  wire         fb0_ack,
    input  wire  [255:0] fb0_rdata,

    output logic        fb1_req,
    output logic        fb1_we,
    output logic [21:0] fb1_addr,
    output logic [255:0] fb1_wdata,
    output logic [15:0] fb1_wmask,
    input  wire         fb1_ack,
    input  wire  [255:0] fb1_rdata,

    // To the mixer: the pixel at rd_x on the current line, one clock later
    input  wire [8:0]   rd_x,
    output wire [13:0]  spr_pix,       // 0 = nothing here
    output wire [1:0]   spr_prio,

    // Observability
    output logic [15:0] draw_clocks,   // clocks the last draw took, /64
    output logic [7:0]  overruns       // draws that missed their swap
);

    localparam [9:0] LINE_CAPTURE = 10'd224;   // MAME's scanline-224 interrupt
    localparam [9:0] LINE_SWAP    = 10'd240;   // first line of vblank
    localparam [9:0] V_TOTAL      = 10'd264;

    function automatic [15:0] reg_of(input [3:0] i);
        reg_of = regs_flat[i*16 +: 16];
    endfunction

    // Start of each line, once.
    wire line_start = ce_pix && (hcnt == 10'd0);

    // ================================================================ frame
    logic disp;          // PSRAM chip being shown; the other is drawn into
    logic snap_cap;      // snapshot buffer the next capture goes into
    logic snap_new;      // a captured list waits in snap[snap_cap ^ 1]... see below
    logic draw_busy, draw_done;
    logic draw_snap;     // snapshot buffer being drawn
    logic draw_go;       // pulse: start a draw

    // Capture always goes to the snapshot buffer NOT being drawn. Either the
    // draw is idle, in which case both are free, or it is running from the
    // other one. A capture that lands on an undrawn list replaces it: that
    // list was going to be shown late anyway, and the newer one is better.
    logic cap_go;
    always_ff @(posedge clk) begin
        cap_go  <= 1'b0;
        draw_go <= 1'b0;
        if (rst) begin
            disp      <= 1'b0;
            snap_new  <= 1'b0;
            draw_snap <= 1'b0;
            draw_done <= 1'b0;
            overruns  <= '0;
        end else begin
            if (line_start && vcnt == LINE_CAPTURE) begin
                cap_go   <= 1'b1;
                snap_cap <= ~draw_snap;
                snap_new <= 1'b1;
            end
            if (line_start && vcnt == LINE_SWAP) begin
                if (draw_busy) begin
                    if (overruns != 8'hff) overruns <= overruns + 8'd1;
                end else begin
                    if (draw_done) begin
                        disp      <= ~disp;
                        draw_done <= 1'b0;
                    end
                    if (snap_new) begin
                        draw_snap <= ~draw_snap;
                        snap_new  <= 1'b0;
                        draw_go   <= 1'b1;
                    end
                end
            end
            if (draw_fin) draw_done <= 1'b1;
        end
    end
    wire dbuf = ~disp;   // the chip being drawn

    // Which captured list is where, for the simulation harness: every capture
    // is numbered, the number travels with the draw, and shown_tag is the
    // number of the list on screen.
    logic [15:0] cap_tag /*verilator public_flat_rd*/;
    logic [15:0] draw_tag, done_tag;
    logic [15:0] shown_tag /*verilator public_flat_rd*/;
    always_ff @(posedge clk) begin
        if (rst) begin
            cap_tag <= '0; draw_tag <= '0; done_tag <= '0; shown_tag <= '0;
        end else begin
            if (cap_go) cap_tag <= cap_tag + 16'd1;
            if (draw_go) draw_tag <= cap_tag;
            if (draw_fin) done_tag <= draw_tag;
            if (line_start && vcnt == LINE_SWAP && !draw_busy && draw_done) shown_tag <= done_tag;
        end
    end

    // ============================================================= snapshot
    // 2 x 4K words. Copying 4096 words takes 4096 clocks (85 us); CPU writes to
    // sprite RAM wait meanwhile, so the copy is exactly the list at line 224.
    logic [15:0] snap [0:8191];
    logic        copying;
    logic [12:0] cp_cnt;          // 0..4096, one ahead of the write
    logic        cp_wv;
    logic [11:0] cp_wa;
    assign spr_hold = copying || cap_go;

    always_ff @(posedge clk) begin
        cp_wv <= 1'b0;
        if (rst) begin
            copying <= 1'b0;
        end else if (cap_go) begin
            copying <= 1'b1;
            cp_cnt  <= '0;
        end else if (copying) begin
            if (cp_cnt[12]) copying <= 1'b0;
            else begin
                cp_cnt <= cp_cnt + 13'd1;
                cp_wv  <= 1'b1;
                cp_wa  <= cp_cnt[11:0];
            end
        end
        if (cp_wv) snap[{snap_cap, cp_wa}] <= spr_q;
    end
    always_comb spr_addr = cp_cnt[11:0];

    // ========================================================= blank table
    // One bit per sprite code: 1 = all 256 bytes are zero. Built while the ROM
    // loads, from the words the loader writes. Lets the draw skip the
    // hundreds of slots a frame that hold an empty tile without fetching them.
    localparam [24:1] SPR_W0 = 24'h380000;    // byte 0x700000
    logic        blank [0:33791];   // 0x840000 / 256 codes
    logic        bl_any;
    wire  [24:1] dl_rel = dl_addr - SPR_W0;
    wire         dl_spr = dl_wr && (dl_addr >= SPR_W0) && (dl_rel < 24'h420000);
    always_ff @(posedge clk) begin
        if (dl_spr) begin
            if (dl_rel[7:1] == 7'h7f) begin
                blank[dl_rel[23:8]] <= !(bl_any || (dl_data != 16'd0));
                bl_any <= 1'b0;
            end else begin
                bl_any <= (dl_rel[7:1] == 7'h00) ? (dl_data != 16'd0)
                                                 : (bl_any || (dl_data != 16'd0));
            end
        end
    end

    // ================================================================ parse
    // Stage A. Walks the snapshot first to last, applying the multisprite
    // latches exactly as draw_sprites() does, and emits one job per visible
    // row of every non-blank sprite.
    typedef enum logic [2:0] {
        P_IDLE, P_CLEAR, P_READ, P_CALC, P_BLANK, P_BWAIT, P_ROWS, P_DONE
    } pstate_t;
    pstate_t pst;

    logic [10:0] p_idx;           // sprite 0..1023 (bit 10 = finished)
    logic [2:0]  p_rd;            // words requested this sprite
    logic [2:0]  p_got;           // words received
    /* verilator lint_off UNUSEDSIGNAL */   // attr bit 10 has no known use
    logic [15:0] w_attr, w_code, w_x, w_y;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] snap_q;
    logic [12:0] snap_ra;
    always_ff @(posedge clk) snap_q <= snap[snap_ra];

    // The latches
    logic [15:0] l_x, l_y, l_xo, l_yo;
    logic [16:0] l_code;          // 17 bits: the bloodwar bit is latched too
    logic [5:0]  l_color;
    logic [1:0]  l_prio;
    logic        l_flipx, l_flipy;

    // This sprite, resolved
    logic [16:0] s_code;
    logic [5:0]  s_color;
    logic [1:0]  s_prio;
    logic        s_flipx, s_flipy;
    logic signed [9:0] s_sx, s_sy;
    logic [3:0]  s_r, s_rend;     // current and last row
    logic [16:0] s_elem;          // code mod element count

    // Element count, then code mod it. Codes reach 17 bits through the
    // bloodwar bit (y & 1) << 16, so up to three subtractions.
    wire [16:0] n_elem = map2 ? 17'd32768 : 17'd33792;
    function automatic [16:0] code_mod(input [16:0] c, input [16:0] n);
        logic [17:0] m;
        m = {1'b0, c};
        if (m >= 18'(3 * n)) m = m - 18'(3 * n);
        else if (m >= 18'(2 * n)) m = m - 18'(2 * n);
        else if (m >= 18'(n)) m = m - 18'(n);
        code_mod = m[16:0];
    endfunction

    // Clearing the draw buffer's dirty words (240 of them) is the frame's
    // whole "clear".
    logic [7:0]  clr_y;

    // Job FIFO to the fetcher
    typedef struct packed {
        logic [7:0]        y;
        logic signed [9:0] sx;
        logic [SDR_AW:1]   addr;      // word address of the left 8 pixels
        logic              flipx;
        logic [5:0]        color;
        logic [1:0]        prio;
    } job_t;
    localparam int unsigned JQ = 8;
    job_t        jq [0:JQ-1];
    logic [3:0]  jq_wp, jq_rp;
    wire         jq_full  = (jq_wp - jq_rp) == 4'(JQ);
    wire         jq_empty = (jq_wp == jq_rp);
    logic        jq_push;
    job_t        jq_in;

    logic        draw_fin;
    logic [21:0] draw_cnt;

    // Dirty RAM port A (the writer and the clear share it; see writer)
    logic        clr_we;

    always_ff @(posedge clk) begin
        jq_push  <= 1'b0;
        draw_fin <= 1'b0;
        clr_we   <= 1'b0;
        if (rst) begin
            pst       <= P_IDLE;
            draw_busy <= 1'b0;
        end else begin
            if (draw_busy && !(&draw_cnt)) draw_cnt <= draw_cnt + 22'd1;
            case (pst)
                P_IDLE: if (draw_go) begin
                    draw_busy <= 1'b1;
                    draw_cnt  <= '0;
                    clr_y     <= 8'd0;
                    pst       <= P_CLEAR;
                    l_x <= '0; l_y <= '0; l_code <= '0; l_xo <= '0; l_yo <= '0;
                    l_color <= '0; l_prio <= '0; l_flipx <= 1'b0; l_flipy <= 1'b0;
                end

                P_CLEAR: begin
                    clr_we <= 1'b1;
                    if (clr_y == 8'd239) begin
                        p_idx <= '0;
                        p_rd  <= '0;
                        p_got <= '0;
                        pst   <= P_READ;
                    end
                    clr_y <= clr_y + 8'd1;
                end

                // Four reads, one clock apart; data lands one clock later.
                P_READ: begin
                    if (p_idx[10]) begin
                        pst <= P_DONE;
                    end else begin
                        if (p_rd != 3'd4) begin
                            snap_ra <= {draw_snap, p_idx[9:0], p_rd[1:0]};
                            p_rd    <= p_rd + 3'd1;
                        end
                        // p_rd counts requests; data for request k arrives two
                        // clocks after it is set (address register + RAM).
                        if (p_rd >= 3'd2 || p_got != 3'd0) begin
                            case (p_got)
                                3'd0: w_attr <= snap_q;
                                3'd1: w_code <= snap_q;
                                3'd2: w_x    <= snap_q;
                                3'd3: w_y    <= snap_q;
                                default: ;
                            endcase
                            p_got <= p_got + 3'd1;
                            if (p_got == 3'd3) pst <= P_CALC;
                        end
                    end
                end

                P_CALC: begin : calc
                    logic [15:0] x, y, xo, yo, code;
                    logic [5:0]  color;
                    logic [1:0]  prio;
                    logic        fx, fy;
                    logic [1:0]  oi;
                    oi    = w_attr[12:11];
                    color = w_attr[5:0];
                    prio  = w_attr[7:6];
                    fy    = w_attr[8];
                    fx    = w_attr[9];
                    code  = w_code;
                    x     = w_x;
                    y     = w_y;
                    xo    = reg_of(4'(8 + oi * 2));
                    yo    = reg_of(4'(9 + oi * 2)) - reg_of(4'd1);

                    // USE_LATCHED_CODE: the latched code plus one, which
                    // replaces the bloodwar bit added in get_sprite_attributes.
                    // Otherwise the code (with that bit) is what is latched.
                    if (w_attr[15]) begin
                        l_code <= l_code + 17'd1;
                        s_code <= l_code + 17'd1;
                    end else begin
                        l_code <= {1'b0, code} + {w_y[0], 16'd0};
                        s_code <= {1'b0, code} + {w_y[0], 16'd0};
                    end
                    // USE_LATCHED_COLOR: colour, priority, offsets and (with
                    // fliptype 0, as on this board) the flips.
                    if (w_attr[14]) begin
                        color = l_color; prio = l_prio; xo = l_xo; yo = l_yo;
                        fx = l_flipx; fy = l_flipy;
                    end else begin
                        l_color <= color; l_prio <= prio; l_xo <= xo; l_yo <= yo;
                        l_flipx <= fx; l_flipy <= fy;
                    end
                    // USE_LATCHED_XY, and the position is latched either way.
                    if (w_attr[13]) begin
                        x = x + l_x;
                        y = y + l_y;
                    end
                    l_x <= x;
                    l_y <= y;

                    x = x + xo;
                    y = y + yo;
                    // Screen flip. max is 0x200 << 6 on this 320-wide board.
                    if (regs_flat[1]) begin x = 16'h8000 - x - 16'h0400; fx = ~fx; end
                    if (regs_flat[0]) begin y = 16'h8000 - y - 16'h0400; fy = ~fy; end

                    s_color <= color;
                    s_prio  <= prio;
                    s_flipx <= fx;
                    s_flipy <= fy;
                    s_sx    <= 10'($signed(x) >>> 6);
                    s_sy    <= 10'($signed(y) >>> 6);
                    pst     <= P_BLANK;
                end

                // Visibility, element wrap and the blank table, one clock.
                P_BLANK: begin
                    s_elem <= code_mod(s_code, n_elem);
                    if ((s_sx <= -10'sd16) || (s_sx >= 10'sd320) ||
                        (s_sy <= -10'sd16) || (s_sy >= 10'sd240)) begin
                        p_idx <= p_idx + 11'd1; p_rd <= '0; p_got <= '0;
                        pst   <= P_READ;
                    end else begin
                        s_r    <= (s_sy < 0) ? 4'(-s_sy) : 4'd0;
                        s_rend <= (s_sy > 10'sd224) ? 4'(10'sd239 - s_sy) : 4'd15;
                        pst    <= P_BWAIT;
                    end
                end

                // s_elem lands this clock; blank_q is read from it, so it is
                // only meaningful from the next one.
                P_BWAIT: pst <= P_ROWS;

                P_ROWS: begin
                    if (blank_q) begin
                        p_idx <= p_idx + 11'd1; p_rd <= '0; p_got <= '0;
                        pst   <= P_READ;
                    end else if (!jq_full && !jq_push) begin
                        logic [3:0] py;
                        py = s_flipy ? (4'd15 - s_r) : s_r;
                        jq_in.y     <= 8'(s_sy + 10'(s_r));
                        jq_in.sx    <= s_sx;
                        // byte c*256 + (py>>3)*128 + (py&7)*8, as a word address
                        jq_in.addr  <= rom_base + SDR_AW'({s_elem, 7'd0})
                                     + SDR_AW'({py[3], 6'd0}) + SDR_AW'({py[2:0], 2'd0});
                        jq_in.flipx <= s_flipx;
                        jq_in.color <= s_color;
                        jq_in.prio  <= s_prio;
                        jq_push     <= 1'b1;
                        if (s_r == s_rend) begin
                            p_idx <= p_idx + 11'd1; p_rd <= '0; p_got <= '0;
                            pst   <= P_READ;
                        end else begin
                            s_r <= s_r + 4'd1;
                        end
                    end
                end

                // Everything queued has to land before the draw is finished.
                P_DONE: if (jq_empty && !jq_push && f_idle && w_idle && !pq_valid) begin
                    draw_busy   <= 1'b0;
                    draw_fin    <= 1'b1;
                    draw_clocks <= 16'(draw_cnt >> 6);
                    pst         <= P_IDLE;
                end

                default: pst <= P_IDLE;
            endcase
        end
    end

    // The blank bit for s_elem, ready in P_ROWS (s_elem is set in P_BLANK).
    logic blank_q;
    always_ff @(posedge clk) blank_q <= blank[s_elem[15:0]] & ~s_elem[16];

    always_ff @(posedge clk) begin
        if (rst) jq_wp <= '0;
        else if (jq_push) begin
            jq[jq_wp[2:0]] <= jq_in;
            jq_wp <= jq_wp + 4'd1;
        end
    end

    // ============================================================== fetcher
    // Stage B: both halves of a row at once, on the two ports.
    job_t        f_job;
    logic        f_busy;
    logic [1:0]  f_have;
    logic [63:0] f_l, f_r;
    wire         f_idle = !f_busy;

    // One row of pixels, ready for the writer
    logic        pq_valid;
    logic        pq_take;
    /* verilator lint_off UNUSEDSIGNAL */   // the ROM address is the fetcher's
    job_t        pq_job;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [127:0] pq_pix;         // pixel k (screen order) at [8k +: 8]

    always_ff @(posedge clk) begin
        if (rst) begin
            jq_rp    <= '0;
            f_busy   <= 1'b0;
            rom_req  <= '0;
            pq_valid <= 1'b0;
        end else begin
            if (pq_take) pq_valid <= 1'b0;
            if (!f_busy) begin
                if (!jq_empty) begin
                    f_job       <= jq[jq_rp[2:0]];
                    jq_rp       <= jq_rp + 4'd1;
                    rom_addr[0] <= jq[jq_rp[2:0]].addr;
                    rom_addr[1] <= jq[jq_rp[2:0]].addr + SDR_AW'(32);   // +64 bytes
                    rom_req     <= 2'b11;
                    f_have      <= 2'b00;
                    f_busy      <= 1'b1;
                end
            end else begin
                if (rom_ack[0]) begin rom_req[0] <= 1'b0; f_l <= rom_dout[0]; f_have[0] <= 1'b1; end
                if (rom_ack[1]) begin rom_req[1] <= 1'b0; f_r <= rom_dout[1]; f_have[1] <= 1'b1; end
                if (&f_have && (!pq_valid || pq_take)) begin
                    logic [127:0] row;
                    row = {f_r, f_l};                 // pixel k at [8k +: 8]
                    if (f_job.flipx)
                        for (int k = 0; k < 16; k++) pq_pix[8*k +: 8] <= row[8*(15-k) +: 8];
                    else
                        pq_pix <= row;
                    pq_job   <= f_job;
                    pq_valid <= 1'b1;
                    f_busy   <= 1'b0;
                end
            end
        end
    end

    // ============================================================== dirty RAM
    // {buffer, line} -> 20 segment bits. Port A: clear and writer RMW.
    // Port B: scan-out.
    logic [19:0] dirty [0:511];
    logic [8:0]  da_addr;
    logic        da_we;
    logic [19:0] da_wd, da_q;
    logic [8:0]  db_addr;
    logic [19:0] db_q;
    always_ff @(posedge clk) begin
        if (da_we) dirty[da_addr] <= da_wd;
        da_q <= dirty[da_addr];
        db_q <= dirty[db_addr];
    end

    // =============================================================== writer
    // Stage C: one pixel row -> one or two aligned 16-word segment writes on
    // the draw buffer's chip.
    typedef enum logic [2:0] { W_IDLE, W_DREAD, W_DWAIT, W_SEG, W_ACK } wstate_t;
    wstate_t wst;
    wire     w_idle = (wst == W_IDLE);

    logic [7:0]   wr_y;
    logic [5:0]   w_seg0;          // first segment (may be -1 as 6'h3f)
    logic [511:0] w_win;           // 32 words: word j at [16j +: 16]
    logic [31:0]  w_op;            // opaque per window word
    logic [19:0]  w_dirty;
    logic         w_half;          // 0 = segment seg0, 1 = seg0+1
    logic         fb_req_w, fb_ack_w;
    logic [21:0]  fb_addr_w;
    logic [255:0] fb_wdata_w;
    logic [15:0]  fb_wmask_w;

    always_comb begin
        da_addr = clr_we ? {dbuf, clr_y - 8'd1} : {dbuf, wr_y};
        da_we   = clr_we || w_dirty_we;
        da_wd   = clr_we ? 20'd0 : w_dirty;
    end
    logic w_dirty_we;

    always_ff @(posedge clk) begin
        pq_take    <= 1'b0;
        w_dirty_we <= 1'b0;
        if (rst) begin
            wst      <= W_IDLE;
            fb_req_w <= 1'b0;
        end else begin
            case (wst)
                W_IDLE: if (pq_valid && !pq_take && !clr_we) begin : load
                    logic [3:0]  off;
                    logic [15:0] val;
                    pq_take <= 1'b1;
                    wr_y    <= pq_job.y;
                    off     = pq_job.sx[3:0];
                    w_seg0  <= 6'(pq_job.sx >>> 4);
                    w_win   <= '0;
                    w_op    <= '0;
                    for (int k = 0; k < 16; k++) begin
                        // A transparent pixel is stored as 0 (with no colour
                        // bits), because a fresh segment writes all 16 words.
                        val = (pq_pix[8*k +: 8] == 8'd0) ? 16'd0
                            : {pq_job.prio, 14'({pq_job.color, pq_pix[8*k +: 8]})};
                        w_win[16*(32'(off) + k) +: 16] <= val;
                        w_op[32'(off) + k]             <= (pq_pix[8*k +: 8] != 8'd0);
                    end
                    w_half <= 1'b0;
                    wst    <= W_DREAD;
                end

                // da_addr follows wr_y combinationally; the read is registered.
                W_DREAD: wst <= W_DWAIT;
                W_DWAIT: begin
                    w_dirty <= da_q;
                    wst     <= W_SEG;
                end

                W_SEG: begin : seg
                    logic [5:0]  s;
                    logic [15:0] op;
                    s  = w_seg0 + {5'd0, w_half};
                    op = w_half ? w_op[31:16] : w_op[15:0];
                    if (s[5] || s >= 6'd20 || op == 16'd0) begin
                        // Off screen, or nothing opaque in this segment.
                        if (w_half) begin
                            w_dirty_we <= 1'b1;
                            wst        <= W_IDLE;
                        end else w_half <= 1'b1;
                    end else begin
                        fb_addr_w  <= {5'd0, wr_y, s[4:0], 4'd0};   // y*512 + s*16
                        fb_wdata_w <= w_half ? w_win[511:256] : w_win[255:0];
                        fb_wmask_w <= w_dirty[s[4:0]] ? op : 16'hffff;
                        w_dirty[s[4:0]] <= 1'b1;
                        fb_req_w   <= 1'b1;
                        wst        <= W_ACK;
                    end
                end

                W_ACK: if (fb_ack_w) begin
                    fb_req_w <= 1'b0;
                    if (w_half) begin
                        w_dirty_we <= 1'b1;
                        wst        <= W_IDLE;
                    end else begin
                        w_half <= 1'b1;
                        wst    <= W_SEG;
                    end
                end

                default: wst <= W_IDLE;
            endcase
        end
    end

    // ============================================================= scan-out
    // During line y, fetch line y+1 of the shown buffer into the line buffer
    // the mixer is not reading. Only dirty segments are read.
    logic        lb_bank;                     // bank the mixer reads
    // ONE ARRAY, WITH THE BANK IN THE ADDRESS. Declared as lb[0:1][0:319],
    // Quartus 21.1 inferred a single 512 x 16 RAM with a 9-bit address (the
    // fit report's lb_rtl_0): the first index was dropped, so both banks were
    // the same words and scan-out wrote line y+1 over the line the mixer was
    // reading. Verilator keeps both banks, so every simulated frame was right
    // while the Pocket showed sprite rows torn and smeared. 1024 deep so the
    // address is {bank, x} with no arithmetic.
    logic [15:0] lb [0:1023];
    logic [19:0] lb_present [0:1];
    logic [7:0]  so_y;
    logic        so_busy;
    logic [4:0]  so_seg;
    logic [19:0] so_dirty;
    logic [1:0]  so_st;                       // 0 dirty read, 1 dirty wait, 2 segs, 3 ack
    logic        fb_req_s, fb_ack_s;
    logic [21:0] fb_addr_s;
    logic [255:0] so_data;
    logic        so_unpack;
    logic [3:0]  so_k;
    logic [4:0]  so_useg;

    // The line the mixer shows next. Fetch starts at the start of the
    // previous line; line 0 is fetched during the last line of the frame.
    wire [9:0] next_line = (vcnt == V_TOTAL - 10'd1) ? 10'd0 : vcnt + 10'd1;
    wire       fetch_go  = line_start && (next_line < 10'd240);

    always_ff @(posedge clk) begin
        if (rst) begin
            so_busy   <= 1'b0;
            fb_req_s  <= 1'b0;
            lb_bank   <= 1'b0;
            so_unpack <= 1'b0;
        end else begin
            if (line_start) lb_bank <= ~lb_bank;
            if (fetch_go) begin
                so_busy <= 1'b1;
                so_y    <= 8'(next_line);
                so_st   <= 2'd0;
                so_seg  <= '0;
            end else if (so_busy) begin
                case (so_st)
                    2'd0: so_st <= 2'd1;                // db_addr set below
                    2'd1: begin
                        so_dirty <= db_q;
                        lb_present[~lb_bank] <= db_q;
                        so_st    <= 2'd2;
                    end
                    2'd2: begin
                        if (so_seg == 5'd20) begin
                            if (!so_unpack) so_busy <= 1'b0;
                        end else if (so_dirty[so_seg] && !so_unpack) begin
                            fb_addr_s <= {5'd0, so_y, so_seg, 4'd0};
                            fb_req_s  <= 1'b1;
                            so_st     <= 2'd3;
                        end else if (!so_dirty[so_seg]) begin
                            so_seg <= so_seg + 5'd1;
                        end
                    end
                    2'd3: if (fb_ack_s) begin
                        fb_req_s  <= 1'b0;
                        so_data   <= fb_rdata_s;
                        so_unpack <= 1'b1;
                        so_k      <= '0;
                        so_useg   <= so_seg;
                        so_seg    <= so_seg + 5'd1;
                        so_st     <= 2'd2;
                    end
                endcase
            end
            // Sixteen words into the line buffer, one a clock, overlapping the
            // next segment's read.
            if (so_unpack) begin
                lb[{~lb_bank, 9'({so_useg, 4'd0}) + 9'(so_k)}] <= so_data[16*so_k +: 16];
                so_k <= so_k + 4'd1;
                if (so_k == 4'd15) so_unpack <= 1'b0;
            end
        end
    end
    always_comb db_addr = {disp, so_y};

    // The mixer's read: one clock, as kaneko_tmap_line's.
    logic [15:0] lb_q;
    logic        lb_p;
    wire  [8:0]  rx = (rd_x < 9'd320) ? rd_x : 9'd0;
    always_ff @(posedge clk) begin
        lb_q <= lb[{lb_bank, rx}];
        lb_p <= lb_present[lb_bank][rx[8:4]] && (rd_x < 9'd320);
    end
    assign spr_pix  = lb_p ? lb_q[13:0]  : 14'd0;
    assign spr_prio = lb_p ? lb_q[15:14] : 2'd0;

    // ============================================================ port muxes
    // The writer always talks to the draw chip, scan-out to the shown chip.
    // `disp` only changes at line 240, when neither is mid-request: scan-out
    // has nothing to fetch in vblank, and a draw still running blocks the swap.
    logic [255:0] fb_rdata_s;
    always_comb begin
        fb0_req = disp ? fb_req_w : fb_req_s;
        fb0_we  = disp;
        fb0_addr  = disp ? fb_addr_w : fb_addr_s;
        fb0_wdata = fb_wdata_w;
        fb0_wmask = fb_wmask_w;
        fb1_req = disp ? fb_req_s : fb_req_w;
        fb1_we  = ~disp;
        fb1_addr  = disp ? fb_addr_s : fb_addr_w;
        fb1_wdata = fb_wdata_w;
        fb1_wmask = fb_wmask_w;
        fb_ack_w  = disp ? fb0_ack : fb1_ack;
        fb_ack_s  = disp ? fb1_ack : fb0_ack;
        fb_rdata_s = disp ? fb1_rdata : fb0_rdata;
    end

endmodule

`default_nettype wire
