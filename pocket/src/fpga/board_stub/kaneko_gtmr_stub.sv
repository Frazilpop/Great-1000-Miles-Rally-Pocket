// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core — the gtmr board, AS A STAND-IN, for building the
// Pocket shell on its own.
//
// The real board is rtl/top/kaneko_gtmr.sv and is written in parallel with the
// shell. This has the same module name and the same ports as the real
// board. pocket/build.sh --stub selects it (via
// board_select.qip); a normal build never sees this file.
//
// WHY IT IS NOT SIMPLY TIED OFF
//
// A board whose outputs are constants and whose inputs go nowhere lets Quartus
// delete most of the shell: with no request ever raised, kaneko_sdram's
// arbiter and read path fold away, and with rom_dout unread, the dram_dq
// capture register has no fanout and is removed — so the SDRAM input timing,
// the one constraint that decides the read-capture default, would not be
// analysed at all. (The first build did exactly that: "Nothing to report" for
// every path from dram_dq.)
//
// So this generates traffic on every port the board owns, each by the
// contract's handshake, and folds everything that comes back into its outputs:
//
//   rom[p]     line reads, req held until ack, address stepping a line each
//   ram        alternating write/read, byte enables from a counter
//   fb0/fb1    alternating row write/read, masks from a counter
//   nv         a 64-word array behind the nv_* port, as the EEPROM would be
//   video      384x264 timing from ce_pix = clk/8, visible 320x240 from line 16
//   inputs     game, p1/p2, coin, start, service, test, pause, dsw, dl_* all folded in
//
// It proves nothing about the data; it keeps every path alive so that fit and
// timing describe the shell that will really be built. Its own logic is small
// and is counted separately in the fit report (entity u_board).
//
// If the board's ports change, this file changes with them.

