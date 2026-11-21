#!/usr/bin/env bash
# Copies the curated reports of a finished run into the repo's results/ folder.
#   cd flow/tsmc18 && ./save_results.sh int8        (or int4)
# Then: git add ../../results/<prec> && git commit && git push
set -euo pipefail
cd "$(dirname "$0")"
PREC=${1:?usage: ./save_results.sh int8|int4}
SRC=out_$PREC
DST=../../results/$PREC
[ -d "$SRC" ] || { echo "No $SRC - run synthesis and Innovus first"; exit 1; }
mkdir -p "$DST/layout" "$DST/netlist" "$DST/timing"
cp "$SRC"/*.rpt "$SRC"/*.sdc "$SRC"/*.spec "$SRC"/*.checkPlace "$DST"/ 2>/dev/null || true
cp "$SRC"/*.png "$DST/layout/" 2>/dev/null || true
cp "$SRC"/*_Net.v "$DST/netlist/" 2>/dev/null || true
for f in "$SRC"/timingReports/*.summary.gz; do
    [ -e "$f" ] && gunzip -c "$f" > "$DST/timing/$(basename "${f%.gz}").txt"
done
echo "Saved reports of $PREC into $DST (GDS, database and logs are not copied)."
