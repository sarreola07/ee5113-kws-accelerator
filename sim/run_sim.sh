#!/usr/bin/env bash
# RTL simulation of the KWS accelerator against the Python golden model.
#
#   ./sim/run_sim.sh int8            # auto: Xcelium if available, else Icarus
#   ./sim/run_sim.sh int4 iverilog   # force Icarus Verilog (laptops)
#   ./sim/run_sim.sh int8 xcelium    # force Xcelium (crosby3, after setmyenv)
#   ./sim/run_sim.sh int8 fpga       # board-level test of fpga/fpga_top.v (Icarus)
#   VCD=1 ./sim/run_sim.sh int8      # also dump kws_tb.vcd (for waveforms/power)
#
# Runs in work/sim/<prec>/ (git-ignored). Prints TEST PASSED / TEST FAILED.
set -euo pipefail
PREC=${1:-int8}
SIM=${2:-auto}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/weights/$PREC"
[ -f "$W/kws_params.vh" ] || { echo "No $W - run python/quantize_export.py first"; exit 1; }

if [ "$SIM" = auto ]; then
    if command -v xrun >/dev/null 2>&1; then SIM=xcelium; else SIM=iverilog; fi
fi

RUN="$ROOT/work/sim/$PREC"
mkdir -p "$RUN" && cd "$RUN"
cp "$W"/test_x.mem "$W"/golden.mem "$W"/test_label.mem .
SRCS=("$ROOT"/rtl/*.v "$W/kws_rom.v" "$ROOT/tb/kws_tb.v")
PLUS=""; [ "${VCD:-0}" = 1 ] && PLUS="+vcd"

echo "== $SIM simulation, $PREC, in $RUN"
case "$SIM" in
  xcelium)  xrun -64bit -access +rwc -incdir "$W" "${SRCS[@]}" -top kws_tb $PLUS | tee sim.log ;;
  iverilog) iverilog -g2012 -I "$W" -o kws_tb.vvp "${SRCS[@]}"
            vvp -n kws_tb.vvp $PLUS | tee sim.log ;;
  fpga)     iverilog -g2012 -I "$W" -o fpga_tb.vvp "$ROOT"/rtl/*.v "$W/kws_rom.v" \
                "$W/fpga_clips_rom.v" "$ROOT/fpga/fpga_top.v" "$ROOT/tb/fpga_tb.v"
            vvp -n fpga_tb.vvp | tee sim.log ;;
  *) echo "unknown simulator $SIM"; exit 1 ;;
esac
grep -q "TEST PASSED" sim.log
