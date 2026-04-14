# bootstrap-remote.ps1 — First-time install of Claude-Toolkit-Portable on a remote machine
# Usage (PowerShell, run as any user):
#   iwr https://raw.githubusercontent.com/zmuleyu/claude-toolkit-portable/master/scripts/bootstrap-remote.ps1 -UseBasicParsing | iex
#
# What it does:
#   1. Checks for Git (required for updates)
#   2. Clones the repo to $env:USERPROFILE\claude-toolkit
#   3. Runs setup.ps1 to validate environment
#   4. Prints next-step instructions

$ErrorActionPreference = "Stop"
$REPO_URL     = "https://github.com/zmuleyu/claude-toolkit-portable.git"
$INSTALL_DIR  = Join-Path $env:USERPROFILE "claude-toolkit"

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║    Claude-Toolkit Portable — 远程自助安装            ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 1. Check Git
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host "  [!!] 未找到 git 命令。" -ForegroundColor Red
    Write-Host "  请先安装 Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    Write-Host "  安装后重新运行本脚本。" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host "  [OK] git 已安装: $($gitCmd.Source)" -ForegroundColor Green

# 2. Clone or update
if (Test-Path $INSTALL_DIR) {
    Write-Host "  [INFO] 目录已存在: $INSTALL_DIR" -ForegroundColor DarkGray
    Write-Host "  [INFO] 执行 git pull 更新..." -ForegroundColor DarkGray
    Push-Location $INSTALL_DIR
    try {
        git fetch origin master 2>&1 | Out-Null
        git reset --hard origin/master 2>&1 | Out-Null
        $ver = (Select-String -Path "modules\constants.ps1" -Pattern '\$SCRIPT_VERSION\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
        Write-Host "  [OK] 更新完成，当前版本: v$ver" -ForegroundColor Green
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  [INFO] 克隆仓库到: $INSTALL_DIR" -ForegroundColor DarkGray
    git clone $REPO_URL $INSTALL_DIR 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [!!] git clone 失败，请检查网络连接" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] 克隆完成" -ForegroundColor Green
}

# 3. Run setup check (non-interactive, just validation)
$setupScript = Join-Path $INSTALL_DIR "setup.ps1"
if (Test-Path $setupScript) {
    Write-Host ""
    Write-Host "  [INFO] 运行环境检查..." -ForegroundColor DarkGray
    try {
        & $setupScript -CheckOnly 2>&1 | Out-Null
    } catch {
        # setup.ps1 may not support -CheckOnly, that's fine
    }
}

# 4. Next steps
Write-Host ""
Write-Host "  ══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  安装完成！下一步操作：" -ForegroundColor Green
Write-Host ""
Write-Host "  1. 查看当前登录账号（只读）：" -ForegroundColor White
Write-Host "     cd `"$INSTALL_DIR`"" -ForegroundColor Yellow
Write-Host "     .\Claude-Toolkit.ps1 -Mode auth -ShowCurrentAccount" -ForegroundColor Yellow
Write-Host ""
Write-Host "  2. 运行完整交互菜单：" -ForegroundColor White
Write-Host "     .\Claude-Toolkit.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. 如登录有问题，运行认证恢复（Mode 7）：" -ForegroundColor White
Write-Host "     .\Claude-Toolkit.ps1 -Mode recovery" -ForegroundColor Yellow
Write-Host ""
Write-Host "  4. 日后更新：" -ForegroundColor White
Write-Host "     .\scripts\update-from-github.ps1" -ForegroundColor Yellow
Write-Host "  ══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
