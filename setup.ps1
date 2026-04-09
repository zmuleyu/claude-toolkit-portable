# setup.ps1 — Claude Toolkit First-Run Setup
# Run: powershell -ExecutionPolicy Bypass -File setup.ps1

$ToolkitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load constants for version info
. (Join-Path $ToolkitRoot "modules\constants.ps1")

Write-Host ""
Write-Host "  Claude Toolkit v$SCRIPT_VERSION $SCRIPT_EDITION — First-Run Setup" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Toolkit location: $ToolkitRoot" -ForegroundColor DarkGray
Write-Host ""

# ── 1. PowerShell version ──
$psVer = $PSVersionTable.PSVersion
$psOk = ($psVer.Major -ge 5 -and $psVer.Minor -ge 1) -or ($psVer.Major -ge 6)
if ($psOk) {
    Write-Host "  [OK] PowerShell $psVer" -ForegroundColor Green
} else {
    Write-Host "  [!!] PowerShell $psVer — 需要 5.1 或更高版本" -ForegroundColor Red
}

# ── 2. Python (optional) ──
$pyFound = $false
foreach ($name in @("python", "python3", "py")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
        $pyVer = & $cmd.Source --version 2>&1
        Write-Host "  [OK] $pyVer (增强 JSON 处理)" -ForegroundColor Green
        $pyFound = $true
        break
    }
}
if (-not $pyFound) {
    Write-Host "  [i]  Python 未安装 — 部分功能降级，不影响核心使用" -ForegroundColor Yellow
}

# ── 3. Claude CLI ──
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $claudeVer = & claude --version 2>&1
    Write-Host "  [OK] Claude CLI: $claudeVer" -ForegroundColor Green
} else {
    Write-Host "  [i]  Claude CLI 未安装 — 诊断工具仍可运行" -ForegroundColor Yellow
}

# ── 4. VS Code ──
$codeCmd = Get-Command code -ErrorAction SilentlyContinue
if ($codeCmd) {
    Write-Host "  [OK] VS Code 已安装" -ForegroundColor Green
} else {
    Write-Host "  [i]  VS Code 未检测到" -ForegroundColor DarkGray
}

# ── 4b. Claude Code Desktop ──
$CLAUDE_DESKTOP_PATHS = @(
    "$env:LOCALAPPDATA\Programs\claude-desktop",
    "$env:APPDATA\Claude",
    "$env:LOCALAPPDATA\AnthropicClaude"
)
$desktopFound = $false
foreach ($dp in $CLAUDE_DESKTOP_PATHS) {
    if (Test-Path $dp) {
        Write-Host "  [OK] Claude Code Desktop: $dp" -ForegroundColor Green
        $desktopFound = $true
        break
    }
}
if (-not $desktopFound) {
    Write-Host "  [i]  Claude Code Desktop 未安装" -ForegroundColor DarkGray
}

# ── 5. Clash Verge DNS filter guard ──
$clashConfigDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$dnsConfigFile  = Join-Path $clashConfigDir "dns_config.yaml"
if (Test-Path $dnsConfigFile) {
    Write-Host "  [OK] Clash Verge 配置目录已找到" -ForegroundColor Green

    # Load clash-fake-ip-fix module for detection functions
    $fixModule = Join-Path $ToolkitRoot "modules\clash-fake-ip-fix.ps1"
    if (Test-Path $fixModule) { . $fixModule }

    # Check if filter entries are present
    if (Get-Command -Name Test-AnthropicFakeIpFilter -ErrorAction SilentlyContinue) {
        $filterResult = Test-AnthropicFakeIpFilter
        if ($filterResult.Pass) {
            Write-Host "  [OK] dns_config.yaml fake-ip-filter: 7 条 AI provider 条目已存在" -ForegroundColor Green
        } else {
            Write-Host "  [!!] dns_config.yaml 缺失条目: $($filterResult.Missing -join ', ')" -ForegroundColor Yellow
            $patchResp = Read-Host "  是否立即修补？(Y/n)"
            if ($patchResp -notmatch "^[Nn]") {
                if (Add-AnthropicFakeIpFilter) {
                    Write-Host "  [OK] dns_config.yaml 已修补 — 请重启 Clash Verge 生效" -ForegroundColor Green
                } else {
                    Write-Host "  [!!] 修补失败，请手动运行 Mode 4 (网络诊断)" -ForegroundColor Red
                }
            }
        }
    }

    # Check if ClashDnsFilterCheck guard task is registered
    if (Get-Command -Name Test-DnsFilterGuardRegistered -ErrorAction SilentlyContinue) {
        if (Test-DnsFilterGuardRegistered) {
            Write-Host "  [OK] ClashDnsFilterCheck 定时守护任务已注册" -ForegroundColor Green
        } else {
            Write-Host "  [i]  ClashDnsFilterCheck 定时守护任务未注册" -ForegroundColor Yellow
            $guardResp = Read-Host "  是否注册开机+每日 09:07 自动检测任务？(Y/n)"
            if ($guardResp -notmatch "^[Nn]") {
                $registerScript = Join-Path $ToolkitRoot "Register-DnsFilterCheck.ps1"
                if (Test-Path $registerScript) {
                    try {
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $registerScript
                        Write-Host "  [OK] 守护任务注册成功" -ForegroundColor Green
                    } catch {
                        Write-Host "  [!!] 守护任务注册失败: $_" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  [!!] Register-DnsFilterCheck.ps1 未找到" -ForegroundColor Red
                }
            }
        }
    }
} else {
    Write-Host "  [i]  Clash Verge 未检测到，跳过 DNS filter 检查" -ForegroundColor DarkGray
}

# ── 7. Desktop shortcut ──
Write-Host ""
$shortcutPath = "$env:USERPROFILE\Desktop\Claude Toolkit.lnk"
$createShortcut = $true
if (Test-Path $shortcutPath) {
    Write-Host "  桌面快捷方式已存在: $shortcutPath" -ForegroundColor DarkGray
    $createShortcut = $false
} else {
    $resp = Read-Host "  是否创建桌面快捷方式？(Y/n)"
    if ($resp -match "^[Nn]") { $createShortcut = $false }
}

if ($createShortcut) {
    try {
        & (Join-Path $ToolkitRoot "create-shortcut.ps1")
    } catch {
        Write-Host "  [!!] 快捷方式创建失败: $_" -ForegroundColor Red
    }
}

# ── Summary ──
Write-Host ""
Write-Host "  ────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Setup complete! 使用方式:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    方式 1: 双击 run.bat" -ForegroundColor White
Write-Host "    方式 2: powershell -ExecutionPolicy Bypass -File `"$ToolkitRoot\Claude-Toolkit.ps1`"" -ForegroundColor White
Write-Host "    方式 3: 桌面快捷方式 (如已创建)" -ForegroundColor White
Write-Host ""
Write-Host "    命令行模式: run.bat -Mode health|auth|cache|network|settings|full" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  按 Enter 退出"
