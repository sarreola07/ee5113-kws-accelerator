#!/usr/bin/env bash
# RTL simulation of the KWS accelerator against the Python golden model.
#
#   ./sim/run_sim.sh int8            # auto: Xcelium if available, else Icarus
#   ./sim/run_sim.sh int4 iverilog   # force Icarus Verilog (laptops, CI)
#   ./sim/run_sim.sh int8 xcelium    # force Xcelium (crosby3, after setmyenv)
#   ./sim/run_sim.sh int8 fpga       # board-level test of fpga/fpga_top.v (Icarus)
#
# Options (environment variables):
#   TB_CLK_NS=5   clock period in ns (default 10). The result must not depend on it.
#   VCD=1         dump the DUT for ONE inference (clip VCD_CLIP, default 1, after a
#                 warm-up clip) to kws_tb.vcd, and print a VCD_WINDOW line
#   WAVES=1       debug: dump every signal of the whole run (big file)
#
# Runs in work/sim/<prec>/ (fpga mode: work/sim/<prec>_fpga/), which is git-ignored.
# Prints TEST PASSED / TEST FAILED; the exit status is 0 only for TEST PASSED.
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
if [ "$SIM" = fpga ]; then RUN="$ROOT/work/sim/${PREC}_fpga"; fi
mkdir -p "$RUN" && cd "$RUN"
rm -f sim.log kws_tb.vcd
cp "$W"/test_x.mem "$W"/golden.mem "$W"/test_label.mem .

PLUS=""
if [ "${VCD:-0}" = 1 ]; then PLUS="$PLUS +vcd +vcd_clip=${VCD_CLIP:-1}"; fi
if [ "${WAVES:-0}" = 1 ]; then PLUS="$PLUS +waves"; fi
CLK=${TB_CLK_NS:-10.0}

echo "== $SIM simulation, $PREC, clock $CLK ns, in $RUN"
case "$SIM" in
  xcelium)
    xrun -64bit -access +r -timescale 1ns/1ps -incdir "$W" +define+TB_CLK_NS=$CLK \
         "$ROOT"/rtl/*.v "$W/kws_rom.v" "$ROOT/tb/kws_tb.v" -top kws_tb $PLUS -l sim.log ;;
  iverilog)
    iverilog -g2012 -I "$W" -DTB_CLK_NS=$CLK -o kws_tb.vvp \
             "$ROOT"/rtl/*.v "$W/kws_rom.v" "$ROOT/tb/kws_tb.v"
    vvp -n kws_tb.vvp $PLUS | tee sim.log ;;
  fpga)
    iverilog -g2012 -I "$W" -o fpga_tb.vvp "$ROOT"/rtl/*.v "$W/kws_rom.v" \
             "$W/fpga_clips_rom.v" "$ROOT/fpga/fpga_top.v" "$ROOT/tb/fpga_tb.v"
    vvp -n fpga_tb.vvp | tee sim.log ;;
  *) echo "unknown simulator $SIM"; exit 1 ;;
esac
grep -q "TEST PASSED" sim.log
