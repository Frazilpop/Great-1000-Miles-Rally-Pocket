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
Under **Core Settings** there are three options:

- **Test Mode** – the arcade cabinet's operator menu
- **Reset Game**
- **Diagnostic overlay** – probably best to ignore this

## Technical details

- The core recreates Kaneko's arcade board in hardware logic, built on [alphanu1's Kaneko16 MiSTer core](https://github.com/alphanu1/kaneko16-mister) with the Mille Miglia board and a Pocket shell.
- It's been checked against MAME in simulation – over three million moves of the game's main processor, identical from power-on.
- To build it yourself: `tools/bootstrap.sh`, then `sh pocket/build.sh` (Quartus Prime Lite 21.1 in Docker, about ten minutes). The finished SD card layout can be found in `pocket/dist/`.

## Credits and licence

- **alphanu1** – the Kaneko16 MiSTer core this is built on.
- **Jorge Cwik (ijor)** – fx68k, the 68000 processor.
- **Jose Tejada (jotego)** – jt6295, the sound chips.
- **agg23** – the Pocket utilities used for loading, PSRAM and audio.
- **Analogue** – the openFPGA core framework.
- **The MAME team** – whose work on the Kaneko boards was referenced.
- Pocket port by **Frazilpop**.

GPL-3.0-only. [`THIRD-PARTY.md`](THIRD-PARTY.md) lists every dependency and its
licence.

Great 1000 Miles Rally and Mille Miglia 2 are © Kaneko. This project contains
no game data.
