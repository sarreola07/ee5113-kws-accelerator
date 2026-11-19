@echo off
REM Windows: fpga\build.bat [int8^|int4] [nexys4ddr^|nexys4] [program]
REM Run from the repo folder in a normal Command Prompt (Vivado must be on PATH,
REM or first run: C:\Xilinx\Vivado\<version>\settings64.bat)
cd /d "%~dp0.."
set PREC=%1
if "%PREC%"=="" set PREC=int8
set BOARD=%2
if "%BOARD%"=="" set BOARD=nexys4ddr
if not exist fpga\work mkdir fpga\work
call vivado -mode batch -nojournal -log fpga\work\vivado_build.log -source fpga\build.tcl -tclargs %PREC% %BOARD%
if /I "%3"=="program" call vivado -mode batch -nojournal -log fpga\work\vivado_program.log -source fpga\program.tcl -tclargs %PREC% %BOARD%
