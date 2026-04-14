# Claude-Toolkit.ps1  v7.3 Portable
# Claude Code Diagnostic & Repair Toolkit for Windows
# Run as: Right-click -> "Run with PowerShell"
# Or: powershell -ExecutionPolicy Bypass -File Claude-Toolkit.ps1 [-Mode health|auth|cache|network|settings|lan|recovery|peer-check|full] [-ExpectedAccountUuid <uuid>] [-ExpectedEmail <email>] [-ExpectedOrgUuid <uuid>] [-ShowCurrentAccount]
#
# Modes:
#   1 (health)      - Read-only health check & diagnostic
#   2 (auth)        - OAuth authentication reset
#   3 (cache)       - Cache and storage cleanup
#   4 (network)     - Network connectivity diagnostics + repair (fake-ip auto-patch)
#   5 (settings)    - Settings reset / restore defaults
#   6 (lan)         - LAN cross-device connectivity diagnostics
#   7 (recovery)    - Guided auth recovery: proxy fix + fake-ip + Clash + OAuth
#   8 (peer-check)  - A<->B cross-machine communication diagnostic
#   0 (full)        - Run health + network (read-only overview)
#
# Special flags:
#   -ShowCurrentAccount  - Print current logged-in account (email/uuid/org), read-only, no changes
#
# Requires: PowerShell 5.1+, Windows 10/11
# Optional: Python 3.x (enables better JSON handling)

param(
    [ValidateSet("menu","health","auth","cache","network","settings","lan","recovery","peer-check","full")]
    [string]$Mode = "menu",
    [switch]$AutoFix,            # Auto-repair discovered issues (network mode)
    [switch]$ShowCurrentAccount, # Read-only: print current logged-in Claude account
    [string]$ExpectedAccountUuid,
    [string]$ExpectedEmail,
    [string]$ExpectedOrgUuid,
    [string]$AuthBrowserProfile
)

# ── Load modules ──────────────────────────────────────────────
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesDir = Join-Path $ScriptRoot "modules"

if (-not (Test-Path $ModulesDir)) {
    Write-Host ""
    Write-Host "  [!!] modules/ 目录未找到: $ModulesDir" -ForegroundColor Red
    Write-Host "       请确保 modules/ 文件夹与本脚本在同一目录下。" -ForegroundColor Red
    Write-Host ""
    Read-Host "按 Enter 退出"
    exit 1
}

$requiredModules = @(
    "constants.ps1",
    "utils.ps1",
    "clash-helpers.ps1",
    "clash-fake-ip-fix.ps1"
)
$optionalModules = @(
    "mode-health.ps1",
    "mode-auth.ps1",
    "mode-cache.ps1",
    "mode-network.ps1",
    "mode-settings.ps1",
    "mode-lan.ps1",
    "mode-recovery.ps1",
    "mode-peer-check.ps1"
)

foreach ($mod in $requiredModules) {
    $modPath = Join-Path $ModulesDir $mod
    if (-not (Test-Path $modPath)) {
        Write-Host "  [!!] 必需模块缺失: $mod" -ForegroundColor Red
        Read-Host "按 Enter 退出"
        exit 1
    }
    . $modPath
}

# Load optional mode modules (missing = placeholder)
$LoadedModes = @{}
foreach ($mod in $optionalModules) {
    $modPath = Join-Path $ModulesDir $mod
    if (Test-Path $modPath) {
        . $modPath
        $LoadedModes[$mod] = $true
    } else {
        $LoadedModes[$mod] = $false
    }
}

# ── Initialize ────────────────────────────────────────────────
$script:PythonExe = $null
$script:AutoFixEnabled = $AutoFix.IsPresent
$script:ExpectedAccountUuid = $ExpectedAccountUuid
$script:ExpectedEmail = $ExpectedEmail
$script:ExpectedOrgUuid = $ExpectedOrgUuid
$script:AuthBrowserProfile = $AuthBrowserProfile
Find-PythonCmd | Out-Null

