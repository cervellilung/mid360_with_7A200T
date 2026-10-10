param(
    [string]$LidarIp = '192.168.1.20',
    [string]$BindIp = '0.0.0.0',
    [string]$AdapterName = '以太网',
    [ValidateRange(1, 65535)][int]$UdpPort = 56301
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
if ($adapter.Status -ne 'Up') {
    throw "Network adapter '$AdapterName' is $($adapter.Status). Connect and power the MID-360 before capturing."
}
$occupied = @(Get-NetUDPEndpoint -LocalPort $UdpPort -ErrorAction SilentlyContinue)
if ($occupied.Count -gt 0) {
    $owners = @($occupied | ForEach-Object {
        $pidValue = $_.OwningProcess
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($process) { "$($process.ProcessName) (PID $pidValue)" } else { "PID $pidValue" }
    } | Select-Object -Unique)
    throw "UDP port $UdpPort is already in use by $($owners -join ', '). Close that program before capturing."
}

# Captures are stored under the repository sample/radar directory.
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'sample\radar'))
$name = 'mid360_5s_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
$session = [IO.Path]::GetFullPath((Join-Path $workspaceRoot $name))
if (-not $session.StartsWith($workspaceRoot + [IO.Path]::DirectorySeparatorChar,
                            [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Recording path is outside the FPGA workspace.'
}
if (Test-Path -LiteralPath $session) {
    throw "Recording directory already exists: $session"
}

$runner = Join-Path $PSScriptRoot 'run_pc.ps1'
Write-Host "Recording MID-360 for 5 seconds to $session"
$result = & $runner -Mode radar -LidarIp $LidarIp -BindIp $BindIp `
    -UdpPort $UdpPort -Duration 5 -Headless -Record $session
if ($LASTEXITCODE -ne 0) {
    throw "Radar capture failed (exit code $LASTEXITCODE). Output directory: $session"
}
$report = ($result -join [Environment]::NewLine) | ConvertFrom-Json
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $session 'capture_report.json') -Encoding UTF8
$result | Write-Output
if ($report.stats.radar_packets -eq 0 -or $report.stats.scans -eq 0) {
    throw "No usable radar scan was received. Check IP addresses and UDP port. Output directory: $session"
}
Write-Host "Saved: $session"
