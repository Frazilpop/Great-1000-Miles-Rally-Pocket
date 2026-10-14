// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko16 (gtmr board) for Analogue Pocket — the core top level
//
// Instantiated by Analogue's apf_top. Everything Pocket-specific lives here and
// in the pocket_* modules beside it; the board itself (rtl/top/kaneko_gtmr.sv)
// knows nothing of APF, pins or the bridge.
//
// CLOCKS (core/mf_pllbase/mf_pllbase_0002.v has the derivation)
//
//   clk_74a        74.25 MHz  APF bridge, pad bus, I2S; PLL reference
//   clk_core       48 MHz     the board and every servant it talks to
//   clk_sdram      96 MHz     kaneko_sdram, behind kaneko_sdram_x2
//   clk_sdram_ps   96 MHz     180 deg, forwarded to dram_clk
//   clk_vid         6 MHz     APF video bus
//   clk_vid90       6 MHz     90 deg, for APF's video DDR
//
// 48, 96 and 6 come from one VCO and are synchronous; everything they share
// with clk_74a crosses through a synchroniser, a dcfifo or a dual-clock RAM,
// and core_constraints.sdc cuts exactly those.
//
// BRIDGE MAP
//
//   0x00000000-   ROM image data slot -> SDRAM          pocket_rom_loader
//   0x20000000-   EEPROM save slot, 128 bytes, r/w      pocket_nvram
//   0xF0000000    game id (instance JSON memory_writes) r/w
//   0xF1000000-   options (interact.json)               r/w, see below
//   0xF8000000-   APF command bridge                    core_bridge_cmd
//
// DATA SLOTS (dist/Cores/frazilpop.Great 1000 Miles Rally/data.json), in table order:
//
//   [0] id 0  instance JSON (APF requires the instance slot to come first)
//   [1] id 1  <set>.rom at 0x00000000
//   [2] id 2  <set>.sav at 0x20000000, nonvolatile, 128 bytes

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

localparam SDR_COL = 10;                    // AS4C32M16MSA: 8192 x 1024 x 4
localparam SDR_AW  = 2 + 13 + SDR_COL;      // 25: word address [25:1], 64 MB
localparam NP      = 9;                     // board ROM read ports
// One more at the controller than the board has: port NP is the shell's own
// SDRAM read-back check (see DIAGNOSTICS below). The board never sees it.
localparam NPS     = NP + 1;

// ============================================================ unused pins
// As Analogue's template leaves them.

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

// ================================================================= clocks
wire clk_core, clk_sdram, clk_sdram_ps, clk_vid, clk_vid90;
wire pll_core_locked;

