#!/usr/bin/env bash
# Locate the 45 nm (gpdk045 / gsclib045) library files on crosby3 so you can
# fill in flow/config.tcl.  Usage:  ./flow/find_libs.sh  [search_root ...]
ROOTS=${*:-/home/opt2 /opt /usr/local}
echo "Searching: $ROOTS  (this can take a minute)"
for pat in "*basicCells*.lib" "gsclib045*tech*.lef" "gsclib045*macro*.lef" \
           "*.tch" "qrcTechFile" "gds2*.map" "*.map" "gsclib045*.gds"; do
    echo; echo "### $pat"
    find $ROOTS -iname "$pat" -path "*45*" 2>/dev/null | head -10
done
echo; echo "Copy the right paths into flow/config.tcl (LIB_SLOW, LIB_FAST, LEF_FILES, QRC_TECH, GDS_MAP)."
