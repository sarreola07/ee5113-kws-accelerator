# Low-Precision Hardware Accelerator for Voice Keyword Recognition

EE 5113 VLSI System Design: final project (UTSA). It is a small neural-network accelerator
that recognizes 6 spoken words (**yes, no, on, off, up, down**). It is built at **INT8** and **INT4**
precision so the two can be compared on area, power, timing and accuracy, using:

- **Python**: Google Speech Commands → MFCC → small FC network → INT8/INT4 quantization
- **Verilog**: one shared MAC, FC-layer engine, ReLU and argmax (`rtl/`)
- **Cadence Genus + Innovus**: 45 nm (gpdk045) synthesis and place & route on `crosby3.utsarr.net`
- **Xilinx Vivado**: live demo on a Digilent **Nexys 4** (Artix-7 XC7A100T)

> **New machine or new partner? Start with [`docs/SETUP.md`](docs/SETUP.md).**
> For the latest status, read the newest file in [`docs/progress/`](docs/progress/).

## Architecture

```
            ┌──────────── kws_top ────────────────────────────────────┐
 load_* ───►│ in_buf[250]──┐                                          │
            │              ▼                                          │
            │   W1/B1 ROM ─► fc_layer (1 MAC, reused) ─► relu ─► hid_buf[32]
            │   W2/B2 ROM ─►    (layer 1, then layer 2)               │
            │                         └─► argmax ─► class_out (0..5)  │──► done
            └──────────────────────────────────────────────────────────┘
```

- Layer 1 is 250 inputs → 32 hidden, with ReLU and a power-of-two requantize.
- Layer 2 is 32 → 6 logits, followed by argmax.
- Each clip takes about 8,300 cycles, which is 83 µs at 100 MHz.
- The bit width, sizes and weights come from `weights/<prec>/`, which `python/quantize_export.py` generates.

## Repository map

| Path | Contents |
|------|----------|
| `python/` | `train.py` (float model), `quantize_export.py` (INT8/INT4 export), `kws_common.py` (bit-exact golden model) |
| `weights/<int8,int4>/` | Generated ROMs (`kws_rom.v`), params (`kws_params.vh`), test vectors, `summary.json` |
| `rtl/` | `mac.v`, `fc_layer.v`, `relu.v`, `argmax.v`, `kws_top.v` |
| `tb/`, `sim/run_sim.sh` | Self-checking testbenches. Xcelium (crosby3) or Icarus (laptop) |
| `flow/` | `config.tcl` (library paths), `constraints.sdc`, `syn/genus.tcl`, `pnr/innovus.tcl`, `run.sh` |
| `fpga/` | `fpga_top.v`, Nexys 4 / 4 DDR pin constraints, Vivado `build.tcl` / `program.tcl` |
| `results/` | Curated reports that are committed for the report and slides |
| `docs/` | `SETUP.md`, `progress/` milestone logs, `report/`, `slides/`, `reference/` (proposal, guidelines, tutorial) |
| `CLAUDE.md` | Instructions Claude follows on every machine |

## Quick commands

```bash
python python/quantize_export.py --synthetic      # placeholder weights, no dataset
python python/train.py && python python/quantize_export.py   # real model (laptop)
./sim/run_sim.sh int8                              # RTL vs Python golden → TEST PASSED
./sim/run_sim.sh int8 fpga                         # board-level sim of the FPGA top
./flow/run.sh all int8 && ./flow/run.sh save int8  # crosby3: Genus + Innovus, keep reports
fpga\build.bat int8 nexys4ddr program              # Windows: build + program the board
```

## Status

| Item | Status |
|------|--------|
| Repo, docs, collaboration workflow | ✅ done |
| RTL + testbench (bit-exact vs Python, INT8 & INT4) | ✅ passes with **synthetic** weights |
| FPGA top + Nexys 4 constraints | ✅ simulated; ⏳ first Vivado build on the board |
| Train the real model on Speech Commands | ⏳ |
| gpdk045 paths in `flow/config.tcl` + first Genus/Innovus run | ⏳ needs crosby3 |
| Results tables, report, slides | ⏳ |

## Progress log

| Date | Milestone |
|------|-----------|
| 2026-11-18 | [Repository and environment set up](docs/progress/2026-11-18-repo-setup.md) |
