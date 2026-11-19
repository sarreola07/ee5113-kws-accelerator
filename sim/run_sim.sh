#!/usr/bin/env bash
# RTL simulation of the KWS accelerator against the Python golden model (Linux / Mac / crosby3).
#
#   ./sim/run_sim.sh int8             # auto: xsim (Vivado) if found, else xcelium, else Icarus
#   ./sim/run_sim.sh int4 xcelium     # force Xcelium (crosby3, after source /home/opt2/setmyenv)
#   ./sim/run_sim.sh int8 iverilog    # force Icarus Verilog (laptops)
#   ./sim/run_sim.sh fpga             # board-level test of fpga/kws_fpga_top.v (both precisions)
#
# Windows: use sim\run_sim.ps1 instead (Vivado xsim).
# Runs in work/sim/<target>/ (git-ignored). Exit status 0 only for TEST PASSED.
set -euo pipefail
TARGET=${1:-int8}
SIM=${2:-auto}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ "$SIM" = auto ]; then
    if   command -v xvlog >/dev/null 2>&1; then SIM=xsim
    elif command -v xrun  >/dev/null 2>&1; then SIM=xcelium
    else SIM=iverilog; fi
fi

RUN="$ROOT/work/sim/$TARGET"
mkdir -p "$RUN" && cd "$RUN" && rm -rf sim.log xsim.dir xcelium.d sim.vvp
if [ "$TARGET" = fpga ]; then
    cp "$ROOT"/fpga/mem/*.mem .
    SRCS=("$ROOT/rtl/kws_accel.v" "$ROOT/fpga/kws_fpga_core.v" "$ROOT/fpga/kws_fpga_top.v" "$ROOT/tb/tb_fpga_top.v")
    TOP=tb_fpga_top
else
    W="$ROOT/weights/$TARGET"
    [ -f "$W/kws_params.vh" ] || { echo "No $W - run python/export_hw.py first"; exit 1; }
    cp "$W"/* .
    echo "\`define KWS_TOP kws_$TARGET" >> kws_params.vh      # picks kws_int8 / kws_int4
    SRCS=("$ROOT/rtl/kws_accel.v" "$ROOT/rtl/kws_top.v" "$ROOT/tb/tb_kws.v")
    TOP=tb_kws
fi

echo "== $SIM simulation of $TARGET in $RUN"
case "$SIM" in
  xsim)
    xvlog "${SRCS[@]}" -i . > xvlog.out || { cat xvlog.out; exit 1; }
    xelab $TOP -s sim_snap -debug off > xelab.out || { cat xelab.out; exit 1; }
    xsim sim_snap -R | tee sim.log ;;
  xcelium)
    xrun -64bit -timescale 1ns/1ps -incdir . "${SRCS[@]}" -top $TOP -l sim.log ;;
  iverilog)
    iverilog -g2005 -I . -o sim.vvp "${SRCS[@]}" && vvp -n sim.vvp | tee sim.log ;;
  *) echo "unknown simulator $SIM"; exit 1 ;;
esac
grep -q "TEST PASSED" sim.log
