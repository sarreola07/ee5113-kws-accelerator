@echo off
REM Windows: fpga\program.bat [nexys4ddr^|nexys4^|nexys_a7_50t]
REM Loads results\fpga\kws_fpga_top_<board>.bit on the board (USB-PROG port, power on).
cd /d "%~dp0.."
set BOARD=%1
if "%BOARD%"=="" set BOARD=nexys4ddr
if not exist fpga\work mkdir fpga\work
call vivado -mode batch -nojournal -log fpga\work\vivado_program.log -source fpga\program.tcl -tclargs %BOARD%
