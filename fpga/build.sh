#!/usr/bin/env bash
# Linux: ./fpga/build.sh [nexys4ddr|nexys4|nexys_a7_50t] [program]
# Builds results/fpga/kws_fpga_top_<board>.bit (INT8 + INT4 on one FPGA); "program" also loads it.
# Vivado must be on PATH (source <Vivado>/settings64.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
BOARD=${1:-nexys4ddr}
mkdir -p fpga/work
vivado -mode batch -nojournal -log fpga/work/vivado_build.log -source fpga/build.tcl -tclargs "$BOARD"
if [ "${2:-}" = program ]; then
    vivado -mode batch -nojournal -log fpga/work/vivado_program.log -source fpga/program.tcl -tclargs "$BOARD"
fi
