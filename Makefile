# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core — Copyright (C) 2026 alphanu1
#
#   make lint     verilator --lint-only over all RTL
#   make test     build and run every simulation harness
#   make area     yosys area estimate for a module (MOD=kaneko_tmap_layer)
#   make clean
#
# The board as a whole is simulated by sim/gtmr/build.sh and built for the
# Pocket by pocket/build.sh; these are the per-module harnesses under it.

VERILATOR ?= verilator
YOSYS     ?= yosys

RTL_DIRS  := rtl/video rtl/cpu rtl/sound rtl/mem rtl/io rtl/mcu
RTL       := $(wildcard $(patsubst %,%/*.sv,$(RTL_DIRS)))
# Simulation-only SystemVerilog (harness wrappers). Compiled into harnesses but
# never linted as core RTL and never instantiated from rtl/.
SIM_SV    := $(wildcard sim/*/*.sv)
# jt6295 and its dependencies, needed only by the OKI harness. Listed rather
# than wildcarded: the directory also holds jt6295_up4*.hex and a .m script.
JT6295_SIM := third_party/jt6295/hdl/jt6295.v third_party/jt6295/hdl/jt6295_acc.v \
              third_party/jt6295/hdl/jt6295_adpcm.v third_party/jt6295/hdl/jt6295_ctrl.v \
              third_party/jt6295/hdl/jt6295_rom.v third_party/jt6295/hdl/jt6295_serial.v \
              third_party/jt6295/hdl/jt6295_sh_rst.v third_party/jt6295/hdl/jt6295_timing.v \
              third_party/jt6295/hdl/jt12_comb.v third_party/jt6295/hdl/jt12_interpol.v

# -Wno-DECLFILENAME: a file holds a group of related modules, not one module
#   named after the file.
# -Wno-MULTITOP: for the same reason — kaneko_tmap.sv holds the address blocks
#   kaneko_tmap_fetch instantiates. Harness builds always pass an explicit
#   --top-module, so this only relaxes the standalone lint sweep.
VFLAGS    := -Wall -Wno-DECLFILENAME -Wno-MULTITOP
VBUILD    := --cc --exe --build -j 0 -O2 -Wno-fatal

# One entry per harness: <name>:<top module>:<harness source>[:<extra sources>]
HARNESSES := kaneko_tmap:kaneko_tmap_layer:sim/video/tb_kaneko_tmap.cpp \
             kaneko_tmap_fetch:kaneko_tmap_fetch:sim/video/tb_kaneko_tmap_fetch.cpp \
             kaneko_sdram:kaneko_sdram_harness:sim/mem/tb_kaneko_sdram.cpp \
             kaneko_irq:kaneko_irq:sim/cpu/tb_kaneko_irq.cpp \
             kaneko_regs16:kaneko_regs16:sim/video/tb_kaneko_regs16.cpp \
             kaneko_tilerom:kaneko_tilerom_harness:sim/video/tb_kaneko_tilerom.cpp \
             kaneko_tmap_line:kaneko_tmap_line:sim/video/tb_kaneko_tmap_line.cpp \
             kaneko_tline:kaneko_tline_harness:sim/video/tb_kaneko_tline.cpp \
             kaneko_oki:kaneko_oki_harness:sim/sound/tb_kaneko_oki.cpp:JT6295 \
             kaneko_toybox:kaneko_toybox:sim/mcu/tb_kaneko_toybox.cpp

.PHONY: all lint test clean area
# GCC writes temporaries to $TMPDIR, which defaults to /tmp — a 16 GB tmpfs
# here. Parallel Verilator builds of fx68k filled it and every harness failed
# with "Disk quota exceeded", which reads like a permissions or code fault.
export TMPDIR := $(CURDIR)/build/tmp
all: lint test

# ------------------------------------------------------------------- lint
# Linted as one set rather than file by file. Modules span files —
# kaneko_tmap_fetch instantiates the address blocks that live in
# kaneko_tmap.sv — and a per-file lint cannot resolve those. Verilator still
# checks every module it parses, so nothing is lost.
lint:
	@$(VERILATOR) --lint-only $(VFLAGS) $(RTL) >/dev/null 2>&1 || { \
	  $(VERILATOR) --lint-only $(VFLAGS) $(RTL); echo "LINT FAILED"; exit 1; }
	@echo "lint: $(words $(RTL)) file(s) clean"

# ------------------------------------------------------------------- test
# Each harness builds into its own obj_<name>/ tree, which .gitignore covers
# with /obj_*/ rather than a per-name list — a narrower pattern stops covering
# new harnesses the moment one is named differently.
test:
	@mkdir -p build/tmp
	@fail=0; \
	for h in $(HARNESSES); do \
	  name=$${h%%:*}; rest=$${h#*:}; top=$${rest%%:*}; rest2=$${rest#*:}; \
	  src=$${rest2%%:*}; extra=""; \
	  case "$$rest2" in \
	    *:JT6295) extra="$(JT6295_SIM)";; \
	  esac; \
	  $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	    --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src >/dev/null 2>&1 || { \
	      echo "BUILD FAILED: $$name"; \
	      $(VERILATOR) $(VBUILD) $(VFLAGS) --top-module $$top \
	        --Mdir build/obj_$$name -o $$name $(RTL) $(SIM_SV) $$extra $$src; fail=1; continue; }; \
	  ./build/obj_$$name/$$name || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi

# ------------------------------------------------------------------- area
MOD ?= kaneko_tmap_fetch
area:
	@$(YOSYS) -p "read_verilog -sv $(RTL); synth -top $(MOD); stat" 2>&1 | \
	  awk '/=== design hierarchy ===/,0' | head -40

# Everything generated lives under build/, so a clean is complete and git
# status stays readable.
clean:
	rm -rf build obj_* yosys.log abc.history
