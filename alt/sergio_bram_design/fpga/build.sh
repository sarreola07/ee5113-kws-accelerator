#!/usr/bin/env bash
# Linux: ./fpga/build.sh [int8|int4] [nexys4ddr|nexys4] [program]
set -euo pipefail
cd "$(dirname "$0")/.."
PREC=${1:-int8}; BOARD=${2:-nexys4ddr}
mkdir -p fpga/work
vivado -mode batch -nojournal -log fpga/work/vivado_build.log -source fpga/build.tcl -tclargs "$PREC" "$BOARD"
if [ "${3:-}" = program ]; then
  vivado -mode batch -nojournal -log fpga/work/vivado_program.log -source fpga/program.tcl -tclargs "$PREC" "$BOARD"
fi