mf_pllbase mp1 (
    .refclk   ( clk_74a ),
    .rst      ( 1'b0 ),
    .outclk_0 ( clk_core ),
    .outclk_1 ( clk_sdram ),
    .outclk_2 ( clk_sdram_ps ),
    .outclk_3 ( clk_vid ),
    .outclk_4 ( clk_vid90 ),
    .locked   ( pll_core_locked )
);

// ================================================================= resets
//
// Three, because three things are being reset for different reasons:
//
//   sdram_rst_n   96 MHz, PLL lock only. kaneko_sdram's reset is synchronous
//                 (so its pins pack into I/O cells) and it runs its own
//                 power-up sequence; it must never be reset again after that.
//   rst_por       48 MHz, PLL lock only: the board's `rst_por`, which the
//                 EEPROM alone listens to, and every servant here.
//   board_rst     48 MHz: rst_por, or APF holding the core in reset (from
//                 boot to [0011 Reset Exit], and again from [0010 Reset
//                 Enter]), or the Reset action in the menu. The board adds
//                 !rom_loaded itself.

wire pll_core_locked_s;                     // clk_74a
synch_3 s_lock74 (.i(pll_core_locked), .o(pll_core_locked_s), .clk(clk_74a), .rise(), .fall());

wire locked_96;
synch_3 s_lock96 (.i(pll_core_locked), .o(locked_96), .clk(clk_sdram), .rise(), .fall());
wire sdram_rst_n = locked_96;

wire locked_48;
synch_3 s_lock48 (.i(pll_core_locked), .o(locked_48), .clk(clk_core), .rise(), .fall());
reg [7:0] por_cnt = 8'd0;
always @(posedge clk_core)
    if (!locked_48)            por_cnt <= 8'd0;
    else if (por_cnt != 8'hff) por_cnt <= por_cnt + 8'd1;
wire rst_por = (por_cnt != 8'hff);

wire reset_n;                               // clk_74a, from core_bridge_cmd
wire reset_n_48;
synch_3 s_rstn48 (.i(reset_n), .o(reset_n_48), .clk(clk_core), .rise(), .fall());

// ================================================================== bridge
//
// Writes are broadcast: the two data_loaders inside pocket_rom_loader and
// pocket_nvram pick out their own regions; the registers below pick out
// theirs. Reads are muxed and REGISTERED: APF buffers bridge reads by one
// word, taking each read's bus value before it strobes bridge_rd, so a
// region backed by memory answers the address of the last strobe
// (pocket_nvram).

wire [31:0] cmd_bridge_rd_data;
wire [31:0] nv_bridge_rd;

// ---- settings written by APF (instance JSON, interact.json)
//
// Every field is laid out so that ZERO IS THE DEFAULT, for two reasons. APF
// writes persisted interact values only when there are some, so on a first
// boot the core's reset value IS the setting; and a `list` element's
// defaultval reads the same whether APF takes it as an index or a value when
// both are zero.
//
//   0xF0000000 [2:0]   game: 0 gtmr, 1 gtmre, 2 gtmrusa, 3 gtmr2, 4 gtmr2u
//   0xF1000000         DIP options, one table for every set, each field
//                      0 = MAME's default; a set ignores a switch its board
//                      does not have:
//                        [0]    service mode (SW1:1)       both boards
//                        [1]    flip screen                both
//                        [2]    cabinet: cocktail          gtmr family
//                        [4:3]  controller: 0 joystick, 1 wheel 360,
//                               2 wheel 270D, 3 wheel 270A both (gtmr has
//                               wheel 360 / 270 only; 270D and 270A both
//                               set 270 there)
//                        [5]    controls: both sides       gtmr family,
//                               with a joystick (the same PCB switch means
//                               360 / 270 with a wheel)
//                        [6]    brake: off                 gtmr family
//                        [7]    pedal: potentiometer       gtmr2 family
//                        [9:8]  anthem & flag: 0 memory, 1 anthem only,
//                               2 flag only, 3 none        gtmr family
//                      Only OPT_MENU's fields are offered in the menu (Test
//                      Mode, bit 0); the rest are held at 0 whatever APF has
//                      saved from older menus. Flip and cocktail need the
//                      tilemap flip this core does not draw, the wheels an
//                      analogue input it does not have, and the others are
//                      cabinet wiring a Pocket has no use for; the table
//                      stays so a field can come back by widening OPT_MENU.
//                      Changing Test Mode resets the game, since the game
//                      reads the switch at boot.
//   0xF100000C         write: reset the game (1 ms)
//   0xF1000014 [0]     diagnostic overlay (pocket_diag), see DIAGNOSTICS
//
// The test switch (0xF1000004), service coin (0xF1000008) and SDRAM read
// capture (0xF1000010) left the menu on 10 Oct 2026: Test Mode does what the
// held test switch did, Select is the coin, and the capture point is fixed at
// the measured CL+2 (READ CAPTURE DEPTH below).

localparam [31:0] OPT_MENU = 32'h0000_0001;

reg  [2:0]  game_74  = 3'd0;
reg  [31:0] opt_74   = 32'd0;
reg         diag_74  = 1'b0;
reg  [16:0] hrst_cnt = 17'd0;               //   1 ms at 74.25 MHz = 74,250
wire        hrst_74  = (hrst_cnt != 17'd0);
wire [31:0] opt_wr   = bridge_wr_data & OPT_MENU;

always @(posedge clk_74a) begin
    if (hrst_cnt != 17'd0) hrst_cnt <= hrst_cnt - 17'd1;
    if (bridge_wr) begin
        case (bridge_addr)
        32'hF0000000: game_74  <= bridge_wr_data[2:0];
        32'hF1000000: begin
            opt_74 <= opt_wr;
            if (opt_wr[0] != opt_74[0]) hrst_cnt <= 17'd74250;
        end
        32'hF100000C: hrst_cnt <= 17'd74250;
        32'hF1000014: diag_74  <= bridge_wr_data[0];
        default: ;
        endcase
    end
end

always @(posedge clk_74a) begin
    casez (bridge_addr)
    32'h2???????: bridge_rd_data <= nv_bridge_rd;
    32'hF0000000: bridge_rd_data <= {29'd0, game_74};
    32'hF1000000: bridge_rd_data <= opt_74;
    32'hF1000014: bridge_rd_data <= {31'd0, diag_74};
    32'hF8??????: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 32'd0;
    endcase
end

// ---- DSW1, as MAME's port and the PCB: active low, high byte
//
// The two boards put the same switches in different places, and in opposite
// orders (kaneko16.cpp, INPUT_PORTS gtmr and gtmr2; `mame -listxml`), so the
// options are one generic table and the word is assembled per game here. The
// low byte is not defined by MAME's port and reads 0 there, so it reads 0
// here.
wire        gtmr2_map = (game_74 == 3'd3) || (game_74 == 3'd4);
wire [1:0]  ctl_74    = opt_74[4:3];            // 0 joystick, 1 wheel 360, 2 wheel 270D, 3 wheel 270A
wire        wheel_74  = (ctl_74 != 2'd0);
wire [15:0] dsw_gtmr  = {~opt_74[9], ~opt_74[8],// 0xC000 anthem & flag: use memory = 11
                         ~opt_74[6],            // 0x2000 use brake: on = 1
                         wheel_74 ? (ctl_74 == 2'd1)   // 0x1000 with a wheel: 360 = 1, 270 = 0
                                  : ~opt_74[5], //        with a joystick: 1P side = 1, both sides = 0
                         ~wheel_74,             // 0x0800 controller: joystick = 1
                         ~opt_74[2],            // 0x0400 cabinet: upright = 1
                         ~opt_74[1],            // 0x0200 flip screen: off = 1
                         ~opt_74[0],            // 0x0100 service mode (SW1:1): off = 1
                         8'h00};
wire [15:0] dsw_gtmr2 = {~opt_74[0],            // 0x8000 service mode (SW1:1)
                         ~opt_74[1],            // 0x4000 flip screen
                         ~opt_74[7],            // 0x2000 pedal: microswitch = 1
                         ~ctl_74[0], ~ctl_74[1],// 0x1800 controls: joystick 11, 360 01, 270D 10, 270A 00
                         3'b111,                // 0x0700 no link communication
                         8'h00};
wire [15:0] dsw_74    = gtmr2_map ? dsw_gtmr2 : dsw_gtmr;

// ---- the APF command bridge, as the template wires it
wire            status_boot_done  = pll_core_locked_s;
// "Setup" means ready to take memory writes, which here means the SDRAM has
// finished its power-up sequence.
wire            mem_ready;
wire            mem_ready_74;
synch_3 s_memrdy74 (.i(mem_ready), .o(mem_ready_74), .clk(clk_74a), .rise(), .fall());
wire            status_setup_done = pll_core_locked_s & mem_ready_74;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1;
wire            dataslot_requestread_ok  = 1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1;
wire            dataslot_requestwrite_ok  = 1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire     [31:0] rtc_epoch_seconds;
wire     [31:0] rtc_date_bcd;
wire     [31:0] rtc_time_bcd;
wire            rtc_valid;

wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'd0;
wire    [31:0]  savestate_size        = 32'd0;
wire    [31:0]  savestate_maxloadsize = 32'd0;

wire            savestate_start;
wire            savestate_start_ack   = 1'b0;
wire            savestate_start_busy  = 1'b0;
wire            savestate_start_ok    = 1'b0;
wire            savestate_start_err   = 1'b0;

wire            savestate_load;
wire            savestate_load_ack    = 1'b0;
wire            savestate_load_busy   = 1'b0;
wire            savestate_load_ok     = 1'b0;
wire            savestate_load_err    = 1'b0;

wire            osnotify_inmenu;

wire            target_dataslot_read      = 1'b0;
wire            target_dataslot_write     = 1'b0;
wire            target_dataslot_getfile   = 1'b0;
wire            target_dataslot_openfile  = 1'b0;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

wire    [15:0]  target_dataslot_id         = 16'd0;
wire    [31:0]  target_dataslot_slotoffset = 32'd0;
wire    [31:0]  target_dataslot_bridgeaddr = 32'd0;
wire    [31:0]  target_dataslot_length     = 32'd0;

wire    [31:0]  target_buffer_param_struct = 32'd0;
wire    [31:0]  target_buffer_resp_struct  = 32'd0;

// THE SAVE FILE'S SIZE. APF writes back as many bytes as the Dataslot
// ID/Size table says, and when no .sav existed yet that entry is zero — the
// game would save into the EEPROM and nothing would ever reach the card. So
// the core keeps writing 128 into the size word of the save slot's entry,
// which is table index 2 (data.json order), word 2*2+1.
reg     [9:0]   datatable_addr;
reg             datatable_wren;
reg     [31:0]  datatable_data;
wire    [31:0]  datatable_q;

always @(posedge clk_74a) begin
    datatable_addr <= 10'd5;
    datatable_wren <= 1'b1;
    datatable_data <= 32'd128;
end

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);

// ======================================================= settings -> 48 MHz
wire [2:0]  game;
wire [15:0] dsw;
wire        host_rst, diag_opt;

pocket_sync_bus #(.W(21), .INIT({3'd0, 16'hff00, 2'b00})) s_cfg48 (
    .clk (clk_core),
    .d   ({game_74, dsw_74, hrst_74, diag_74}),
    .q   ({game,    dsw,    host_rst, diag_opt})
);

wire board_rst = rst_por | ~reset_n_48 | host_rst;

// ================================================================== inputs
//
// The pad bus is on clk_74a. Each button is an independent level, so a
// per-bit synchroniser is enough: a press that lands one cycle earlier on one
// bit than another is invisible to a game polling at 60 Hz.
//
//   p1/p2 = {b4,b3,b2,b1,right,left,down,up} is exactly key[7:0]:
//   up, down, left, right, A (button 1, accelerate), B (button 2, brake),
//   X (button 3), Y (button 4). Select is coin, Start is start.
wire [15:0] k1, k2;
synch_3 #(.WIDTH(16)) s_k1 (.i(cont1_key[15:0]), .o(k1), .clk(clk_core), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_k2 (.i(cont2_key[15:0]), .o(k2), .clk(clk_core), .rise(), .fall());

wire [7:0] in_p1    = k1[7:0];
wire [7:0] in_p2    = k2[7:0];
wire [1:0] in_coin  = {k2[14], k1[14]};
wire [1:0] in_start = {k2[15], k1[15]};

// Pause: the game is paused while the Pocket's own menu is open (APF's OS
// notify, host command 0x00B0), and the picture behind the menu is blacked
// out (after the overlay, below).
wire inmenu_48;
synch_3 s_inmenu48 (.i(osnotify_inmenu), .o(inmenu_48), .clk(clk_core), .rise(), .fall());
wire pause = inmenu_48;

// ========================================================= ROM -> SDRAM
wire allcomplete_48;
synch_3 s_allc48 (.i(dataslot_allcomplete), .o(allcomplete_48), .clk(clk_core), .rise(), .fall());

wire              ldr_wr_req, ldr_wr_ack;
wire [SDR_AW:1]   ldr_wr_addr;
wire [15:0]       ldr_wr_din;
wire [1:0]        ldr_wr_be;
wire              dl_wr;
wire [24:1]       dl_addr;
wire [15:0]       dl_data;
wire              rom_loaded;
wire              ldr_overflow;

pocket_rom_loader #(.SDR_AW(SDR_AW)) u_loader (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),

    .clk                 (clk_core),
    .rst                 (rst_por),
    .mem_ready           (mem_ready),
    .allcomplete_s       (allcomplete_48),

    .wr_req              (ldr_wr_req),
    .wr_addr             (ldr_wr_addr),
    .wr_din              (ldr_wr_din),
    .wr_be               (ldr_wr_be),
    .wr_ack              (ldr_wr_ack),

    .dl_wr               (dl_wr),
    .dl_addr             (dl_addr),
    .dl_data             (dl_data),
    .rom_loaded          (rom_loaded),
    .overflow            (ldr_overflow)
);

// ================================================================== SDRAM
//
// Wired as upstream's Kaneko16.sv wires it: the board's NP read ports and the
// loader on kaneko_sdram_x2's 48 MHz side, kaneko_sdram on the 96 MHz side.
// Two Pocket differences, both at the pins:
//
//   - The Pocket's SDRAM has no CS# pin (it is tied active on the board).
//     kaneko_sdram never issues DESELECT — every command it encodes has
//     cs_n = 0 — so dropping sd_cs_n loses nothing.
//   - dram_clk is clk_sdram_ps forwarded through a DDIO output register
//     rather than routed to the pin as a clock; see mf_pllbase_0002.v.

// Port NP (the last) is the shell's read-back check (DIAGNOSTICS below);
// the board owns 0..NP-1.
wire [NPS-1:0]         rom_req;
wire [NPS*SDR_AW-1:0]  rom_addr;
wire [NPS-1:0]         rom_ack;
wire [NPS*64-1:0]      rom_dout;

wire [NPS-1:0]         f_req, f_ack, f_we;
wire [NPS*SDR_AW-1:0]  f_addr;
wire [NPS*64-1:0]      f_dout;
wire [NPS*16-1:0]      f_din;
wire [NPS*2-1:0]       f_be;
wire                   f_wr_req, f_wr_ack;
wire [SDR_AW:1]        f_wr_addr;
wire [15:0]            f_wr_din;
wire [1:0]             f_wr_be;
wire [NPS-1:0]         sdr_dbg_req, sdr_dbg_grant;

kaneko_sdram_x2 #(.NP(NPS), .AW(SDR_AW)) u_sdr_x2 (
    .clk_fast (clk_sdram),

    // NOBODY READS SDRAM UNTIL THE ROM IS IN IT — upstream's rule, for
    // upstream's reason: readers running during the download starve the
    // loader's writes. Requesters hold req until acknowledged, so masking
    // here parks them and they resume the moment rom_loaded rises.
    .s_req    (rom_loaded ? rom_req : {NPS{1'b0}}),
    .s_addr   (rom_addr),
    .s_we     ({NPS{1'b0}}),
    .s_din    ({NPS{16'd0}}),
    .s_be     ({NPS{2'b11}}),
    .s_ack    (rom_ack),
    .s_dout   (rom_dout),

    .s_wr_req (ldr_wr_req),  .s_wr_addr(ldr_wr_addr), .s_wr_din(ldr_wr_din),
    .s_wr_be  (ldr_wr_be),   .s_wr_ack (ldr_wr_ack),

    .f_req    (f_req),  .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
    .f_we     (f_we),   .f_din (f_din),  .f_be (f_be),
    .f_wr_req (f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
    .f_wr_be  (f_wr_be),  .f_wr_ack (f_wr_ack)
);

// READ CAPTURE DEPTH (kaneko_sdram rd_lat_sel), fixed.
//
// kaneko_sdram's encoding is 0 -> CL+1, 1 -> CL+0, 2 -> CL+2, 3 -> CL+3:
// the pin is sampled into dq_r (cap_depth - 1) edges after the READ command.
//
// THE DEPTH IS CL+2, MEASURED, NOT CL+3, TIMED. core_constraints.sdc times
// the read data as a 2-cycle path from the forwarded device clock, which
// says CL+3 on paper. On the Pocket (9 Oct 2026, pocket_diag's read-back of
// the reset vector) CL+3 returned the line shifted one word early -- 0000
// 0000 9E04 9E04 for 1100 0000 0000 9E04 -- i.e. the first word was already
// on the bus one clock before the paper edge, and the last slot caught the
// bus still holding the final word. One clock earlier is right, which is
// what upstream measured on its board against the same paper. It was a menu
// choice (CL+2, CL+3, CL+1, CL+0) until 10 Oct 2026; the overlay's counters
// 6/7 and flag 7 still check it on every frame.
wire [1:0] rd_lat_sel = 2'd2;       // CL+2

wire        sd_cs_n_unused;
wire        sd_dq_oe;
wire [15:0] sd_dq_o;
assign dram_dq = sd_dq_oe ? sd_dq_o : 16'bZ;

kaneko_sdram #(
    .COL_BITS (SDR_COL),
    .NP       (NPS),
    // 8192 rows per 64 ms = one refresh per 7.8 us = 750 cycles at 96 MHz;
    // 700 keeps margin for a transfer in flight when the timer fires. As
    // upstream.
    .T_REFI   (700),
    // T_RC is what kaneko_sdram waits after AUTO REFRESH, so it must cover
    // tRFC, not only tRC. Upstream's 7 is 73 ns; the Pocket's mobile SDRAM
    // family states tRFC = 80 ns (AS4C16M16MSA sheet; the 512 Mb part's own
    // sheet was not to hand), so 11 = 115 ns. Activate-to-activate on one
    // bank is still governed by T_RAS + T_RP (5 + 2 = 73 ns >= tRC 60 ns).
    .T_RC     (11),
    // JEDEC power-up: 200 us of NOP before the first command for this part
    // (upstream's 10000 is 104 us). The init sequence counts down from here
    // and starts at 400, so 25000 gives 256 us.
    .INIT_NOP (25000),
    // Ports with a deadline first: 0-3 tile layers,
    // 4 the 68000 (and TOYBOX), 5-6 the OKIs. 7-8, the sprite ROM, have a
    // frame of slack and wait; so does 9, the read-back check.
    .URGENT   (10'b00_0111_1111)
) u_sdram (
    .clk       (clk_sdram),
    .rst_n     (sdram_rst_n),
    .ready     (mem_ready),
    .rd_lat_sel(rd_lat_sel),

    .sd_cke    (dram_cke),
    .sd_cs_n   (sd_cs_n_unused),
    .sd_ras_n  (dram_ras_n),
    .sd_cas_n  (dram_cas_n),
    .sd_we_n   (dram_we_n),
    .sd_ba     (dram_ba),
    .sd_a      (dram_a),
    .sd_dqm    (dram_dqm),
    .sd_dq_o   (sd_dq_o),
    .sd_dq_oe  (sd_dq_oe),
    .sd_dq_i   (dram_dq),

    .wr_req    (f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
    .wr_be     (f_wr_be),  .wr_ack (f_wr_ack),

    .p_req     (f_req),
    .p_we      (f_we),
    .p_addr    (f_addr),
    .p_din     (f_din),
    .p_be      (f_be),
    .p_dout    (f_dout),
    .p_ack     (f_ack),
    .dbg_req   (sdr_dbg_req),
    .dbg_grant (sdr_dbg_grant)
);

pin_ddio_clk u_dram_clk (
    .datain_h ( 1'b1 ),
    .datain_l ( 1'b0 ),
    .outclock ( clk_sdram_ps ),
    .dataout  ( dram_clk )
);

// =================================================================== SRAM
wire        ram_req, ram_we, ram_ack;
wire [16:0] ram_addr;
wire [15:0] ram_din, ram_dout;
wire [1:0]  ram_be;

pocket_sram u_sram (
    .clk      (clk_core),
    .rst      (rst_por),
    .req      (ram_req),
    .we       (ram_we),
    .addr     (ram_addr),
    .din      (ram_din),
    .be       (ram_be),
    .ack      (ram_ack),
    .dout     (ram_dout),
    .sram_a   (sram_a),
    .sram_dq  (sram_dq),
    .sram_oe_n(sram_oe_n),
    .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n),
    .sram_lb_n(sram_lb_n)
);

// ================================================================== PSRAM
wire         fb0_req, fb0_we, fb0_ack;
wire [21:0]  fb0_addr;
wire [255:0] fb0_wdata, fb0_rdata;
wire [15:0]  fb0_wmask;
wire         fb1_req, fb1_we, fb1_ack;
wire [21:0]  fb1_addr;
wire [255:0] fb1_wdata, fb1_rdata;
wire [15:0]  fb1_wmask;

pocket_fb_psram u_fb0 (
    .clk       (clk_core),   .rst      (rst_por),
    .req       (fb0_req),    .we       (fb0_we),     .addr (fb0_addr),
    .wdata     (fb0_wdata),  .wmask    (fb0_wmask),
    .ack       (fb0_ack),    .rdata    (fb0_rdata),
    .cram_a    (cram0_a),    .cram_dq  (cram0_dq),   .cram_wait (cram0_wait),
    .cram_clk  (cram0_clk),  .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre),
    .cram_ce0_n(cram0_ce0_n),.cram_ce1_n(cram0_ce1_n),
    .cram_oe_n (cram0_oe_n), .cram_we_n(cram0_we_n),
    .cram_ub_n (cram0_ub_n), .cram_lb_n(cram0_lb_n)
);

pocket_fb_psram u_fb1 (
    .clk       (clk_core),   .rst      (rst_por),
    .req       (fb1_req),    .we       (fb1_we),     .addr (fb1_addr),
    .wdata     (fb1_wdata),  .wmask    (fb1_wmask),
    .ack       (fb1_ack),    .rdata    (fb1_rdata),
    .cram_a    (cram1_a),    .cram_dq  (cram1_dq),   .cram_wait (cram1_wait),
    .cram_clk  (cram1_clk),  .cram_adv_n(cram1_adv_n), .cram_cre(cram1_cre),
    .cram_ce0_n(cram1_ce0_n),.cram_ce1_n(cram1_ce1_n),
    .cram_oe_n (cram1_oe_n), .cram_we_n(cram1_we_n),
    .cram_ub_n (cram1_ub_n), .cram_lb_n(cram1_lb_n)
);

// ================================================================= EEPROM
wire [5:0]  nv_addr;
wire [15:0] nv_din, nv_dout;
wire        nv_we, nv_dirty, nv_dirty_clr;

pocket_nvram u_nvram (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_rd           (bridge_rd),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),
    .bridge_rd_word      (nv_bridge_rd),
    .clk                 (clk_core),
    .nv_addr             (nv_addr),
    .nv_din              (nv_din),
    .nv_we               (nv_we),
    .nv_dout             (nv_dout),
    .nv_dirty            (nv_dirty),
    .nv_dirty_clr        (nv_dirty_clr)
);

// ================================================================== board
wire        ce_pix, hs, vs, hblank, vblank_b;
wire [7:0]  r, g, b;
wire [15:0] snd;

kaneko_gtmr #(.SDR_AW(SDR_AW), .NP(NP)) u_board (
    .clk        (clk_core),
    .rst        (board_rst),
    .rst_por    (rst_por),
    .game       (game),

    .rom_req    (rom_req[NP-1:0]),
    .rom_addr   (rom_addr[NP*SDR_AW-1:0]),
    .rom_ack    (rom_ack[NP-1:0]),
    .rom_dout   (rom_dout[NP*64-1:0]),

    .dl_wr      (dl_wr),
    .dl_addr    (dl_addr),
    .dl_data    (dl_data),
    .rom_loaded (rom_loaded),

    .ram_req    (ram_req),
    .ram_we     (ram_we),
    .ram_addr   (ram_addr),
    .ram_din    (ram_din),
    .ram_be     (ram_be),
    .ram_ack    (ram_ack),
    .ram_dout   (ram_dout),

    .fb0_req    (fb0_req),
    .fb0_we     (fb0_we),
    .fb0_addr   (fb0_addr),
    .fb0_wdata  (fb0_wdata),
    .fb0_wmask  (fb0_wmask),
    .fb0_ack    (fb0_ack),
    .fb0_rdata  (fb0_rdata),

    .fb1_req    (fb1_req),
    .fb1_we     (fb1_we),
    .fb1_addr   (fb1_addr),
    .fb1_wdata  (fb1_wdata),
    .fb1_wmask  (fb1_wmask),
    .fb1_ack    (fb1_ack),
    .fb1_rdata  (fb1_rdata),

    .ce_pix     (ce_pix),
    .hs         (hs),
    .vs         (vs),
    .hblank     (hblank),
    .vblank     (vblank_b),
    .r          (r),
    .g          (g),
    .b          (b),

    .snd        (snd),

    .p1         (in_p1),
    .p2         (in_p2),
    .coin       (in_coin),
    .start      (in_start),
    .service    (1'b0),             // no service coin: Select is the coin
    .test       (1'b0),             // no test button: Test Mode is the DIP
    .dsw        (dsw),
    .pause      (pause),

    .nv_addr    (nv_addr),
    .nv_din     (nv_din),
    .nv_we      (nv_we),
    .nv_dout    (nv_dout),
    .nv_dirty   (nv_dirty),
    .nv_dirty_clr(nv_dirty_clr),

    .diag_clr        (diag_clr),
    .diag_wait_max   (diag_wait_max),
    .diag_wait_addr  (diag_wait_addr),
    .diag_stall_frames(diag_stall_frames),
    .diag_draw_max   (diag_draw_max),
    .diag_spr_overruns(diag_spr_overruns)
);

// ============================================================ DIAGNOSTICS
//
// pocket_diag draws the shell's state over the picture (its header says
// what, where). It is on whenever the menu's "Diagnostic overlay" is, and on
// its own while the ROM is not yet loaded, when colour bars stand in for the
// picture: a core that never gets past loading says so on screen instead of
// staying black.
//
// Flags (left to right, green = 1):
//   0 PLL locked            1 SDRAM initialised (mem_ready)
//   2 APF reset released    3 APF "all slots loaded" seen
//   4 rom_loaded            5 loader FIFO overflowed (should stay red)
//   6 board in reset        7 SDRAM read-back of words 0-3 == what was written
//   8 overlay option on     9 blinks about once a second (frame counter)
//   10-12 game id
//   13 the 68000 has waited through a bus cycle longer than 65536 clocks
//   14 a frame has passed with the 68000 completing fewer than 8192 bus cycles
//   15 the KC-002 has missed a swap (overrun)
//
// Counters (hex):
//   0 longest 68000 bus cycle, in 48 MHz clocks (the sprite snapshot's hold
//     gives ~00001000 in ordinary play; a held CPU shows millions)
//   1 the byte address of that bus cycle (which device held it)
//   2 high half: frames in which the 68000 completed fewer than 8192 bus
//     cycles; low half: the longest KC-002 draw, clocks / 64
//   3 longest wait on SDRAM port 4 (68000 ROM line), request to ack, clocks
//   4 longest wait on the SRAM (68000 external RAM), request to ack, clocks
//   5 KC-002 overruns (draws that missed their swap)
//   6 words 1,0 of line 0 as SDRAM reads them back    7 words 3,2 as read back
//
// Peaks and flags 13-15 hold until the overlay is turned OFF in the menu
// (diag_clr), so the routine is: overlay on to see the baseline, off to
// clear, play until the hitch, overlay on and photograph.
//
// The read-back is port NP of the controller: once per frame, after
// rom_loaded, it reads line 0 (the 68000's reset vector) and the overlay
// shows it beside the loader's copy (flag 7 is the comparison; the loader's
// copy itself is no longer shown). It re-reads every frame.
wire        mem_ready_48;
synch_3 s_memrdy48 (.i(mem_ready), .o(mem_ready_48), .clk(clk_core), .rise(), .fall());

reg  [15:0] exp_w0 = 16'd0, exp_w1 = 16'd0, exp_w2 = 16'd0, exp_w3 = 16'd0;
wire [31:0] diag_wait_max;
wire [23:0] diag_wait_addr;
wire [15:0] diag_stall_frames, diag_draw_max;
wire [7:0]  diag_spr_overruns;
reg         diag_opt_q = 1'b0;
wire        diag_clr = diag_opt_q & ~diag_opt;    // overlay turned off
reg  [31:0] w_rom4 = 32'd0, w_rom4_max = 32'd0, w_ram = 32'd0, w_ram_max = 32'd0;
reg         rom4_req_q = 1'b0, ram_req_q = 1'b0;
reg         f_wait = 1'b0, f_stall = 1'b0, f_over = 1'b0;
reg  [63:0] rb_line = 64'd0;
reg         rb_req  = 1'b0;
reg         vb_q    = 1'b0;
reg  [7:0]  frame   = 8'd0;
wire        rb_ack  = rom_ack[NP];
assign rom_req[NP]  = rb_req;
assign rom_addr[NP*SDR_AW +: SDR_AW] = {SDR_AW{1'b0}};
always @(posedge clk_core) begin
    diag_opt_q <= diag_opt;
    // Request-to-ack waits on the two memories the 68000 is held on. The
    // request is a level; it rises once per transfer and falls on the ack.
    rom4_req_q <= rom_req[4];
    ram_req_q  <= ram_req;
    if (board_rst || diag_clr) begin
        w_rom4 <= 32'd0; w_rom4_max <= 32'd0; w_ram <= 32'd0; w_ram_max <= 32'd0;
        f_wait <= 1'b0; f_stall <= 1'b0; f_over <= 1'b0;
    end else begin
        if (rom_req[4] && !rom4_req_q) w_rom4 <= 32'd1;
        else if (rom_req[4])           w_rom4 <= w_rom4 + 32'd1;
        if (rom_req[4] && w_rom4 > w_rom4_max) w_rom4_max <= w_rom4;
        if (ram_req && !ram_req_q) w_ram <= 32'd1;
        else if (ram_req)          w_ram <= w_ram + 32'd1;
        if (ram_req && w_ram > w_ram_max) w_ram_max <= w_ram;
        if (diag_wait_max > 32'd65536)  f_wait  <= 1'b1;
        if (diag_stall_frames != 16'd0) f_stall <= 1'b1;
        if (diag_spr_overruns != 8'd0)  f_over  <= 1'b1;
    end
    if (dl_wr && dl_addr[24:3] == 22'd0) begin
        case (dl_addr[2:1])
        2'd0: exp_w0 <= dl_data;
        2'd1: exp_w1 <= dl_data;
        2'd2: exp_w2 <= dl_data;
        2'd3: exp_w3 <= dl_data;
        endcase
    end
    vb_q <= vblank_b;
    if (vblank_b && !vb_q) frame <= frame + 8'd1;
    if (rb_req) begin
        if (rb_ack) begin
            rb_req  <= 1'b0;
            rb_line <= rom_dout[NP*64 +: 64];
        end
    end else if (rom_loaded && vblank_b && !vb_q) begin
        rb_req <= 1'b1;
    end
end
wire [63:0] exp_line = {exp_w3, exp_w2, exp_w1, exp_w0};
wire [15:0] diag_flags = {f_over, f_stall, f_wait, game, frame[5], diag_opt,
                          (rb_line == exp_line), board_rst, ldr_overflow, rom_loaded,
                          allcomplete_48, reset_n_48, mem_ready_48, locked_48};
wire [7:0]  dr, dg, db, mr, mg, mb;
pocket_diag u_diag (
    .clk    (clk_core),
    .ce_pix (ce_pix),
    .hblank (hblank),
    .vblank (vblank_b),
    .r_in   (r), .g_in (g), .b_in (b),
    .enable (diag_opt | ~rom_loaded),
    .bars   (~rom_loaded),
    .flags  (diag_flags),
    .cnt    ({rb_line[63:32], rb_line[31:0],
              24'd0, diag_spr_overruns, w_ram_max, w_rom4_max,
              diag_stall_frames, diag_draw_max,
              8'd0, diag_wait_addr, diag_wait_max}),
    .r_out  (dr), .g_out (dg), .b_out (db)
);

// Black behind the Pocket's menu: the game is paused under it.
assign {mr, mg, mb} = inmenu_48 ? 24'd0 : {dr, dg, db};

// ================================================================== video
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid90;

pocket_video u_video (
    .clk       (clk_core),
    .ce_pix    (ce_pix),
    .hs        (hs),
    .vs        (vs),
    .hblank    (hblank),
    .vblank    (vblank_b),
    .r         (mr),
    .g         (mg),
    .b         (mb),
    .clk_vid   (clk_vid),
    .video_rgb (video_rgb),
    .video_de  (video_de),
    .video_hs  (video_hs),
    .video_vs  (video_vs),
    .video_skip(video_skip)
);

// ================================================================== audio
//
// One signed 16-bit mono sample to both channels. sound_i2s (agg23, MIT)
// generates MCLK/SCLK/LRCK from clk_74a as Analogue's example does and moves
// each new sample across from the core clock through a small dcfifo.
sound_i2s #(
    .CHANNEL_WIDTH(16),
    .SIGNED_INPUT (1)
) u_i2s (
    .clk_74a   (clk_74a),
    .clk_audio (clk_core),
    .audio_l   (snd),
    .audio_r   (snd),
    .audio_mclk(audio_mclk),
    .audio_lrck(audio_lrck),
    .audio_dac (audio_dac)
);

endmodule

`default_nettype wire
