# Pocket tools

These are the scripts that make the game files for the Analogue Pocket. The
ROMs you supply are written into `build/`. Run anything that opens the zips
with `python3 -I` so Python can't pick up stray files from the folder you're
in.

## Making the `.rom` files

```sh
python3 -I tools/pocket/build_rom.py gtmr ~/Downloads build/pocket     # one game
python3 -I tools/pocket/build_rom.py all  ~/Downloads build/pocket     # all games
python3 -I tools/pocket/verify_rom.py all                              # verify against MAME
```

You can also give a list of ROM ids separated by commas, e.g. `gtmr,gtmr2`.

The core supports the following ROM ids: `gtmr`, `gtmre`, `gtmrusa`, `gtmr2` and `gtmr2u`.

Each image is exactly 0x1200000 bytes (18 MB), laid out the way the core reads it from SDRAM: maincpu, mcudata, view2, kan_spr, oki1 and
oki2, each at its fixed place, with zeros in the gaps. The mcudata is
word-swapped but **not** decrypted – the board does that itself.

The script finds each chip by its CRC32 and size, and will look through every
zip in the folder (the game's own zip and its parent's first), so merged, split
and non-merged sets all work. A `<rom id>/` folder of loose files works too.
The list of chips is copied from `ROM_START` in MAME's `kaneko16.cpp`, in the
same order, so where chips overlap you get exactly what MAME gets.

