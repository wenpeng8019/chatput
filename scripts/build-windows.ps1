<#
.SYNOPSIS
  build-windows.ps1 — 构建 Windows 桌面应用并部署到本地程序目录

.DESCRIPTION
  流程：
    1. （可选）清理 target/
    2. cargo build 编译 Debug/Release 单 exe（纯原生，无 .NET）
    3. 将 chatput.exe 拷贝到部署目录（默认 %LOCALAPPDATA%\Programs\Chatput）
    4. （可选）拷贝后直接启动应用

.PARAMETER Release
  Release 构建（默认 Debug）。

.PARAMETER Open
  部署后自动启动应用。

.PARAMETER NoDeploy
  只构建，不拷贝到部署目录。

.PARAMETER Clean
  删除 target/ 后再构建。

.PARAMETER DestDir
  部署目标目录（默认 %LOCALAPPDATA%\Programs\Chatput，也可用环境变量 DEST_DIR）。

.EXAMPLE
  ./scripts/build-windows.ps1                 # Debug 构建并部署
  ./scripts/build-windows.ps1 -Release        # Release 构建
  ./scripts/build-windows.ps1 -Open           # 部署后自动启动
  ./scripts/build-windows.ps1 -NoDeploy       # 只构建，不部署
  ./scripts/build-windows.ps1 -Clean          # 删除 target/ 后再构建
#>

[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Open,
    [switch]$NoDeploy,
    [switch]$Clean,
    [string]$DestDir = $(if ($env:DEST_DIR) { $env:DEST_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\Chatput' })
)

$ErrorActionPreference = 'Stop'

# ---- 路径 ----------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$WindowsDir  = Join-Path $ProjectRoot 'desktop-windows'

# 产物名（bin name = chatput）与运行进程名
$ExeName  = 'chatput.exe'
$ProcName = 'chatput'

# ---- 配置 ----------------------------------------------------------------
$Config = if ($Release) { 'release' } else { 'debug' }

# ---- 确保 cargo/MSVC 在 PATH 中（新开 shell 可能缺失）--------------------
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "✗ 未找到 cargo，请先安装 Rust（https://rustup.rs）"
    exit 1
}

Set-Location $WindowsDir

# ---- 1. 清理 -------------------------------------------------------------
if ($Clean) {
    Write-Host "• 清理 target/…"
    cargo clean
}

# ---- 2. 编译 -------------------------------------------------------------
Write-Host "• cargo build（$Config）…"
if ($Config -eq 'release') {
    cargo build --release
} else {
    cargo build
}
if ($LASTEXITCODE -ne 0) {
    Write-Error "✗ 构建失败（cargo 退出码 $LASTEXITCODE）"
    exit 1
}

$ExePath = Join-Path $WindowsDir "target\$Config\$ExeName"
if (-not (Test-Path $ExePath)) {
    Write-Error "✗ 构建产物未找到：$ExePath"
    exit 1
}
Write-Host "✓ 构建完成：$ExePath"

# ---- 3. 部署 -------------------------------------------------------------
if (-not $NoDeploy) {
    $DestExe = Join-Path $DestDir $ExeName
    Write-Host "• 部署到 $DestExe…"

    # 若应用正在运行，先退出，避免拷贝失败
    $running = Get-Process -Name $ProcName -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "  → 检测到应用正在运行，先退出…"
        $running | Stop-Process -Force
        Start-Sleep -Seconds 1
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    Copy-Item -Path $ExePath -Destination $DestExe -Force
    Write-Host "✓ 已部署到 $DestExe"

    if ($Open) {
        Write-Host "• 启动应用…"
        Start-Process -FilePath $DestExe
    }
} else {
    Write-Host "• 跳过部署（-NoDeploy）"
}

Write-Host "✓ 完成。"
