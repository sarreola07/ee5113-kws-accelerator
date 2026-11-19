@echo off
REM Windows: fpga\build.bat [nexys4ddr^|nexys4^|nexys_a7_50t] [program]
REM Builds the bitstream (INT8 and INT4 are both on it, SW15 picks one) into
REM results\fpga\kws_fpga_top_<board>.bit. "program" also loads it on the board.
REM Run from any folder. Vivado must be on PATH, or first run
REM C:\Xilinx\Vivado\<version>\settings64.bat
cd /d "%~dp0.."
set BOARD=%1
if "%BOARD%"=="" set BOARD=nexys4ddr
if not exist fpga\work mkdir fpga\work
call vivado -mode batch -nojournal -log fpga\work\vivado_build.log -source fpga\build.tcl -tclargs %BOARD%
if /I "%2"=="program" call fpga\program.bat %BOARD%
