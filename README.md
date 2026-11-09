![Great 1000 Miles Rally banner](pocket/art/kaneko16-banner.png)

# Great 1000 Miles Rally – Mille Miglia for the Analogue Pocket

**One of the all-time great overhead arcade racers, now on the Analogue
Pocket!**

The real Mille Miglia was a thousand-mile dash across Italy. Now you can
experience the same high speed thrills on your Analogue Pocket. It gets
even better – this core supports five versions of the 1994 original
Great 1000 Miles Rally and its 1995 sequel.

## Supported ROMs

| ROM id | game | notes |
| --- | --- | --- |
| `gtmr` | Great 1000 Miles Rally / 1000 Miglia (1994) | The original 1994 release |
| `gtmre` | Great 1000 Miles Rally: Evolution Model!!! (1994) | This version has two extra cars, reworked stages and a new intro |
| `gtmrusa` | Great 1000 Miles Rally: U.S.A Version! (1994) | Evolution Model, but with USA flags! |
| `gtmr2` | Mille Miglia 2: Great 1000 Miles Rally (1995) | The 1995 sequel |
| `gtmr2u` | Great 1000 Miles Rally 2 USA (1995) | The sequel's US release |

## Installation

No game data comes with this core – you will need to supply your own MAME ROM
sets (`gtmr.zip`, `gtmr2.zip` etc).

### Make the game files

You can't just drag and drop your MAME files. The Analogue Pocket can't read
zips, and the core needs each game as one file with every chip in its correct
place. There's a script in the repository that puts this all together for you,
or you can use a tool like Pocket Updater.

1. Download this repository (**Code → Download ZIP**, then unzip it) or clone it. You'll need Python 3 to run the build script.
2. Put your MAME zips in a folder.
3. In a terminal, from the repository's folder, run the script with the ROM ids you want from the table above, separated by commas:
   
   ```sh
   python3 tools/pocket/build_rom.py gtmr,gtmr2 ~/path/to/roms build/pocket
   ```
   
   So this will write `build/pocket/gtmr.rom` and `build/pocket/gtmr2.rom`. The script finds the right chips in whatever zips you have, merged or split, and checks them against MAME's checksums.

[`tools/pocket/README.md`](tools/pocket/README.md) includes more info on this.

### Copy to the Pocket

1. Copy the `Cores`, `Platforms` and `Assets` folders from a release onto your Pocket's SD card.
2. Copy your `.rom` files into `Assets/kaneko16/common/` – for example `Assets/kaneko16/common/gtmr.rom`.
3. On the Pocket: openFPGA → Arcade → Great 1000 Miles Rally, and pick your rom.

## Controls

| Input | Action |
| --- | --- |
| D-pad | steer |
| A | accelerate |
| B | brake |
| Select | insert coin |
| Start | start |

The Pocket's own menu has the usual **Display Mode** and **Controls** entries.
Under **Core Settings** there are four options:

- **Test Mode** – the arcade cabinet's operator menu
- **Hide speed lines** – turns off the streaks the game draws at high speed
- **Reset Game**
- **Diagnostic overlay** – probably best to ignore this

## Memories and Sleep

The core supports Memories as well as Sleep / Wake. Memories store the board's
EEPROM, where the game keeps its settings and best times, meaning these are
saved / loaded too.

## Analogizer

The core supports RndMnkIII's [Analogizer](https://github.com/RndMnkIII/Analogizer),
which plugs into the Pocket's cartridge slot. It sends the arcade board's own
picture to a CRT or TV, and lets you play with SNAC controllers.

- **Video** – the board's original 15 kHz signal as RGBS, RGsB, YPbPr or Y/C (NTSC or PAL), or 31 kHz for a VGA monitor through the scandoubler, with 0–75 % scanlines (HQ2x shows as the plain scandoubler).
- **Controllers** – DB15, NES, SNES and PC Engine pads through a SNAC adapter, for either player. The buttons work as they do on the Pocket.
- **Setup** – the core reads the shared `analogizer.bin` in `Assets/analogizer/common/`, which Pupdate or AnalogizerConfigurator writes. That file sets the video mode, the controllers and whether the Pocket's own screen stays on. Without it the core works as normal.

Once an Analogizer is set up in `analogizer.bin`, the core drives the cartridge
slot, as every Analogizer core does, so play with the adapter in the slot
rather than a game cartridge. Without it set up, the slot's pins are left idle,
and a cartridge left in the slot is fine. This is standard Analogizer
functionality.

Technical details

- The core recreates Kaneko's arcade board in hardware logic, built on [alphanu1's Kaneko16 MiSTer core](https://github.com/alphanu1/kaneko16-mister) with the Mille Miglia board and a Pocket shell.
- It's been checked against MAME in simulation – over three million moves of the game's main processor, identical from power-on.
- Sound: every phrase as the arcade plays it. In simulation the two sound chips play the same phrases as MAME, every one that runs to its end exact to the sample, in races and attract on the original set, Evolution and Mille Miglia 2.
- To build it yourself: `tools/bootstrap.sh`, then `sh pocket/build.sh` (Quartus Prime Lite 21.1 in Docker, about ten minutes). The finished SD card layout can be found in `pocket/dist/`.

## Credits and licence

- **alphanu1** – the Kaneko16 MiSTer core this is built on.
- **Jorge Cwik (ijor)** – fx68k, the 68000 processor.
- **Jose Tejada (jotego)** – jt6295, the sound chips.
- **RndMnkIII** – the Analogizer and its adapter module, with **Mike Simone**'s Y/C encoder and **Till Harbaum**'s scandoubler from MiST.
- **agg23** – the Pocket utilities used for loading, PSRAM and audio.
- **Analogue** – the openFPGA core framework.
- **The MAME team** – whose work on the Kaneko boards was referenced.
- Pocket port by **Frazilpop**.

GPL-3.0-only. [`THIRD-PARTY.md`](THIRD-PARTY.md) lists every dependency and its
licence.

Great 1000 Miles Rally and Mille Miglia 2 are © Kaneko. This project contains
no game data.
