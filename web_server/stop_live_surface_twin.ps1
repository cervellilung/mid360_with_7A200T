Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pidFile = Join-Path $PSScriptRoot 'reports\live_surface_twin_20260918\server.pid'
if (-not (Test-Path -LiteralPath $pidFile)) {
    throw "Live viewer PID file not found: $pidFile"
}
$targetPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
$process = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
if (-not $process) {
    Write-Host "Live viewer process $targetPid is already stopped."
    exit 0
}
if ($process.Name -notlike 'python*' -or $process.CommandLine -notlike '*live_surface_twin.py*') {
    throw "PID $targetPid no longer belongs to the live viewer. Not stopping it."
}
Stop-Process -Id $targetPid
Write-Host "Stopped live viewer PID $targetPid."
