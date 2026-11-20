# fpga/monitor.ps1 - shows the text the board sends on its USB-UART (115200 baud).
#   powershell -ExecutionPolicy Bypass -File fpga\monitor.ps1            (finds the Digilent COM port)
#   powershell -ExecutionPolicy Bypass -File fpga\monitor.ps1 -Port COM4
# Press CPU_RESET on the board to see the self-test lines again. Ctrl+C to stop.
param([string]$Port = "", [int]$Seconds = 0)

if ($Port -eq "") {
    # the Digilent USB chip is an FTDI FT2232 (VID 0403, PID 6010); its 2nd channel is the UART
    $dev = Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
           Where-Object { $_.InstanceId -match 'VID_0403\+PID_6010' -and $_.FriendlyName -match '\((COM\d+)\)' } |
           Select-Object -First 1
    if (-not $dev) { Write-Host "No Digilent board COM port found. Is the board plugged in (USB-PROG/UART port)?"; exit 1 }
    $Port = [regex]::Match($dev.FriendlyName, 'COM\d+').Value
}

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Open()
Write-Host "Listening on $Port at 115200 baud (Ctrl+C to stop) ..."
$end = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
try {
    while ((Get-Date) -lt $end) {
        $s = $sp.ReadExisting()
        if ($s) { Write-Host -NoNewline ($s -replace "`r", "") }
        Start-Sleep -Milliseconds 100
    }
} finally { $sp.Close() }
