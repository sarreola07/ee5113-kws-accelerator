#!/bin/bash
#############################################################################
# results.sh - INT8 vs INT4 comparison table for the report
# Run after synthesis, the Fmax runs and Innovus:   bash results.sh
# It only reads report files from out_int8/ and out_int4/.
#############################################################################
cd "$(dirname "$0")"

num()  { [ -n "$1" ] && echo "$1" || echo "n/a"; }
# calc FORMAT EXPRESSION VALUE  (x in EXPRESSION is VALUE; n/a if VALUE is empty)
calc() { [ -z "$3" ] && { echo "n/a"; return; }; awk -v x="$3" "BEGIN { printf \"$1\", $2 }"; }
# chk FILE TEXT -> clean / check / n/a
chk()  { [ -f "$1" ] || { echo "n/a"; return; }; grep -q "$2" "$1" && echo clean || echo check; }

declare -A V
for b in 8 4; do
    d=out_int$b; n=kws_int$b
    # --- synthesis at 100 MHz (RC) ---
    V[cells$b]=$(awk -v n=$n '$1==n {print $2; exit}' $d/${n}_area.rpt 2>/dev/null)
    V[sarea$b]=$(awk -v n=$n '$1==n {print $3; exit}' $d/${n}_area.rpt 2>/dev/null)
    V[flops$b]=$(awk '/Sequential Instance Count/ {print $NF; exit}' $d/${n}_qor.rpt 2>/dev/null)
    p=$(awk -v n=$n '$1==n {print $5; exit}' $d/${n}_pwr.rpt 2>/dev/null)        # nW
    V[spwr$b]=$(calc "%.3f" "x/1e6" "$p")                            # mW
    # --- speed-pushed synthesis (2 ns clock) -> Fmax ---
    s=$(awk -F: '/Timing slack/ {gsub(/[ps ]/,"",$2); print $2; exit}' $d/${n}_fmax_time.rpt 2>/dev/null)
    V[cp$b]=$(calc "%.2f" "2.0-x/1000" "$s")                       # ns
    V[fmax$b]=$(calc "%.0f" "1000/(2.0-x/1000)" "$s")              # MHz
    # --- Innovus after routing ---
    V[core$b]=$(awk -F: '/Total area of Core:/ {split($2,a," "); print a[1]; exit}' $d/${n}_summary.rpt 2>/dev/null)
    V[chip$b]=$(awk -F: '/Total area of Chip:/ {split($2,a," "); print a[1]; exit}' $d/${n}_summary.rpt 2>/dev/null)
    V[cellarea$b]=$(awk -F: '/Standard cells\(Subtracting Physical Cells\)/ {split($2,a," "); print a[1]; exit}' $d/${n}_summary.rpt 2>/dev/null)
    V[wns$b]=$(awk '/Slack Time/ {print $NF; exit}' $d/${n}_final_timing.rpt 2>/dev/null)
    ip=$(awk -F: '/^Total Power:/ {gsub(/[ 	]/,"",$2); print $2; exit}' $d/${n}_innovus_power.rpt 2>/dev/null)
    V[ipwr$b]=$(calc "%.3f" "x" "$ip")                                         # mW
    V[energy$b]=$(calc "%.1f" "x*82.7" "$ip")                       # nJ per inference
    V[drc$b]=$(chk $d/${n}.drc.rpt "No DRC violations")
    V[conn$b]=$(chk $d/${n}.conn.rpt "Found no problems")
    V[ant$b]=$(chk $d/${n}.antenna.rpt "No Violations Found")
    # --- Python model accuracy (bit-exact with the hardware) ---
    V[acc$b]=$(awk -F: '/full test set/ {split($2,a," "); print a[1]; exit}' ../../weights/int$b/summary.txt 2>/dev/null)
done

row() { printf "  %-38s %14s %14s\n" "$1" "$(num "$2")" "$(num "$3")"; }
line() { echo "  ----------------------------------------------------------------------"; }
echo
echo "  KWS accelerator: INT8 vs INT4   (tsmc18 slow corner, 100 MHz)"
line
row "Metric"                          "INT8"            "INT4"
line
row "Weight memory (bytes)"           "8192"            "4096"
row "Test accuracy (Python = HW)"     "${V[acc8]}"      "${V[acc4]}"
row "Cycles per inference"            "8270"            "8270"
line
row "Synthesis: cells"                "${V[cells8]}"    "${V[cells4]}"
row "Synthesis: flip-flops"           "${V[flops8]}"    "${V[flops4]}"
row "Synthesis: cell area (um^2)"     "${V[sarea8]}"    "${V[sarea4]}"
row "Synthesis: power (mW)"           "${V[spwr8]}"     "${V[spwr4]}"
row "Critical path, fast run (ns)"    "${V[cp8]}"       "${V[cp4]}"
row "Maximum clock Fmax (MHz)"        "${V[fmax8]}"     "${V[fmax4]}"
line
row "Layout: std-cell area (um^2)"    "${V[cellarea8]}" "${V[cellarea4]}"
row "Layout: core area (um^2)"        "${V[core8]}"     "${V[core4]}"
row "Layout: chip area (um^2)"        "${V[chip8]}"     "${V[chip4]}"
row "Layout: worst slack @100MHz (ns)" "${V[wns8]}"     "${V[wns4]}"
row "Layout: total power (mW)"        "${V[ipwr8]}"     "${V[ipwr4]}"
row "Energy per inference (nJ)"       "${V[energy8]}"   "${V[energy4]}"
row "DRC / connectivity / antenna"    "${V[drc8]}/${V[conn8]}/${V[ant8]}" "${V[drc4]}/${V[conn4]}/${V[ant4]}"
line
echo "  Energy = layout power x 82.7 us (8270 cycles at 100 MHz)."
echo "  Fmax is for the core only (memory access time not included)."
echo
