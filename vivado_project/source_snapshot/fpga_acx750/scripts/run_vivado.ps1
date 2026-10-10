#============================================================================
# run_vivado.ps1 -- ACX750 构建/下载 的统一 PowerShell 包装
#
# 用法：
#   ./scripts/run_vivado.ps1 -Step project            # 建工程 + 综合自检
#   ./scripts/run_vivado.ps1 -Step project -NoSynth   # 只建工程/收源/生成 IP
#   ./scripts/run_vivado.ps1 -Step image -Jobs 8      # 综合->实现->出 bit
#   ./scripts/run_vivado.ps1 -Step image -RouteOnly   # 复用综合，重跑实现
#   ./scripts/run_vivado.ps1 -Step jtag               # JTAG 下载 bit
#   ./scripts/run_vivado.ps1 -Step jtag -Bit D:\x\acx750_top.bit
#   ./scripts/run_vivado.ps1 -Step flash              # bit->bin 并烧 QSPI
#
# 行为：调用 vivado.bat -mode batch -source <tcl>，日志 tee 到 build\<step>.log，
#       按判定期标记决定退出码：0=通过  2=门限未过(BIT_SKIPPED/FAILED)  1=脚本异常
#============================================================================
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('project','image','jtag','flash')]
    [string]$Step,

    [string]$Bit = "",
    [int]$Jobs = 10,
    [switch]$NoSynth,
    [switch]$RouteOnly
)

$ErrorActionPreference = 'Stop'

#----------------------------------------------------------------------------
# 路径推导（不硬编码用户目录）
#----------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$BuildDir  = Join-Path $Root 'build'
if (-not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir | Out-Null }

#----------------------------------------------------------------------------
# 定位 vivado.bat：优先 2018.3（IPC 的 IP 由 2018.3 生成）
#----------------------------------------------------------------------------
$VivadoCandidates = @(
    $env:VIVADO_BAT,
    'C:\Xilinx\Vivado\2018.3\bin\vivado.bat',
    'C:\Xilinx\Vivado\2020.2\bin\vivado.bat'
) | Where-Object { $_ -and (Test-Path $_) }

if ($VivadoCandidates.Count -eq 0) {
    $cmd = Get-Command vivado.bat -ErrorAction SilentlyContinue
    if ($cmd) { $Vivado = $cmd.Source } else { throw "找不到 vivado.bat，请设置环境变量 VIVADO_BAT" }
} else {
    $Vivado = $VivadoCandidates[0]
}
Write-Host "INFO: vivado = $Vivado"

#----------------------------------------------------------------------------
# 步骤 -> 脚本 / tclargs 映射
#----------------------------------------------------------------------------
$tclArgs = @()
switch ($Step) {
    'project' {
        $Source = Join-Path $ScriptDir 'build_project.tcl'
        $tclArgs += @('-jobs', "$Jobs")
        if ($NoSynth) { $tclArgs += '-no_synth' }
        $GateMarkers = @('PROJECT_STATUS=OK')
    }
    'image' {
        $Source = Join-Path $ScriptDir 'build_image.tcl'
        $tclArgs += @('-jobs', "$Jobs")
        if ($RouteOnly) { $tclArgs += '-route-only' }
        $GateMarkers = @('BIT_READY=')
    }
    'jtag' {
        $Source = Join-Path $ScriptDir 'jtag_program.tcl'
        if ($Bit -ne "") { $tclArgs += @('-bit', $Bit) }
        $GateMarkers = @('JTAG_STATUS=OK')
    }
    'flash' {
        $Source = Join-Path $ScriptDir 'program_flash.tcl'
        if ($Bit -ne "") { $tclArgs += @('-bit', $Bit) }
        $GateMarkers = @('FLASH_STATUS=OK')
    }
}

$LogFile = Join-Path $BuildDir ("$Step.log")
Write-Host "INFO: source = $Source"
Write-Host "INFO: log    = $LogFile"

#----------------------------------------------------------------------------
# 运行（-mode batch 非交互），日志 tee
#----------------------------------------------------------------------------
$argsList = @('-mode', 'batch', '-source', $Source, '-nojournal', '-nolog')
if ($tclArgs.Count -gt 0) { $argsList += @('-tclargs') + $tclArgs }

& $Vivado @argsList 2>&1 | Tee-Object -FilePath $LogFile
$vivadoExit = $LASTEXITCODE

#----------------------------------------------------------------------------
# 依据判定标记决定退出码
#----------------------------------------------------------------------------
$logText = Get-Content $LogFile -Raw

$passed = $false
foreach ($m in $GateMarkers) {
    if ($logText -match [regex]::Escape($m)) { $passed = $true; break }
}
$skipped = ($logText -match 'BIT_SKIPPED') -or ($logText -match '=FAILED')

if ($passed) {
    Write-Host "RESULT: PASS ($Step)"
    exit 0
} elseif ($skipped) {
    Write-Host "RESULT: GATE-FAILED ($Step) —— 门限未过，详见 $LogFile"
    exit 2
} else {
    Write-Host "RESULT: ERROR ($Step) —— 脚本异常，详见 $LogFile (vivado exit=$vivadoExit)"
    exit 1
}