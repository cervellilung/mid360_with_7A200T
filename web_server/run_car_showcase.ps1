$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$python = Join-Path (Split-Path $root -Parent) '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw "Python environment missing: $python" }
Push-Location $root
try {
    $url = 'http://127.0.0.1:8766/viewer.html'
    try {
        $running = Invoke-WebRequest -Uri 'http://127.0.0.1:8766/output/manifest.json' -TimeoutSec 2 -ErrorAction Stop
        if ($running.StatusCode -eq 200 -and $running.Content -match 'real M3CP recording') {
            Write-Host "Showcase already running: $url"
            Start-Process $url
            return
        }
    } catch { }
    if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $root -Parent) 'sample\car_showcase\output\manifest.json'))) {
        & $python -m car_showcase.build
        if ($LASTEXITCODE -ne 0) { throw 'Scene cache build failed.' }
    }
    & $python -m car_showcase.serve
} finally {
    Pop-Location
}
