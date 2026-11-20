# run_sim.ps1 - RTL simulation on Windows with the Vivado simulator (xsim), no GUI.
#
#   .\sim\run_sim.ps1 int8        # accelerator vs Python, INT8   -> TEST PASSED
#   .\sim\run_sim.ps1 int4        # same for INT4
#   .\sim\run_sim.ps1 fpga        # board-level test of fpga/kws_fpga_top.v (both precisions)
#
# Vivado's bin folder is found automatically under C:\Xilinx\Vivado, or set $env:VIVADO_BIN.
# Runs in work\sim\<target>\ (git-ignored). Exit code 0 only for TEST PASSED.
param([string]$Target = "int8")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

$V = $env:VIVADO_BIN
if (-not $V) {
    $V = Get-ChildItem "C:\Xilinx\Vivado\*\bin\xvlog.bat" -ErrorAction SilentlyContinue |
         Sort-Object FullName | Select-Object -Last 1 | ForEach-Object { $_.DirectoryName }
}
if (-not $V) { throw "Vivado not found: set `$env:VIVADO_BIN to the Vivado bin folder" }
# some shells (e.g. AI agents) set this, which stops Vivado's .bat files from working
Remove-Item env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue

$Run = Join-Path $Root "work\sim\$Target"
New-Item -ItemType Directory -Force $Run | Out-Null

if ($Target -eq "fpga") {
    Copy-Item "$Root\fpga\mem\*.mem", "$Root\rtl\kws_accel.v", "$Root\fpga\kws_fpga_core.v",
              "$Root\fpga\kws_fpga_top.v", "$Root\fpga\uart.v", "$Root\fpga\kws_uart_link.v",
              "$Root\tb\tb_fpga_top.v" $Run -Force
    $srcs = "kws_accel.v", "kws_fpga_core.v", "kws_fpga_top.v", "uart.v", "kws_uart_link.v", "tb_fpga_top.v"; $top = "tb_fpga_top"
} elseif ($Target -in "int8", "int4") {
    Copy-Item "$Root\weights\$Target\*" $Run -Force
    Copy-Item "$Root\rtl\kws_accel.v", "$Root\rtl\kws_top.v", "$Root\tb\tb_kws.v" $Run -Force
    # pick the chip top (kws_int8 / kws_int4). Not via -d: the .bat splits "A=B" at '='
    Add-Content "$Run\kws_params.vh" ('`define KWS_TOP kws_' + $Target)
    $srcs = "kws_accel.v", "kws_top.v", "tb_kws.v"; $top = "tb_kws"
} else { throw "unknown target '$Target' (use int8, int4 or fpga)" }

Push-Location $Run
try {
    & "$V\xvlog.bat" @srcs -i . | Out-File xvlog.out
    & "$V\xelab.bat" $top -s sim_snap -debug off | Out-File xelab.out
    & "$V\xsim.bat" sim_snap -R | Tee-Object -FilePath sim.log |
        Select-String "mismatches|Accuracy|Cycles|7-segment|correct|TEST|ERROR"
} finally { Pop-Location }
if (Select-String -Path "$Run\sim.log" -Pattern "TEST PASSED" -Quiet) { exit 0 } else { exit 1 }
