param(
    [ValidateSet('simulate','replay','live','radar','export-vectors')][string]$Mode = 'simulate',
    [string]$Python = '',
    [string]$Session,
    [double]$Duration = 30,
    [double]$Speed = 1,
    [int]$CameraIndex = -1,
    [string]$LidarIp,
    [string]$BindIp = '0.0.0.0',
    [int]$UdpPort = 56301,
    [string]$SerialPort,
    [int]$Baud = 460800,
    [string]$CameraId = '',
    [string]$MountId = '',
    [string]$Calibration,
    [string]$Config,
    [string]$TimeOffset,
    [string]$Record,
    [switch]$Headless
)
$ErrorActionPreference = 'Stop'
if (-not $Python) {
    $localPython = Join-Path (Split-Path $PSScriptRoot -Parent) '.venv\Scripts\python.exe'
    $Python = if (Test-Path -LiteralPath $localPython) { $localPython } else { 'python' }
}
$env:PYTHONPATH = $PSScriptRoot
$arguments = @('-m', 'pc_perception.cli', $Mode)
if ($Mode -eq 'replay') {
    if (-not $Session) { throw 'Replay needs -Session.' }
    $arguments += $Session
    $arguments += @('--speed', "$Speed")
}
if ($Mode -eq 'simulate' -or $Mode -eq 'radar') { $arguments += @('--duration', "$Duration") }
if ($Mode -eq 'live' -or $Mode -eq 'radar') {
    if (-not $LidarIp -or ($Mode -eq 'live' -and $CameraIndex -lt 0)) { throw 'Live needs -CameraIndex and -LidarIp; radar needs -LidarIp.' }
    $arguments += @('--lidar-ip', $LidarIp, '--bind-ip', $BindIp, '--udp-port', "$UdpPort")
    if ($Mode -eq 'live') { $arguments += @('--camera-index', "$CameraIndex") }
    if ($SerialPort) { $arguments += @('--serial-port', $SerialPort, '--baud', "$Baud") }
}
if ($Mode -eq 'export-vectors') {
    $arguments += @('--out', (Join-Path (Split-Path $PSScriptRoot -Parent) 'sample\reports\fpga_vectors.json'))
} else {
    $arguments += @('--camera-id', $CameraId, '--mount-id', $MountId)
    if ($Calibration) { $arguments += @('--calibration', $Calibration) }
    if ($Config) { $arguments += @('--config', $Config) }
    if ($TimeOffset) { $arguments += @('--time-offset', $TimeOffset) }
    if ($Record) { $arguments += @('--record', $Record) }
    if ($Headless) { $arguments += '--headless' }
}
& $Python @arguments
exit $LASTEXITCODE
