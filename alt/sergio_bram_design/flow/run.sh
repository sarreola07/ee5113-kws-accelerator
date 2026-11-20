#!/usr/bin/env bash
# ASIC flow driver (run on crosby3 after: source /home/opt2/setmyenv)
#
#   ./flow/run.sh syn  int8      # Genus synthesis
#   ./flow/run.sh pnr  int8      # Innovus place & route (needs syn first)
#   ./flow/run.sh all  int4      # both
#   ./flow/run.sh save int8      # copy key reports into results/int8/ (to commit)
#   CLK_PERIOD_NS=4 ./flow/run.sh syn int8    # different clock target
#
# Everything runs in work/<prec>/{syn,pnr}/ which is git-ignored.
set -euo pipefail
STEP=${1:?usage: run.sh syn|pnr|all|save int8|int4}
PREC=${2:-int8}
export REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export KWS_PREC=$PREC
[ -f "$REPO_ROOT/weights/$PREC/kws_rom.v" ] || { echo "No weights/$PREC - run python/quantize_export.py"; exit 1; }

syn() {
    mkdir -p "$REPO_ROOT/work/$PREC/syn" && cd "$REPO_ROOT/work/$PREC/syn"
    genus -batch -files "$REPO_ROOT/flow/syn/genus.tcl" -log genus.log
}
pnr() {
    mkdir -p "$REPO_ROOT/work/$PREC/pnr" && cd "$REPO_ROOT/work/$PREC/pnr"
    innovus -no_gui -overwrite -files "$REPO_ROOT/flow/pnr/innovus.tcl" -log innovus.log
}
save() {
    local dst="$REPO_ROOT/results/$PREC"
    mkdir -p "$dst/syn" "$dst/pnr"
    cp -v "$REPO_ROOT"/work/$PREC/syn/reports/*.rpt "$dst/syn/" 2>/dev/null || true
    cp -v "$REPO_ROOT"/work/$PREC/pnr/reports/*.rpt "$dst/pnr/" 2>/dev/null || true
    cp -v "$REPO_ROOT/weights/$PREC/summary.json" "$dst/" 2>/dev/null || true
    echo "Now: git add results/$PREC && git commit -m 'results: $PREC' && git push"
}

case "$STEP" in
    syn)  syn ;;
    pnr)  pnr ;;
    all)  syn; pnr ;;
    save) save ;;
    *) echo "unknown step $STEP"; exit 1 ;;
esac