# Handle -ShowCurrentAccount shortcut (read-only, no menu)
if ($ShowCurrentAccount.IsPresent) {
    Show-Banner
    if ($LoadedModes["mode-auth.ps1"]) {
        Show-CurrentAccount
    } else {
        Write-Host "  [!!] mode-auth.ps1 未加载，无法读取账号信息" -ForegroundColor Red
    }
    exit 0
}

# ── Banner ────────────────────────────────────────────────────
function Show-Banner {
    $claudeVer = Get-ClaudeVersion
    $extVer    = Get-VscodeExtVersion
    $pyStatus  = if ($script:PythonExe) { "可用" } else { "不可用 (部分功能降级)" }

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    $editionTag = if ($SCRIPT_EDITION) { " $SCRIPT_EDITION" } else { "" }
    $titleLine = "Claude Code 诊断与修复工具  v{0}{1}" -f $SCRIPT_VERSION, $editionTag
    Write-Host ("  ║    {0}║" -f $titleLine.PadRight(50)) -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  系统: $([System.Environment]::OSVersion.VersionString)" -ForegroundColor DarkGray
    Write-Host "  PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray
    Write-Host "  Python: $pyStatus" -ForegroundColor DarkGray
    if ($claudeVer) {
        Write-Host "  Claude CLI: $claudeVer" -ForegroundColor DarkGray
    } else {
        Write-Host "  Claude CLI: 未检测到" -ForegroundColor DarkGray
    }
    if ($extVer) {
        Write-Host "  VS Code 扩展: $extVer" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ── Menu ──────────────────────────────────────────────────────
function Show-MainMenu {
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │              请选择功能模式                      │" -ForegroundColor Cyan
    Write-Host "  ├──────────────────────────────────────────────────┤" -ForegroundColor Cyan

    $modes = @(
        @{ Key="1"; Label="健康检查"; Desc="只读诊断，不修改文件";            Mod="mode-health.ps1" },
        @{ Key="2"; Label="认证重置"; Desc="清除OAuth令牌，重新登录";         Mod="mode-auth.ps1" },
        @{ Key="3"; Label="缓存清理"; Desc="释放磁盘空间";                   Mod="mode-cache.ps1" },
        @{ Key="4"; Label="网络诊断"; Desc="DNS/HTTPS/代理/端口一致性";      Mod="mode-network.ps1" },
        @{ Key="5"; Label="设置重置"; Desc="恢复安全默认配置";               Mod="mode-settings.ps1" },
        @{ Key="6"; Label="LAN 诊断"; Desc="跨设备连接排查/防火墙修复";     Mod="mode-lan.ps1" },
        @{ Key="7"; Label="认证恢复"; Desc="代理+fake-ip+Clash+OAuth 全流程"; Mod="mode-recovery.ps1" },
        @{ Key="8"; Label="跨机诊断"; Desc="A<->B 通信检测/端口/根因";       Mod="mode-peer-check.ps1" }
    )

    foreach ($m in $modes) {
        $available = $LoadedModes[$m.Mod]
        $status = if ($available) { "" } else { " [即将推出]" }
        $color  = if ($available) { "White" } else { "DarkGray" }
        Write-Host ("  │  [{0}] {1,-8} {2}{3}" -f $m.Key, $m.Label, $m.Desc, $status).PadRight(52) + "│" -ForegroundColor $color
    }

    Write-Host "  │                                                  │" -ForegroundColor Cyan
    Write-Host "  │  [0] 完整诊断     (按顺序运行 1 + 4)            │" -ForegroundColor White
    Write-Host "  │  [A] 查看账号     (只读，显示当前登录账号)      │" -ForegroundColor Cyan
    Write-Host "  │  [R] 认证恢复     (快捷入口，等同于 7)          │" -ForegroundColor Cyan
    Write-Host "  │  [Q] 退出                                       │" -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

# ── Mode dispatcher ───────────────────────────────────────────
function Invoke-Mode {
    param([string]$ModeName)

    $modeMap = @{
        "health"     = @{ Func = "Invoke-HealthCheck";        Mod = "mode-health.ps1";     Label = "健康检查" }
        "auth"       = @{ Func = "Invoke-AuthReset";          Mod = "mode-auth.ps1";       Label = "认证重置" }
        "cache"      = @{ Func = "Invoke-CacheCleanup";       Mod = "mode-cache.ps1";      Label = "缓存清理" }
        "network"    = @{ Func = "Invoke-NetworkDiagnostics"; Mod = "mode-network.ps1";    Label = "网络诊断" }
        "settings"   = @{ Func = "Invoke-SettingsReset";      Mod = "mode-settings.ps1";   Label = "设置重置" }
        "lan"        = @{ Func = "Invoke-LanDiagnostics";     Mod = "mode-lan.ps1";        Label = "LAN 诊断" }
        "recovery"   = @{ Func = "Invoke-AuthRecovery";       Mod = "mode-recovery.ps1";   Label = "认证恢复" }
        "peer-check" = @{ Func = "Invoke-PeerCheck";          Mod = "mode-peer-check.ps1"; Label = "跨机诊断" }
    }

    $info = $modeMap[$ModeName]
    if (-not $info) {
        Write-Host "  未知模式: $ModeName" -ForegroundColor Red
        return
    }

    if (-not $LoadedModes[$info.Mod]) {
        Write-Host ""
        Write-Host "  [$($info.Label)] 即将推出 — 模块 $($info.Mod) 尚未安装" -ForegroundColor Yellow
        Write-Host "  请将 $($info.Mod) 放入 modules/ 目录后重新运行。" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "  ── $($info.Label) ──────────────────────────────────" -ForegroundColor Cyan
    try {
        & $info.Func
    } catch {
        Write-Host ""
        Write-Status "ERROR" "$($info.Label) 遇到错误: $_"
        Write-Status "INFO" "位置: $($_.ScriptStackTrace)"
    }
    Write-Host ""
    Write-Host "  ── $($info.Label) 完成 ─────────────────────────────" -ForegroundColor Cyan
}

# ── Entry point ───────────────────────────────────────────────
Show-Banner

if ($Mode -ne "menu") {
    # Command-line mode: run directly
    if ($Mode -eq "full") {
        Invoke-Mode "health"
        Invoke-Mode "network"
        Write-Host ""
        Write-Host "  完整诊断结束。如需修复，请使用对应功能模式。" -ForegroundColor Cyan
    } else {
        Invoke-Mode $Mode
    }
} else {
    # Interactive menu loop
    do {
        Show-MainMenu
        $choice = (Read-Host "  请选择功能 [0-8/A/R/Q]").ToLower().Trim()
        $menuMap = @{
            "1" = "health"
            "2" = "auth"
            "3" = "cache"
            "4" = "network"
            "5" = "settings"
            "6" = "lan"
            "7" = "recovery"
            "8" = "peer-check"
            "r" = "recovery"
        }

        if ($choice -eq "a") {
            # Read-only account view
            if ($LoadedModes["mode-auth.ps1"]) {
                Show-CurrentAccount
            } else {
                Write-Host "  [!!] mode-auth.ps1 未加载" -ForegroundColor Red
            }
        } elseif ($menuMap.ContainsKey($choice)) {
            Invoke-Mode $menuMap[$choice]
        } elseif ($choice -eq "0") {
            Invoke-Mode "health"
            Invoke-Mode "network"
            Write-Host ""
            Write-Host "  完整诊断结束。如需修复，请使用对应功能模式。" -ForegroundColor Cyan
        } elseif ($choice -eq "q") {
            # Exit
        } else {
            Write-Host "  无效选项，请重新选择。" -ForegroundColor Red
        }

        if ($choice -ne "q") {
            Write-Host ""
            Read-Host "  按 Enter 返回主菜单"
        }
    } while ($choice -ne "q")
}

Write-Host ""
Write-Host "  再见！" -ForegroundColor Cyan
Write-Host ""
