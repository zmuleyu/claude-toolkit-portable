# update-from-github.ps1 — Update Claude-Toolkit-Portable from GitHub
# Usage:
#   .\scripts\update-from-github.ps1            # Update to latest master
#   .\scripts\update-from-github.ps1 -Tag v7.3  # Pin to specific tag/version
#
# Run from the toolkit root directory, or from any location (auto-detects root).

param(
    [string]$Tag = ""  # Optional: pin to specific tag or commit
)

$ErrorActionPreference = "Stop"

# Detect toolkit root (script is in scripts/ subdirectory)
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolkitRoot = Split-Path -Parent $ScriptDir

# Validate we're in the right place
$constFile = Join-Path $ToolkitRoot "modules\constants.ps1"
if (-not (Test-Path $constFile)) {
    # Maybe user is running from toolkit root directly
    $ToolkitRoot = $ScriptDir
    $constFile   = Join-Path $ToolkitRoot "modules\constants.ps1"
    if (-not (Test-Path $constFile)) {
        Write-Host "[!!] 无法定位 toolkit 根目录。请从 toolkit 目录内运行本脚本。" -ForegroundColor Red
        exit 1
    }
}

# Read current version
function Get-ToolkitVersion {
    param([string]$Root)
    $f = Join-Path $Root "modules\constants.ps1"
    if (-not (Test-Path $f)) { return "unknown" }
    $m = Select-String -Path $f -Pattern '\$SCRIPT_VERSION\s*=\s*"([^"]+)"'
    if ($m.Matches.Count -gt 0) { return $m.Matches[0].Groups[1].Value }
    return "unknown"
}

$oldVersion = Get-ToolkitVersion $ToolkitRoot

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║    Claude-Toolkit Portable — GitHub 自动更新         ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  当前版本: v$oldVersion" -ForegroundColor DarkGray
Write-Host "  工具目录: $ToolkitRoot" -ForegroundColor DarkGray
Write-Host ""

# Check git
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host "  [!!] 未找到 git 命令，无法更新。请先安装 Git for Windows。" -ForegroundColor Red
    exit 1
}

# Check if this is a git repo
Push-Location $ToolkitRoot
try {
    $remoteUrl = git remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $remoteUrl) {
        Write-Host "  [!!] 本目录未配置 git remote origin。" -ForegroundColor Red
        Write-Host "  请先运行 bootstrap-remote.ps1 完成初始化安装，或手动 git remote add origin <url>" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "  [INFO] Remote: $remoteUrl" -ForegroundColor DarkGray

    # Fetch
    Write-Host "  [INFO] 获取最新版本..." -ForegroundColor DarkGray
    git fetch origin 2>&1 | Out-Null

    if ($Tag) {
        # Pin to specific tag/commit
        Write-Host "  [INFO] 切换到: $Tag" -ForegroundColor DarkGray
        git checkout $Tag 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [!!] 切换到 $Tag 失败，请确认 tag 存在: git tag -l" -ForegroundColor Red
            exit 1
        }
    } else {
        # Reset to latest master
        git reset --hard origin/master 2>&1 | Out-Null
    }

    $newVersion = Get-ToolkitVersion $ToolkitRoot

    Write-Host ""
    if ($oldVersion -eq $newVersion) {
        Write-Host "  [OK] 已是最新版本 v$newVersion，无需更新。" -ForegroundColor Green
    } else {
        Write-Host "  [OK] 更新成功: v$oldVersion -> v$newVersion" -ForegroundColor Green
    }

    # Show recent changelog entry if available
    $changelog = Join-Path $ToolkitRoot "CHANGELOG.md"
    if (Test-Path $changelog) {
        Write-Host ""
        Write-Host "  最新变更 (CHANGELOG.md 前 10 行):" -ForegroundColor DarkGray
        Get-Content $changelog | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "  运行工具: .\Claude-Toolkit.ps1" -ForegroundColor Cyan
Write-Host ""