`default_nettype none

module kaneko_gtmr #(
    parameter int unsigned SDR_AW = 25,
    parameter int unsigned NP     = 9
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rst_por,
    input  wire [2:0]  game,

    output wire [NP-1:0]             rom_req,
    output wire [NP-1:0][SDR_AW:1]   rom_addr,
    input  wire [NP-1:0]             rom_ack,
    input  wire [NP-1:0][63:0]       rom_dout,

    input  wire        dl_wr,
    input  wire [24:1] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        rom_loaded,

    output wire        ram_req,
    output wire        ram_we,
    output wire [16:0] ram_addr,
    output wire [15:0] ram_din,
    output wire [1:0]  ram_be,
    input  wire        ram_ack,
    input  wire [15:0] ram_dout,

    output wire        fb0_req,
    output wire        fb0_we,
    output wire [21:0] fb0_addr,
    output wire [255:0] fb0_wdata,
    output wire [15:0] fb0_wmask,
    input  wire        fb0_ack,
    input  wire [255:0] fb0_rdata,

    output wire        fb1_req,
    output wire        fb1_we,
    output wire [21:0] fb1_addr,
    output wire [255:0] fb1_wdata,
    output wire [15:0] fb1_wmask,
    input  wire        fb1_ack,
    input  wire [255:0] fb1_rdata,

    output wire        ce_pix,
    output wire        hs, vs, hblank, vblank,
    output wire [7:0]  r, g, b,

    output wire [15:0] snd,

    input  wire [7:0]  p1, p2,
    input  wire [1:0]  coin, start,
    input  wire        service, test,
    input  wire [15:0] dsw,
    input  wire        pause,

    input  wire [5:0]  nv_addr,
    input  wire [15:0] nv_din,
    input  wire        nv_we,
    output wire [15:0] nv_dout,
    output wire        nv_dirty,
    input  wire        nv_dirty_clr,

    // Diagnostics: the stub has nothing to report
    input  wire        diag_clr,
    output wire [31:0] diag_wait_max,
    output wire [23:0] diag_wait_addr,
    output wire [15:0] diag_stall_frames,
    output wire [15:0] diag_draw_max,
    output wire [7:0]  diag_spr_overruns
);
assign diag_wait_max = 32'd0; assign diag_wait_addr = 24'd0;
assign diag_stall_frames = 16'd0; assign diag_draw_max = 16'd0;
assign diag_spr_overruns = 8'd0;
wire unused_diag_clr = diag_clr;

// ------------------------------------------------------------------ video
reg [2:0] ce_div;
always @(posedge clk) ce_div <= ce_div + 3'd1;
assign ce_pix = (ce_div == 3'd0);

reg [8:0] hc, vc;
always @(posedge clk) if (ce_pix) begin
    if (hc == 9'd383) begin hc <= 9'd0; vc <= (vc == 9'd263) ? 9'd0 : vc + 9'd1; end
    else hc <= hc + 9'd1;
end
assign hblank = (hc >= 9'd320);
assign vblank = (vc < 9'd16) || (vc >= 9'd256);
assign hs     = (hc >= 9'd336) && (hc < 9'd368);
assign vs     = (vc >= 9'd248) && (vc < 9'd256);

// ------------------------------------------------------------- ROM ports
reg [NP-1:0]           rq;
reg [NP-1:0][SDR_AW:1] ra;
reg [NP-1:0][15:0]     racc;
genvar gp;
generate for (gp = 0; gp < NP; gp = gp + 1) begin : g_rom
    always @(posedge clk) begin
        if (rst) begin
            rq[gp] <= 1'b0;
            ra[gp] <= SDR_AW'(gp) << 20;
        end else if (rq[gp]) begin
            if (rom_ack[gp]) begin
                rq[gp] <= 1'b0;
                ra[gp] <= ra[gp] + SDR_AW'(4);
                racc[gp] <= racc[gp] ^ rom_dout[gp][15:0] ^ rom_dout[gp][31:16]
                                     ^ rom_dout[gp][47:32] ^ rom_dout[gp][63:48];
            end
        end else begin
            rq[gp] <= 1'b1;
        end
    end
end endgenerate
assign rom_req  = rq;
assign rom_addr = ra;

// ------------------------------------------------------------------ SRAM
reg        mq, mwe;
reg [16:0] ma;
reg [15:0] macc;
always @(posedge clk) begin
    if (rst) mq <= 1'b0;
    else if (mq) begin
        if (ram_ack) begin
            mq   <= 1'b0;
            mwe  <= ~mwe;
            if (mwe) ma <= ma + 17'd1;
            if (!mwe) macc <= macc ^ ram_dout;
        end
    end else mq <= 1'b1;
end
assign ram_req  = mq;
assign ram_we   = mwe;
assign ram_addr = ma;
assign ram_din  = ma[15:0] ^ macc;
assign ram_be   = ma[1:0] | {1'b0, ~ma[1]};

// ------------------------------------------------------------ PSRAM rows
reg  [1:0]       fq, fwe;
reg  [1:0][21:0] fa;
reg  [1:0][15:0] facc;
wire [1:0]       fack = {fb1_ack, fb0_ack};
wire [1:0][255:0] frd = {fb1_rdata, fb0_rdata};
function automatic [15:0] fold256(input [255:0] v);
    integer i;
    begin
        fold256 = 16'd0;
        for (i = 0; i < 16; i = i + 1) fold256 = fold256 ^ v[16*i +: 16];
    end
endfunction
genvar gf;
generate for (gf = 0; gf < 2; gf = gf + 1) begin : g_fb
    always @(posedge clk) begin
        if (rst) fq[gf] <= 1'b0;
        else if (fq[gf]) begin
            if (fack[gf]) begin
                fq[gf]  <= 1'b0;
                fwe[gf] <= ~fwe[gf];
                if (fwe[gf]) fa[gf] <= fa[gf] + 22'd16;
                if (!fwe[gf]) facc[gf] <= facc[gf] ^ fold256(frd[gf]);
            end
        end else fq[gf] <= 1'b1;
    end
end endgenerate
assign fb0_req   = fq[0];
assign fb0_we    = fwe[0];
assign fb0_addr  = fa[0];
assign fb0_wdata = {16{fa[0][15:0] ^ facc[0]}};
assign fb0_wmask = fa[0][19:4] | facc[0];
assign fb1_req   = fq[1];
assign fb1_we    = fwe[1];
assign fb1_addr  = fa[1];
assign fb1_wdata = {16{fa[1][15:0] ^ facc[1]}};
assign fb1_wmask = fa[1][19:4] | facc[1];

// ---------------------------------------------------------------- EEPROM
reg [15:0] nv_mem [64];
reg [15:0] nv_q;
reg        nv_d;
always @(posedge clk) begin
    if (nv_we) nv_mem[nv_addr] <= nv_din;
    nv_q <= nv_mem[nv_addr];
    if (rst_por) nv_d <= 1'b0;
    else if (nv_dirty_clr) nv_d <= 1'b0;
    else if (vblank && hc == 9'd0 && vc == 9'd0 && mwe) nv_d <= 1'b1;
end
assign nv_dout  = nv_q;
assign nv_dirty = nv_d;

// --------------------------------------------------------------- outputs
reg [15:0] acc;
reg [15:0] rfold;
integer k;
always @(*) begin
    rfold = 16'd0;
    for (k = 0; k < NP; k = k + 1) rfold = rfold ^ racc[k];
end
always @(posedge clk)
    acc <= rfold ^ macc ^ facc[0] ^ facc[1] ^ dsw ^ {p1, p2}
         ^ {game, coin, start, service, test, pause, rom_loaded, 5'd0}
         ^ (dl_wr ? dl_data ^ dl_addr[16:1] : 16'd0);
assign {r, g, b} = (hblank | vblank) ? 24'd0 : {acc, acc[7:0]};
assign snd = acc;

endmodule

`default_nettype wire
