param(
    [Parameter(Mandatory = $true)][string]$LidarIp,
    [string]$BindIp = '0.0.0.0',
    [string]$AdapterName = '以太网',
    [ValidateRange(1, 65535)][int]$UdpPort = 56301,
    [ValidateRange(1, 65535)][int]$HttpPort = 8765
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
if ($adapter.Status -ne 'Up') {
    throw "Network adapter '$AdapterName' is $($adapter.Status)."
}
if (@(Get-NetUDPEndpoint -LocalPort $UdpPort -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "UDP port $UdpPort is occupied. Close Livox Viewer or another radar receiver first."
}
if (@(Get-NetTCPConnection -LocalPort $HttpPort -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "HTTP port $HttpPort is occupied."
}
$python = Join-Path (Split-Path $PSScriptRoot -Parent) '.venv\Scripts\python.exe'
$script = Join-Path $PSScriptRoot 'live_surface_twin.py'
if (-not (Test-Path -LiteralPath $python)) {
    throw "Project Python environment not found: $python"
}
Write-Host "Open http://127.0.0.1:$HttpPort/ in a browser. Press Ctrl+C here to stop."
& $python $script --lidar-ip $LidarIp --bind-ip $BindIp --udp-port $UdpPort --http-port $HttpPort
exit $LASTEXITCODE