`verify_rom.py` runs MAME with `tools/mame_gtmr_regions.lua`, which saves
MAME's own copy of each region to `build/mame/regions/<rom id>/`, then compares
them with the image byte for byte. MAME decrypts the TOYBOX data when it
starts up, so the script decrypts the mcudata part of the image first (using
the tables from MAME's `kaneko_toybox.cpp`) before comparing.

For simulation, `--regions` writes one file per MAME region instead:

```sh
python3 -I tools/pocket/build_rom.py gtmr ~/Downloads build/roms --regions
# build/roms/gtmr_maincpu.bin, _mcudata.bin, _kan_spr.bin, _view2_0.bin,
# _view2_1.bin, _oki1.bin, _oki2.bin, _mcudata_decrypted.bin
```

## On the Analogue Pocket

Copy the image onto the SD card as

```
Assets/kaneko16/common/<rom id>.rom        e.g. Assets/kaneko16/common/gtmr.rom
```

Each game's instance JSON points at that file. The Pocket loads it at bridge
address 0, and byte *n* of the file ends up at SDRAM byte *n*.

## Checking against MAME

Everything from here on is for working on the core itself.

Run these through `mame_oracle.sh`. It gives each run a fresh, empty nvram and
cfg folder. MAME saves the 93C46 EEPROM when it quits and loads it again when
it starts, so otherwise every run would start from wherever the last one left
off. It also adds the flags autoboot needs (`-skip_gameinfo -autoboot_delay
0`). `ROMS=` changes where it looks for ROMs (`~/Downloads` by default) and
`MAME=` changes which MAME it runs.

### What's on screen at a given frame

```sh
tools/pocket/mame_oracle.sh tools/mame_gtmr_dump.lua gtmr \
    DUMP_DIR=build/mame/dump/gtmr DUMP_FRAME=900,2100,3300
python3 -I tools/pocket/gtmr_dump_view.py build/mame/dump/gtmr/f0*
```

Ask for one frame and it writes straight into `DUMP_DIR`. Ask for several and
each gets its own `f<NNNNN>/` folder. The top of the script lists every file
it writes and what's in it.

If you're looking for something in gtmr's attract mode, roughly: Kaneko logo
at frame 300, car intro 600, title 900, demo race 1200–3000, records table
3300, second demo race 4500–6300.

`gtmr_dump_view.py` turns a dump into `palette.png`, `sprite_layer.png` and
`screen.rgb`, and checks the dump makes sense on its own terms. Wherever the
sprite layer has priority 3, the picture has to equal `palette[0x4000 + pen]`,
and with every tile layer turned off the whole picture has to be the sprite
layer over fill pen 0x7f00.

`LAYERS_OFF=spr` or `LAYERS_OFF=t00,t01,t10,t11` (VIEW2 chip, then layer) also
draws that frame without those layers, as `screen_off_<list>.png`. Nothing
else in the dump changes.

### Which frame is which

Frame *N* is the *N*th frame notification since power-on, so
`screen_frame_number` is *N* − 1. Everything is captured inside that
notification, which MAME sends just after it has drawn picture *N* and before
the CPU carries on:

| file | what it shows |
|---|---|
| VIEW2 VRAM / regs, palette, sprite regs, live sprite RAM, work RAM, MCU RAM, 310000 RAM | the moment picture *N* was drawn – the tilemaps came from exactly these bytes |
| `spriteram_buffered.bin` | the buffer the KC-002 drew picture *N*'s sprites from: live sprite RAM as it was copied at line 224 of frame *N* − 1 |
| `spriteram_next.bin` | the buffer as it is now, copied at line 224 of frame *N* – it draws picture *N* + 1 |
| `sprite_bitmap.bin` | the sprite layer drawn at line 224 of frame *N* and mixed into picture *N* (`pri<<14 \| pen`, colour 0x4000 + pen) |
| `spr_regs_at_draw.bin` | the sprite regs when the 68000 takes the level 5 interrupt, just after that draw |
| `screen.png` | picture *N* |

Don't use `screen:pixels()` to get the picture. Inside a frame notification
it gives you picture *N* − 1, coloured with palette *N*, because MAME swaps
its two screen bitmaps after drawing. That's where the "picture *N* matches
state *N* − 1" lag in the MiSTer core's `mame_dump_frame.lua` came from. If you want to
see it for yourself, `PIXELS_TOO=1` writes it anyway, as
`pixels_at_notifier.rgb`.

### Tracing the bus from power-on

```sh
tools/pocket/mame_oracle.sh tools/mame_gtmr_bus_trace.lua gtmr \
    BUS_TRACE_OUT=build/mame/gtmr_bus.txt BUS_TRACE_COUNT=200000
python3 -I tools/pocket/diff_gtmr_trace.py ours.txt build/mame/gtmr_bus.txt gtmr
python3 -I tools/pocket/diff_gtmr_trace.py --census build/mame/gtmr_bus.txt gtmr
```

The traces are in the same format as the MiSTer core's `mame_bus_trace.lua` writes
(`addr R|W data mask`, plus `# frame N` lines that the readers skip). The
script starts at machine time 0, before the 68000's first cycle, so there's no
need to fake a reset. `BUS_TRACE_DATA_ONLY=1` leaves out instruction fetches
but still keeps the wheel port at 0ffffe. `diff_gtmr_trace.py` compares
traces the same way `diff_bus_trace.py` does, but with this board's 1 MB ROM
window and region names.

In MAME's traces, 0xd00000 (TOYBOX status) and the watchdog at 0xa00000
always read 0000. So if the core's TOYBOX is busy for a few cycles you'll see
some extra poll loops in our trace – that's fine.

### Frame-by-frame I/O, while playing

```sh
printf '400 coin=1\n410 coin=0\n440 start=1\n450 start=0\n520 b1=1\n530 b1=0\n700 b1=1\n710 b1=0\n1000 b2=1\n1150 right=1\n' > build/mame/plan.txt
tools/pocket/mame_oracle.sh tools/mame_gtmr_io_profile.lua gtmr \
    IO_PROFILE_OUT=build/mame/gtmr_io.txt IO_PROFILE_FRAMES=1800 IO_PROFILE_PLAY=1 \
    IO_PROFILE_PLAN=build/mame/plan.txt IO_PROFILE_SNAP_DIR=build/mame/snaps IO_PROFILE_SNAP_EVERY=30
```

You get one line per frame showing what the 68000 did with the OKI sound
chips (every command byte and status value), the hit chip, the TOYBOX, the
watchdog and the inputs.

The plan file is a list of `<frame> name=0/1 ...` lines, using coin, start,
b1, b2, up, down, left and right. A value stays put until you change it. The
plan above puts a coin in, picks the car and the first stage, holds the
accelerator (button 2) and steers right into the wall at about frame 1230.
The simulation harness takes the same file (`tb_gtmr ... --inputs
build/mame/plan.txt`), and its stats.csv shows the longest bus cycle in each
frame and its address.

## Reading the program

```sh
python3 -I tools/pocket/dasm68k.py build/pocket/gtmr.rom 0xd232 0xd2d4
```

This disassembles part of the 68000 program straight from the `.rom` image
(the first 1 MB of it is MAME's maincpu region, in big-endian words). You'll
need capstone (`python3 -m pip install --user capstone`). `-I` normally hides
your user packages, so the script adds them back itself.
