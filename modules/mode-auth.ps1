# mode-auth.ps1 — Mode 2: Authentication Reset + Account Inspection
# Refactored from Fix-ClaudeAuth v3.1 (same logic, modular structure)
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

# ── Helper: resolve claude executable (prefer .cmd over .ps1 on Windows) ──
function Get-ClaudeExecutable {
    $npmBin = Split-Path (Get-Command claude -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
    if ($npmBin) {
        $cmd = Join-Path $npmBin "claude.cmd"
        if (Test-Path $cmd) { return $cmd }
    }
    $resolved = Get-Command claude -ErrorAction SilentlyContinue
    if ($resolved) { return $resolved.Source }
    return $null
}

# ── Helper: run claude <args> via Start-Process, returns process object ──
function Invoke-ClaudeProcess {
    param([string[]]$ArgumentList, [string]$StdOut, [string]$StdErr)
    $exe = Get-ClaudeExecutable
    if (-not $exe) { throw "claude not found in PATH" }

    if ($exe -match '\.ps1$') {
        # PS1 entry: wrap in powershell.exe so Start-Process can exec it
        return Start-Process -FilePath "powershell.exe" `
            -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $exe) + $ArgumentList) `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $StdOut `
            -RedirectStandardError  $StdErr `
            -ErrorAction Stop
    } else {
        return Start-Process -FilePath $exe `
            -ArgumentList $ArgumentList `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $StdOut `
            -RedirectStandardError  $StdErr `
            -ErrorAction Stop
    }
}

# ══════════════════════════════════════════════════════════════
# ── Show-CurrentAccount: Read-only account reporter ──────────
# ══════════════════════════════════════════════════════════════

function Show-CurrentAccount {
    Write-Section "当前 Claude Code 登录账号" "[只读]"

    $credFile = $CREDENTIALS_FILE
    if (-not (Test-Path $credFile)) {
        Write-Status "WARN" "未找到凭据文件: $credFile"
        Write-Status "INFO" "Claude Code 可能尚未登录，或凭据路径不同"
        Write-Host ""
        Write-Host "  请运行 'claude login' 完成登录后再检查。" -ForegroundColor Yellow
        return
    }

    try {
        $raw = Get-Content $credFile -Raw -Encoding UTF8
        $cred = $raw | ConvertFrom-Json
    } catch {
        Write-Status "ERROR" "凭据文件解析失败: $_"
        return
    }

    # Extract from oauthAccount (Claude Code CLI standard format)
    $acct = $null
    if ($cred.PSObject.Properties["oauthAccount"]) {
        $acct = $cred.oauthAccount
    } elseif ($cred.PSObject.Properties["claudeAiOauth"]) {
        # Older format
        $acct = $cred.claudeAiOauth
    }

    if (-not $acct) {
        Write-Status "WARN" "凭据文件格式不识别，原始内容如下（已遮码敏感字段）:"
        $sanitized = $raw -replace '"accessToken"\s*:\s*"[^"]{6}[^"]*"', '"accessToken": "***REDACTED***"'
        $sanitized = $sanitized -replace '"refreshToken"\s*:\s*"[^"]{6}[^"]*"', '"refreshToken": "***REDACTED***"'
        Write-Host $sanitized
        return
    }

    # Parse expiry
    $expiresAt = $null
    $expiryLabel = "N/A"
    $expiryColor = "Gray"
    if ($acct.PSObject.Properties["expiresAt"]) {
        try {
            $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$acct.expiresAt).LocalDateTime
            $remaining = $expiresAt - [DateTime]::Now
            if ($remaining.TotalMinutes -lt 0) {
                $expiryLabel = "已过期 ($($expiresAt.ToString('yyyy-MM-dd HH:mm')))"
                $expiryColor = "Red"
            } elseif ($remaining.TotalHours -lt 1) {
                $expiryLabel = "即将过期 ($([int]$remaining.TotalMinutes) 分钟后)"
                $expiryColor = "Yellow"
            } else {
                $expiryLabel = "$($expiresAt.ToString('yyyy-MM-dd HH:mm')) (还有 $([int]$remaining.TotalHours) 小时)"
                $expiryColor = "Green"
            }
        } catch { $expiryLabel = "解析失败" }
    }

    # Print table
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │            当前登录账号信息  (只读)                 │" -ForegroundColor Cyan
    Write-Host "  ├─────────────────────────────────────────────────────┤" -ForegroundColor Cyan

    $fields = [ordered]@{
        "Email"           = if ($acct.PSObject.Properties["emailAddress"]) { $acct.emailAddress } else { "N/A" }
        "Account UUID"    = if ($acct.PSObject.Properties["accountUuid"])  { $acct.accountUuid  } else { "N/A" }
        "Org UUID"        = if ($acct.PSObject.Properties["organizationUuid"]) { $acct.organizationUuid } else { "(无组织)" }
        "Org Name"        = if ($acct.PSObject.Properties["organizationName"])  { $acct.organizationName  } else { "(无组织)" }
        "Token 过期"      = $expiryLabel
        "Scopes"          = if ($acct.PSObject.Properties["scopes"]) { ($acct.scopes -join ", ") } else { "N/A" }
    }

    foreach ($kv in $fields.GetEnumerator()) {
        $label = ("  │  " + $kv.Key).PadRight(22)
        $value = $kv.Value
        Write-Host -NoNewline $label -ForegroundColor Cyan
        if ($kv.Key -eq "Token 过期") {
            Write-Host -NoNewline (": " + $value) -ForegroundColor $expiryColor
        } else {
            Write-Host -NoNewline (": " + $value) -ForegroundColor White
        }
        Write-Host ""
    }

    Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    if ($expiresAt -and ([DateTime]::Now -gt $expiresAt)) {
        Write-Status "WARN" "Token 已过期！运行 Mode 7 (认证恢复) 重新登录"
    } else {
        Write-Status "OK" "账号信息读取完成。如需重置登录，使用 Mode 2 (认证重置)"
    }
}

# ══════════════════════════════════════════════════════════════
# ── Hosted-session detection / detached worker helpers ──────
# ══════════════════════════════════════════════════════════════

function Get-HostedVscodeContext {
    $vscodePid = $null
    if ($env:VSCODE_PID -match '^\d+$') {
        $vscodePid = [int]$env:VSCODE_PID
    }

    $chain = @()
    $cur = $PID
    for ($i = 0; $i -lt 8 -and $cur; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        $chain += $proc
        $cur = $proc.ParentProcessId
    }

    $hasCodeAncestor = @($chain | Where-Object { $_.Name -match '^Code(\.exe)?$|^codex\.exe$' }).Count -gt 0
    return [pscustomobject]@{
        IsHostedInVscode = ($hasCodeAncestor -or $null -ne $vscodePid)
        VscodePid = $vscodePid
        Chain = $chain
    }
}

function Start-DetachedAuthReset {
    param($ClashState)

    $toolkitRoot = Split-Path -Parent $PSScriptRoot
    $tmpWorker = Join-Path $env:TEMP ("claude_auth_worker_" + [guid]::NewGuid().ToString() + ".ps1")
    $expectedAccountUuid = $script:ExpectedAccountUuid
    if (-not $expectedAccountUuid) { $expectedAccountUuid = "" }
    $expectedAccountUuid = $expectedAccountUuid -replace "'", "''"

    $expectedEmail = $script:ExpectedEmail
    if (-not $expectedEmail) { $expectedEmail = "" }
    $expectedEmail = $expectedEmail -replace "'", "''"

    $expectedOrgUuid = $script:ExpectedOrgUuid
    if (-not $expectedOrgUuid) { $expectedOrgUuid = "" }
    $expectedOrgUuid = $expectedOrgUuid -replace "'", "''"

    $authBrowserProfile = $script:AuthBrowserProfile
    if (-not $authBrowserProfile) { $authBrowserProfile = "" }
    $authBrowserProfile = $authBrowserProfile -replace "'", "''"
    $workerScript = @"
`$ErrorActionPreference = 'Continue'
`$toolkitRoot = '$toolkitRoot'
`$script:ExpectedAccountUuid = '$expectedAccountUuid'
`$script:ExpectedEmail = '$expectedEmail'
`$script:ExpectedOrgUuid = '$expectedOrgUuid'
`$script:AuthBrowserProfile = '$authBrowserProfile'
`$script:AuthResetStartUtc = [DateTime]::UtcNow
`$script:LastLoginStateChangeUtc = `$null
. (Join-Path `$toolkitRoot 'modules\constants.ps1')
. (Join-Path `$toolkitRoot 'modules\utils.ps1')
. (Join-Path `$toolkitRoot 'modules\clash-helpers.ps1')
. (Join-Path `$toolkitRoot 'modules\mode-auth.ps1')

Write-Host ''
Write-Host 'Claude Auth Worker 已启动。准备在独立窗口中执行认证清理...' -ForegroundColor Cyan
Start-Sleep -Seconds 2

Get-Process -Name @('Code', 'Code - Insiders') -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name @('claude') -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name @('node') -ErrorAction SilentlyContinue | Where-Object { `$_.Path -match 'claude' } | Stop-Process -Force

`$state = Invoke-ClashDirectMode
Invoke-AuthCleanup -ClashState `$state
Invoke-CleanLogin -ClashState `$state
`$identityStatus = Invoke-PostLoginIdentityCheck
Invoke-PostLoginCapabilityCheck
if (`$identityStatus -eq 'account_mismatch') {
    Write-Status 'ERROR' '最终状态: account_mismatch'
}
"@

    $workerScript | Set-Content $tmpWorker -Encoding UTF8
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpWorker`""
    Write-Status "OK" "已启动独立认证修复窗口: $tmpWorker"
    Write-Status "INFO" "当前窗口可关闭；后续关停 VS Code 与清理将在独立窗口中继续"
}

function Show-ExpectedAccountHints {
    $expectation = Test-ClaudeAccountExpectation `
        -ExpectedAccountUuid $script:ExpectedAccountUuid `
        -ExpectedEmail $script:ExpectedEmail `
        -ExpectedOrgUuid $script:ExpectedOrgUuid

    if (-not $expectation.StrictMode) {
        Write-Status "INFO" "未提供 ExpectedAccount 参数，登录后将展示实际账号信息但不做严格阻断"
        return
    }

    Write-Status "INFO" "严格账号校验已启用:"
    foreach ($check in $expectation.Checks) {
        Write-Status "INFO" "  expected $($check.Field): $($check.Expected)"
    }
    if ($script:AuthBrowserProfile) {
        Write-Status "INFO" "AuthBrowserProfile: $($script:AuthBrowserProfile) (当前版本仅记录，不自动驱动浏览器)"
    }
}

function Show-AuthReadinessReport {
    param([object]$Readiness)

    Write-Status "INFO" "登录环境判定: $(Get-AuthReadinessLabel -Readiness $Readiness) / $($Readiness.Status)"
    if ($Readiness.SystemProxy.Enabled -or $Readiness.SystemProxy.Server -or $Readiness.SystemProxy.AutoConfigUrl) {
        if ($Readiness.SystemProxy.Server) {
            Write-Status "WARN" "系统代理仍启用: $($Readiness.SystemProxy.Server)"
        }
        if ($Readiness.SystemProxy.AutoConfigUrl) {
            Write-Status "WARN" "系统 PAC 代理仍启用: $($Readiness.SystemProxy.AutoConfigUrl)"
        }
    } else {
        Write-Status "OK" "系统代理未启用"
    }

    $proxyRows = @($Readiness.ProxyEnvironment | Where-Object { $_.Key -in $PROXY_ENV_VARS })
    if ($proxyRows.Count -gt 0) {
        foreach ($row in $proxyRows) {
            $displayValue = if ($row.Process) { $row.Process } else { $row.User }
            Write-Status "WARN" "代理变量残留: $($row.Key) = $displayValue"
        }
    } else {
        Write-Status "OK" "未检测到代理环境变量"
    }

    foreach ($ep in $Readiness.EndpointResolutions) {
        if ($ep.Success) {
            $tag = if ($ep.HasFakeIp) { " [fake-ip]" } else { "" }
            $level = if ($ep.HasFakeIp) { "WARN" } else { "INFO" }
            Write-Status $level "$($ep.Host) -> $($ep.Addresses -join ', ')$tag"
        } else {
            Write-Status "ERROR" "$($ep.Host) DNS 失败: $($ep.Error)"
        }
    }

    if ($Readiness.ClashDetected) {
        if ($Readiness.ClashApiReachable) {
            Write-Status "INFO" "Clash API 可达，当前模式: $($Readiness.ClashMode)"
        } else {
            Write-Status "WARN" "检测到 Clash/Mihomo 运行，但 API 不可达，无法确认是否已切到 Direct"
            if ($Readiness.Ready) {
                Write-Status "INFO" "当前已降级为软警告：只要 auth 域名是真实解析且无代理残留，允许继续登录"
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-ClashDirectMode: Step 0 — Detect & switch proxy ──
# ══════════════════════════════════════════════════════════════

function Invoke-ClashDirectMode {
    Write-Section "检测 Clash Verge / Mihomo 代理..." "[步骤 0/7]"

    $state = @{
        WasRunning   = $false
        PreviousMode = $null
        ApiCfg       = $null
    }

    $clashProc = Get-Process -Name $PROXY_PROC_NAMES -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $clashProc) {
        Write-Status "OK" "未检测到 Clash Verge / Mihomo 进程"

        # Check proxy env vars
        $activeProxies = @()
        foreach ($pv in $PROXY_ENV_VARS) {
            $val = [System.Environment]::GetEnvironmentVariable($pv, 'User')
            if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process') }
            if ($val) { $activeProxies += "$pv=$val" }
        }
        if ($activeProxies.Count -gt 0) {
            Write-Status "WARN" "检测到代理环境变量 (可能影响 OAuth):"
            $activeProxies | ForEach-Object { Write-Status "INFO" "  $_" }
            Write-Status "INFO" "这些变量将在干净登录窗口中被清除 (步骤 7)"
        }
        return $state
    }

    $state.WasRunning = $true
    Write-Status "WARN" "检测到代理进程: $($clashProc.Name) (PID $($clashProc.Id))"

    $apiCfg = Get-ClashApiConfig
    $state.ApiCfg = $apiCfg

    if ($apiCfg.ConfigFile) {
        Write-Status "INFO" "配置: $($apiCfg.ConfigFile)"
        Write-Status "INFO" "API 端口: $($apiCfg.Port)  Secret: $(if ($apiCfg.Secret) { '***' } else { '(无)' })"
    }

    $currentMode = Get-ClashMode -ApiCfg $apiCfg
    if ($currentMode) {
        $state.PreviousMode = $currentMode
        Write-Status "INFO" "当前 Clash 模式: $currentMode"

        if ($currentMode -ne "direct") {
            Write-Status "ACTION" "切换 Clash Verge 至 Direct 模式..."
            $ok = Set-ClashMode -ApiCfg $apiCfg -Mode "direct"
            if ($ok -and (Wait-ForClashMode -ApiCfg $apiCfg -ExpectedMode "direct")) {
                Write-Status "OK" "已切换至 Direct 模式并完成确认"
            } else {
                Write-Status "ERROR" "自动切换失败或无法确认。请手动切换: Clash Verge → 设置 → 模式 → 直连"
            }
        } else {
            Write-Status "OK" "Clash Verge 已在 Direct 模式"
        }
    } else {
        Write-Status "WARN" "无法连接 Clash API (端口 $($apiCfg.Port))，请手动切换至 Direct 模式"
    }

    return $state
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-AuthCleanup: Steps 1-6 ───────────────────────────
# ══════════════════════════════════════════════════════════════

function Invoke-AuthCleanup {
    param($ClashState)

    # ── Step 1: Kill processes ──
    Write-Section "终止 Claude / VSCode 进程..." "[步骤 1/7]"
    $claudeExe = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeExe) {
        Write-Status "INFO" "执行 claude logout ..."
        try {
            $proc = Invoke-ClaudeProcess -ArgumentList @("logout") `
                -StdOut "$env:TEMP\claude_logout.txt" `
                -StdErr "$env:TEMP\claude_logout_err.txt"
            Write-Status "OK" "claude logout 完成 (exit $($proc.ExitCode))"
        } catch {
            Write-Status "SKIP" "claude logout 跳过: $_"
        }
    } else {
        Write-Status "SKIP" "claude 未在 PATH 中"
    }

    $vscodeNames = @("Code", "Code - Insiders")
    $vsProcs = Get-Process -Name $vscodeNames -ErrorAction SilentlyContinue
    if ($vsProcs) {
        $vsProcs | Stop-Process -Force
        Write-Status "OK" "VSCode 已终止 ($($vsProcs.Count) 个进程)"
    } else {
        Write-Status "OK" "无 VSCode 进程"
    }

    $claudeProcs = Get-Process -Name @("claude","node") -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -match "claude" }
    if ($claudeProcs) {
        $claudeProcs | Stop-Process -Force
        Write-Status "OK" "残留 Claude 进程已终止 ($($claudeProcs.Count))"
    }
    Start-Sleep -Seconds 1

    # ── Step 2: Clear auth files ──
    Write-Section "清除认证文件..." "[步骤 2/7]"
    $anyDeleted = $false
    foreach ($f in $AUTH_FILES) {
        if (Test-Path $f) {
            Backup-Path $f ("auth-" + (Split-Path $f -Leaf)) | Out-Null
            Remove-Item $f -Force
            Write-Status "OK" "已删除: $f"
            $anyDeleted = $true
        }
    }
    if (-not $anyDeleted) {
        Write-Status "OK" "无认证文件需清除"
    }

    # ── Step 3: Clean global settings ──
    Write-Section "清理全局设置文件..." "[步骤 3/7]"
    Clean-SettingsFile "$CLAUDE_HOME\settings.json"       "~/.claude/settings.json"
    Clean-SettingsFile "$CLAUDE_HOME\settings.local.json" "~/.claude/settings.local.json"
    Clean-SettingsFile "$env:APPDATA\Claude\settings.json"       "%APPDATA%/Claude/settings.json"
    Clean-SettingsFile "$env:LOCALAPPDATA\Claude\settings.json"  "%LOCALAPPDATA%/Claude/settings.json"

    # ── Step 3.5: Check VS Code settings ──
    Write-Section "检查 VS Code settings.json..." "[步骤 3.5/7]"
    if (Test-Path $VSCODE_SETTINGS) {
        $vsContent = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8
        $vsFixed = $false

        # Check [1m] suffix
        if ($vsContent -match '"claudeCode\.selectedModel"\s*:\s*"([^"]*\[1m\][^"]*)"') {
            $oldModel = $Matches[1]
            $newModel = $oldModel -replace '\[1m\]', ''
            Write-Status "ERROR" "检测到长上下文模型: $oldModel (导致 429)"
            Write-Status "ACTION" "修复: $oldModel -> $newModel"
            if (-not $vsFixed) { Backup-File $VSCODE_SETTINGS | Out-Null }
            $vsContent = $vsContent -replace """claudeCode\.selectedModel""\s*:\s*""[^""]*\[1m\][^""]*""", """claudeCode.selectedModel"": ""$newModel"""
            $vsFixed = $true
        } else {
            Write-Status "OK" "模型设置正常"
        }

        # Check disableLoginPrompt
        if ($vsContent -match '"claudeCode\.disableLoginPrompt"\s*:\s*true') {
            Write-Status "ERROR" "disableLoginPrompt = true (阻止登录)"
            Write-Status "ACTION" "修复: true -> false"
            if (-not $vsFixed) { Backup-File $VSCODE_SETTINGS | Out-Null }
            $vsContent = $vsContent -replace '"claudeCode\.disableLoginPrompt"\s*:\s*true', '"claudeCode.disableLoginPrompt": false'
            $vsFixed = $true
        } else {
            Write-Status "OK" "disableLoginPrompt 未阻塞"
        }

        if ($vsFixed) {
            $vsContent | Set-Content $VSCODE_SETTINGS -Encoding UTF8
            Write-Status "OK" "VS Code 设置已更新"
        }
    } else {
        Write-Status "SKIP" "VS Code settings.json 未找到"
    }

    # ── Step 3.6: Reset VS Code extension auth/state ──
    Reset-VscodeClaudeState

    # ── Step 4: Project-level settings ──
    Write-Section "检查项目级设置..." "[步骤 4/7]"
    $cwd = Get-Location
    $projectSettings = @(
        (Join-Path $cwd ".claude\settings.json"),
        (Join-Path $cwd ".claude\settings.local.json")
    )
    $found = $false
    foreach ($ps in $projectSettings) {
        if (Test-Path $ps) {
            $content = Get-Content $ps -Raw
            if ($content -match "ANTHROPIC_BASE_URL|openrouter|AUTH_TOKEN|apiBaseUrl") {
                Write-Status "ERROR" "检测到第三方配置: $ps"
                Write-Status "INFO" "请手动移除 ANTHROPIC_BASE_URL"
                $found = $true
            } else {
                Write-Status "OK" "$ps 正常"
            }
        }
    }
    if (-not $found) {
        Write-Status "OK" "无项目级覆盖配置"
    }

    # ── Step 5: Clear env vars ──
    Write-Section "清除用户级环境变量..." "[步骤 5/7]"
    foreach ($v in $BAD_ENV_KEYS) {
        [System.Environment]::SetEnvironmentVariable($v, $null, 'User')
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
    foreach ($v in $PROXY_ENV_VARS) {
        $proxyVal = [System.Environment]::GetEnvironmentVariable($v, 'User')
        if ($proxyVal) {
            Write-Status "WARN" "清除用户代理变量: $v = $proxyVal"
        }
        [System.Environment]::SetEnvironmentVariable($v, $null, 'User')
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
    Write-Status "OK" "用户级环境变量已清除 (含代理变量)"

    # ── Step 6: Verify ──
    Write-Section "验证清理结果..." "[步骤 6/7]"
    $issues = @()
    foreach ($v in $BAD_ENV_KEYS) {
        $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
        if ($val) { $issues += "  ENV $v = $val" }
    }
    foreach ($v in $PROXY_ENV_VARS) {
        $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
        if ($val) { $issues += "  ENV $v = $val" }
    }

    $settingsToCheck = @($SETTINGS_FILE, $SETTINGS_LOCAL)
    $pyCmd = Find-PythonCmd
    foreach ($sf in $settingsToCheck) {
        if (Test-Path $sf) {
            if ($pyCmd) {
                $checkPy = @"
import json, sys
with open(sys.argv[1],'r',encoding='utf-8-sig') as f:
    cfg = json.load(f)
bad = ['ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','apiBaseUrl','authToken']
found = [k for k in bad if k in cfg]
env = cfg.get('env', {})
found += [k for k in bad if k in env]
print(','.join(found) if found else 'OK')
"@
                $tmpCheck = "$env:TEMP\check_claude.py"
                $checkPy | Set-Content $tmpCheck -Encoding UTF8
                $checkResult = & $pyCmd $tmpCheck $sf 2>&1
                Remove-Item $tmpCheck -Force -ErrorAction SilentlyContinue
                if ($checkResult -ne "OK") {
                    $issues += "  FILE $sf 仍含第三方配置: $checkResult"
                }
            } else {
                $raw = Get-Content $sf -Raw
                if ($raw -match '"ANTHROPIC_BASE_URL"\s*:' -or $raw -match '"apiBaseUrl"\s*:') {
                    $issues += "  FILE $sf 仍含第三方配置"
                }
            }
        }
    }

    if ($issues.Count -eq 0) {
        Write-Status "OK" "验证通过 — 无残留第三方配置"
    } else {
        Write-Status "WARN" "仍有问题:"
        $issues | ForEach-Object { Write-Status "ERROR" $_ }
    }
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-CleanLogin: Step 7 — Launch clean login window ────
# ══════════════════════════════════════════════════════════════

function Invoke-CleanLogin {
    param($ClashState)

    Write-Section "准备干净登录环境..." "[步骤 7/7]"
    Show-ExpectedAccountHints

    $claudeLoginExe = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeLoginExe) {
        Write-Status "SKIP" "claude 不在 PATH 中"
        Write-Status "INFO" "安装: npm install -g @anthropic-ai/claude-code"
        return
    }

    $readiness = Get-AuthNetworkReadiness
    Show-AuthReadinessReport -Readiness $readiness
    if (-not $readiness.Ready) {
        Write-Status "ERROR" "当前网络未达到 OAuth 登录前置条件: $($readiness.Status)"
        switch ($readiness.Status) {
            "dns_fake_ip_active" {
                Write-Status "INFO" "请先关闭 Clash TUN / Fake-IP，或确保 anthropic 相关域名不再解析到 198.18.0.0/15"
            }
            "proxy_residual" {
                Write-Status "INFO" "请先关闭系统代理，清理残留代理入口，再重新运行认证重置"
            }
            "network_not_ready" {
                Write-Status "INFO" "请先确保 Clash API 可验证 Direct 模式，或直接停止代理组件后再登录"
            }
        }
        Write-Status "SKIP" "已阻止启动 claude login，避免再次触发 15000ms timeout"
        return
    }

    $allClearVars = $BAD_ENV_KEYS + $PROXY_ENV_VARS
    $clearBlock = ($allClearVars | ForEach-Object { "`$null = Remove-Item 'Env:\$_' -EA 0" }) -join "`n"
    $loginClassification = Get-AuthReadinessLabel -Readiness $readiness
    $browserProfileLine = if ($script:AuthBrowserProfile) {
        "Write-Host `"AuthBrowserProfile: $($script:AuthBrowserProfile) (仅记录，不自动驱动浏览器)`" -ForegroundColor DarkGray"
    } else {
        ""
    }

    $cleanLoginScript = @"
$clearBlock
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  干净登录窗口 ($loginClassification)" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "执行: claude login" -ForegroundColor Yellow
Write-Host "登录前网络判定: $($readiness.Status)" -ForegroundColor White
Write-Host "浏览器将打开，请完成 OAuth 登录流程。" -ForegroundColor White
Write-Host "完成后，请重新打开 VS Code 并在 Claude Code 扩展中再次登录。" -ForegroundColor White
Write-Host "务必在浏览器里选择与 CLI 相同的 Claude 账号/组织。" -ForegroundColor White
$browserProfileLine
Write-Host ""
claude login
Write-Host ""
Write-Host "CLI 登录步骤完成。" -ForegroundColor Green
Write-Host "下一步: 打开 VS Code -> Claude Code 扩展 -> Login，并选择同一账号。" -ForegroundColor Green
Read-Host "按 Enter 退出"
"@

    $tmpLogin = "$env:TEMP\claude_clean_login.ps1"
    $cleanLoginScript | Set-Content $tmpLogin -Encoding UTF8

    Write-Status "INFO" "将打开新的 PowerShell 窗口进行干净登录"

    if (Confirm-Action "立即打开登录窗口?") {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpLogin`""
        Write-Status "OK" "登录窗口已启动 — 请在浏览器中完成 OAuth"
        Write-Status "INFO" "轮询等待 CLI 登录状态变化..."
        $loginResult = Wait-ForClaudeLoginCompletion -TimeoutSeconds 180 -PollIntervalSeconds 5

        if ($loginResult.Success) {
            Write-Status "OK" "检测到 Claude CLI 登录状态已完成"
            $script:LastLoginStateChangeUtc = $loginResult.LastStateChanged
            if ($loginResult.AccountInfo) {
                Write-Status "INFO" "实际账号: $($loginResult.AccountInfo.Email)"
                Write-Status "INFO" "accountUuid: $($loginResult.AccountInfo.AccountUuid)"
                Write-Status "INFO" "organizationUuid: $($loginResult.AccountInfo.OrganizationUuid)"
            }
        } else {
            $script:LastLoginStateChangeUtc = $null
            $postReadiness = Get-AuthNetworkReadiness
            Write-Status "ERROR" "在 180 秒内未检测到有效登录完成"
            Write-Status "ERROR" "状态分类: $($postReadiness.Status)"
            switch ($postReadiness.Status) {
                "dns_fake_ip_active" {
                    Write-Status "INFO" "认证流量仍被 TUN/Fake-IP 接管，这是重启后 timeout 的高概率根因"
                }
                "proxy_residual" {
                    Write-Status "INFO" "仍有代理入口残留，请先统一系统代理 / 环境变量 / Clash 状态"
                }
                default {
                    Write-Status "INFO" "若浏览器已完成授权但 CLI 无变化，请继续运行网络诊断模式定位真实网络问题"
                }
            }
        }

        # Restore Clash mode
        if ($ClashState.WasRunning -and $ClashState.ApiCfg -and
            $ClashState.PreviousMode -and $ClashState.PreviousMode -ne "direct") {
            Write-Host ""
            Write-Status "ACTION" "恢复 Clash Verge 至 '$($ClashState.PreviousMode)' 模式..."
            $restored = Set-ClashMode -ApiCfg $ClashState.ApiCfg -Mode $ClashState.PreviousMode
            if ($restored -and (Wait-ForClashMode -ApiCfg $ClashState.ApiCfg -ExpectedMode $ClashState.PreviousMode)) {
                Write-Status "OK" "Clash Verge 已恢复至 $($ClashState.PreviousMode) 模式"
            } else {
                Write-Status "WARN" "自动恢复失败。请手动恢复 Clash Verge 模式。"
            }
        }
    } else {
        Write-Status "SKIP" "跳过自动登录。手动运行:"
        Write-Status "INFO" "powershell -NoProfile -ExecutionPolicy Bypass -File `"$tmpLogin`""
    }

    # Final guidance
    Write-Host ""
    Write-Host "  验证登录成功:" -ForegroundColor Cyan
    Write-Host "    1. 重新打开 VSCode" -ForegroundColor White
    Write-Host "    2. 在 Claude Code 扩展中重新执行 Login (claudeai)" -ForegroundColor White
    Write-Host "    3. 确认浏览器选择的账号与 CLI 当前账号一致" -ForegroundColor White
    Write-Host "    4. 在 Claude Code 中运行 /status" -ForegroundColor White
    Write-Host "    5. 预期: Login method: Claude Max Account" -ForegroundColor DarkGray
    Write-Host "               无 'organization does not have access' 报错" -ForegroundColor DarkGray
    Write-Host ""
    if ($ClashState.WasRunning) {
        Write-Host "  Clash Verge 后续:" -ForegroundColor Cyan
        Write-Host "    → 确认已恢复至正常代理模式" -ForegroundColor White
        Write-Host "    → 建议添加直连规则: DOMAIN-SUFFIX,anthropic.com,DIRECT" -ForegroundColor DarkGray
        Write-Host "                        DOMAIN-SUFFIX,claude.ai,DIRECT" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  稳定性建议:" -ForegroundColor Cyan
    Write-Host "    → 不要长期保留用户级 HTTP_PROXY/HTTPS_PROXY" -ForegroundColor White
    Write-Host "    → 代理只保留一个配置入口，避免环境变量 / VS Code / 系统代理三头并存" -ForegroundColor White
    Write-Host "    → 清 env proxy 不等于真直连；系统代理和 TUN fake-IP 也会继续截流" -ForegroundColor White
    Write-Host "    → 如仍复现 403，请比对 ~/.claude.json 中的组织信息与浏览器选中的组织是否一致" -ForegroundColor White
}

function Invoke-PostLoginCapabilityCheck {
    Write-Section "验证登录后的实际可用性..." "[附加步骤 B]"

    $probe = Invoke-ClaudeCapabilityProbe
    switch ($probe.Status) {
        "ok" {
            Write-Status "OK" "Claude CLI 实时推理探针通过，登录已真正可用"
        }
        "permission_error_org_access" {
            Write-Status "ERROR" "OAuth 登录成功，但 Claude Code / CLI 推理仍被组织权限拒绝"
            Write-Status "ERROR" "这不是本地登录失败，而是当前账号/组织缺少 Claude Code API 推理权限"
            $bundleDir = Export-ClaudeSupportBundle -ProbeResult $probe
            Write-Status "INFO" "请停止重复网页登录，改为提交支持证据包: $bundleDir"
        }
        "credit_low" {
            Write-Status "ERROR" "OAuth 登录成功，但当前账号余额不足"
            $bundleDir = Export-ClaudeSupportBundle -ProbeResult $probe
            Write-Status "INFO" "支持证据包已导出: $bundleDir"
        }
        "network_error" {
            Write-Status "ERROR" "OAuth 登录成功，但实时请求失败于网络/TLS 问题"
            Write-Status "INFO" "建议继续运行网络诊断模式进一步排查"
        }
        default {
            Write-Status "WARN" "无法确认登录后的实时可用性: $($probe.Detail)"
            $bundleDir = Export-ClaudeSupportBundle -ProbeResult $probe
            Write-Status "INFO" "已导出证据包供进一步排查: $bundleDir"
        }
    }
}

function Invoke-PostLoginIdentityCheck {
    Write-Section "校验登录后的账号身份..." "[附加步骤 A]"

    $stateFile = "$env:USERPROFILE\.claude.json"
    $lastLoginStateChangeUtc = $script:LastLoginStateChangeUtc
    $authResetStartUtc = $script:AuthResetStartUtc
    if (-not $lastLoginStateChangeUtc -and (Test-Path $stateFile)) {
        $stateWriteUtc = (Get-Item $stateFile).LastWriteTimeUtc
        if (-not $authResetStartUtc -or $stateWriteUtc -gt $authResetStartUtc) {
            $lastLoginStateChangeUtc = $stateWriteUtc
        }
    }

    if (-not $lastLoginStateChangeUtc) {
        Write-Status "WARN" "未检测到本轮登录产生新的 ~/.claude.json 写入，跳过账号真相校验"
        return "identity_not_verified"
    }

    $accountInfo = Get-ClaudeAccountInfo
    if (-not $accountInfo) {
        Write-Status "WARN" "未读取到 ~/.claude.json 中的 oauthAccount，无法做账号真相校验"
        return "identity_not_verified"
    }

    Write-Status "INFO" "实际 email: $($accountInfo.Email)"
    Write-Status "INFO" "实际 accountUuid: $($accountInfo.AccountUuid)"
    Write-Status "INFO" "实际 organizationUuid: $($accountInfo.OrganizationUuid)"

    $expectation = Test-ClaudeAccountExpectation `
        -ExpectedAccountUuid $script:ExpectedAccountUuid `
        -ExpectedEmail $script:ExpectedEmail `
        -ExpectedOrgUuid $script:ExpectedOrgUuid `
        -ActualAccount $accountInfo

    if (-not $expectation.StrictMode) {
        Write-Status "OK" "auth_success_verified: 已登录并读取到真实账号信息"
        return "auth_success_verified"
    }

    if ($expectation.Matched) {
        Write-Status "OK" "auth_success_verified: 登录账号与 ExpectedAccount 参数一致"
        return "auth_success_verified"
    }

    Write-Status "ERROR" "account_mismatch: 登录成功，但账号/组织与期望不一致"
    foreach ($check in $expectation.FailedChecks) {
        Write-Status "ERROR" "  $($check.Field): expected=$($check.Expected) actual=$($check.Actual)"
    }
    Write-Status "INFO" "accountUuid 是终极真相；这通常意味着浏览器里误选了另一个账号，而不是目录隔离失效"
    return "account_mismatch"
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-AuthReset: Main entry for Mode 2 ─────────────────
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
# ── Invoke-AuthRelogin: Mode 2L — Lightweight relogin ────────
# ══════════════════════════════════════════════════════════════
# 仅做三步：logout → 弹浏览器 → 验证。不动 settings/env/VS Code 状态。
# 适用场景：账号 token 过期、想切换到同一 configDir 下的另一个账号。
# 对比 Mode 2 (Invoke-AuthReset)：Mode 2 是"重置全家桶"，本模式是"温柔重登"。

function Invoke-AuthRelogin {
    [CmdletBinding()]
    param(
        [switch]$SkipLogout,           # 已手动 logout，跳过 Step 1
        [int]$LoginTimeoutSeconds = 240
    )

    $script:AuthResetStartUtc = [DateTime]::UtcNow
    $script:LastLoginStateChangeUtc = $null

    Write-Section "Claude Auth Relogin (轻量三步)" "[Mode 2L]"
    Show-ExpectedAccountHints

    # ── 守卫：在 VS Code 进程树内运行会被 logout 自杀 ──────────
    $hostCtx = Get-HostedVscodeContext
    if ($hostCtx.IsHostedInVscode) {
        Write-Status "WARN" "当前运行在 VS Code / Codex 进程树内"
        Write-Status "INFO" "请在独立的 PowerShell 窗口中运行 Mode 2L，避免 logout 自杀当前会话"
        Write-Status "INFO" "命令: powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Split-Path -Parent $PSScriptRoot)\Claude-Toolkit.ps1`" -Mode relogin"
        return
    }

    # ── Step 1/3: 手动退出 ──────────────────────────────────────
    Write-Section "退出当前 Claude 登录..." "[步骤 1/3]"

    if ($SkipLogout) {
        Write-Status "SKIP" "用户指定 -SkipLogout，跳过 logout"
    } else {
        $claudeExe = Get-Command claude -ErrorAction SilentlyContinue
        if (-not $claudeExe) {
            Write-Status "ERROR" "claude 不在 PATH，无法 logout"
            Write-Status "INFO" "请先安装: npm install -g @anthropic-ai/claude-code"
            return
        }

        # 备份当前凭据快照（便于回滚）
        Export-AuthBaseline -Reason "relogin-pre-logout" | Out-Null

        try {
            $proc = Invoke-ClaudeProcess -ArgumentList @("logout") `
                -StdOut "$env:TEMP\claude_relogin_logout.txt" `
                -StdErr "$env:TEMP\claude_relogin_logout_err.txt"
            Write-Status "OK" "claude logout 完成 (exit $($proc.ExitCode))"
        } catch {
            Write-Status "ERROR" "claude logout 失败: $_"
            return
        }

        # 显式确认凭据已清（logout 不一定删文件）
        if (Test-Path $CREDENTIALS_FILE) {
            Write-Status "WARN" "logout 后 $CREDENTIALS_FILE 仍存在，主动清除"
            Backup-Path $CREDENTIALS_FILE "relogin-cred-residual" | Out-Null
            Remove-Item $CREDENTIALS_FILE -Force
        } else {
            Write-Status "OK" "凭据文件已清除"
        }

        Write-Status "OK" "Step 1/3 完成 — 凭据已清空，准备弹浏览器登录"
    }

    # ── Step 2/3: 弹浏览器 OAuth 登录 ──────────────────────────
    Write-Section "弹出浏览器进行 OAuth 登录..." "[步骤 2/3]"

    $readiness = Get-AuthNetworkReadiness
    Show-AuthReadinessReport -Readiness $readiness

    if (-not $readiness.Ready) {
        Write-Status "ERROR" "网络环境未就绪 ($($readiness.Status))，登录大概率会 15s timeout — 已中止"
        switch ($readiness.Status) {
            "dns_fake_ip_active" {
                Write-Status "INFO" "Clash TUN/Fake-IP 仍活跃，请先用 Mode 4 修复，再重跑 Mode 2L"
            }
            "proxy_residual" {
                Write-Status "INFO" "代理残留，请先用 Mode 7 清理，再重跑 Mode 2L"
            }
            default {
                Write-Status "INFO" "请先确认网络直连 claude.ai / api.anthropic.com 后再登录"
            }
        }
        return
    }

    # 写临时登录脚本（新 PS 窗口执行，避免当前窗口 TTY 被占用）
    $tmpLogin = "$env:TEMP\claude_relogin_$([guid]::NewGuid().ToString('N')).ps1"
    $loginScript = @'
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  Claude Auth Relogin — 登录窗口" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "浏览器即将打开，请完成 OAuth 登录。" -ForegroundColor Yellow
Write-Host "务必选择与目标账号一致的邮箱与组织。" -ForegroundColor Yellow
Write-Host ""
claude login
Write-Host ""
Write-Host "登录命令已退出，可以关闭此窗口。" -ForegroundColor Green
Read-Host "按 Enter 关闭"
'@
    $loginScript | Set-Content $tmpLogin -Encoding UTF8

    if (-not (Confirm-Action "立即弹出登录窗口?")) {
        Write-Status "SKIP" "用户取消。手动运行:"
        Write-Status "INFO" "powershell -NoProfile -ExecutionPolicy Bypass -File `"$tmpLogin`""
        return
    }

    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmpLogin`""
    Write-Status "OK" "登录窗口已启动，开始轮询 CLI 凭据变化 (超时 ${LoginTimeoutSeconds}s)..."

    $loginResult = Wait-ForClaudeLoginCompletion -TimeoutSeconds $LoginTimeoutSeconds -PollIntervalSeconds 5

    if (-not $loginResult.Success) {
        Write-Status "ERROR" "在 ${LoginTimeoutSeconds}s 内未检测到 CLI 登录完成"
        $postReadiness = Get-AuthNetworkReadiness
        switch ($postReadiness.Status) {
            "dns_fake_ip_active" {
                Write-Status "INFO" "Fake-IP 仍活跃，OAuth callback 被截 — 这是 15s timeout 的高概率根因"
            }
            "proxy_residual" {
                Write-Status "INFO" "代理残留仍在，建议用 Mode 7 彻底清理后重试"
            }
            default {
                Write-Status "INFO" "若浏览器授权已完成但 CLI 无变化，请继续用 Mode 4/7 排查网络"
            }
        }
        return
    }

    $script:LastLoginStateChangeUtc = $loginResult.LastStateChanged
    Write-Status "OK" "CLI 已写入新凭据"
    if ($loginResult.AccountInfo) {
        Write-Status "INFO" "实际 email: $($loginResult.AccountInfo.Email)"
        Write-Status "INFO" "实际 accountUuid: $($loginResult.AccountInfo.AccountUuid)"
        Write-Status "INFO" "实际 organizationUuid: $($loginResult.AccountInfo.OrganizationUuid)"
    }

    Write-Status "OK" "Step 2/3 完成 — 浏览器 OAuth 已完成，CLI 凭据已更新"

    # ── Step 3/3: 登录验证（身份 uuid + 真实能力双校验）──────
    Write-Section "登录后验证..." "[步骤 3/3]"

    $identityStatus = Invoke-PostLoginIdentityCheck   # uuid 比对
    Invoke-PostLoginCapabilityCheck                   # 真实推理 probe

    Write-Host ""
    if ($identityStatus -eq "account_mismatch") {
        Write-Status "ERROR" "Relogin FAILED — account_mismatch（浏览器选错了账号）"
        Write-Status "INFO" "请重新运行 Mode 2L，在浏览器里确认选择正确的邮箱与组织"
    } elseif ($identityStatus -eq "identity_not_verified") {
        Write-Status "WARN" "Relogin partial — 已登录，但未提供 -ExpectedAccountUuid，无法做严格身份比对"
        Write-Status "INFO" "如需严格校验，加参数: -ExpectedAccountUuid <uuid> -ExpectedEmail <email>"
    } else {
        Write-Status "OK" "Step 3/3 完成 — Relogin SUCCESS: 身份 + 能力双校验通过"
    }
}

function Invoke-AuthReset {
    $script:AuthResetStartUtc = [DateTime]::UtcNow
    $script:LastLoginStateChangeUtc = $null
    Export-AuthBaseline -Reason "auth-reset-start" | Out-Null
    $hostCtx = Get-HostedVscodeContext
    if ($hostCtx.IsHostedInVscode) {
        Write-Host ""
        Write-Status "WARN" "检测到当前会话运行在 VS Code / Codex 进程树内"
        Write-Status "ACTION" "切换为独立 PowerShell worker 执行认证修复，避免当前会话被 Stop-Process 直接打断"
        Start-DetachedAuthReset -ClashState $null
        return
    }

    $clashState = Invoke-ClashDirectMode
    Write-Host ""
    Invoke-AuthCleanup -ClashState $clashState
    Write-Host ""
    Invoke-CleanLogin -ClashState $clashState
    Write-Host ""
    $identityStatus = Invoke-PostLoginIdentityCheck
    Write-Host ""
    Invoke-PostLoginCapabilityCheck
    if ($identityStatus -eq "account_mismatch") {
        Write-Status "ERROR" "最终状态: account_mismatch"
    }
}

# ── Auth Recovery (pre-flight + OAuth reset) ─────────────────
# Consolidated from mode-recovery.ps1 (v7.4 → v7.5)

function Disable-SystemProxy {
    $proxyRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $proxyRegPath -Name ProxyEnable -Value 0
    Set-ItemProperty -Path $proxyRegPath -Name ProxyServer -Value ""
    Set-ItemProperty -Path $proxyRegPath -Name AutoConfigURL -Value ""
    Write-Status "OK" "System proxy disabled"
}

function Invoke-AuthRecovery {

    Write-Section "Auth readiness (initial)" "[1/5]"
    $initial = Get-AuthNetworkReadiness
    Show-AuthReadinessReport -Readiness $initial
    Show-ExpectedAccountHints

    Write-Section "System proxy" "[2/5]"
    if ($initial.SystemProxy.Enabled -and $initial.SystemProxy.Server) {
        Write-Status "WARN" "System proxy detected: $($initial.SystemProxy.Server)"
        if ($script:AutoFixEnabled -or (Confirm-Action "Disable system proxy now?" -DefaultYes $true)) {
            Disable-SystemProxy
        } else {
            Write-Status "SKIP" "System proxy kept. Recovery may still be blocked."
        }
    } else {
        Write-Status "OK" "System proxy already disabled"
    }

    Write-Section "AI provider fake-ip filter (dns_config.yaml)" "[3/5]"
    $fakeIpCheck = Test-AnthropicFakeIpFilter
    if ($fakeIpCheck.Pass) {
        Write-Status "OK" "fake-ip-filter: all 7 AI provider entries present (Anthropic + OpenAI)"
        Save-LastGoodDnsConfig | Out-Null
    } else {
        Write-Status "WARN" "Missing: $($fakeIpCheck.Missing -join ', ')"
        if ($script:AutoFixEnabled -or (Confirm-Action "Patch dns_config.yaml and restart Clash Verge now?" -DefaultYes $true)) {
            if (Add-AnthropicFakeIpFilter) {
                Save-LastGoodDnsConfig | Out-Null
                Restart-ClashVerge | Out-Null
                Start-Sleep -Seconds 2
                $reCheck = Test-AnthropicFakeIpFilter
                if ($reCheck.Pass) {
                    Write-Status "OK" "fake-ip-filter updated — all entries now present"
                } else {
                    Write-Status "ERROR" "Patch did not stick: $($reCheck.Reason)"
                }
            } else {
                Write-Status "ERROR" "Add-AnthropicFakeIpFilter failed"
            }
        } else {
            Write-Status "SKIP" "dns_config.yaml not patched. claude login will likely time out."
        }
    }

    Write-Section "Clash mode" "[4/5]"
    $clashState = Invoke-ClashDirectMode
    if ($clashState.WasRunning -and -not $clashState.PreviousMode) {
        Write-Status "WARN" "Proxy detected but Clash mode could not be verified — check TUN status manually"
    }

    Write-Section "Auth readiness (recheck)" "[5/5]"
    $after = Get-AuthNetworkReadiness
    Show-AuthReadinessReport -Readiness $after

    if (-not $after.Ready) {
        Write-Host ""
        Write-Status "ERROR" "Auth still blocked: $($after.Status)"
        switch ($after.Status) {
            "dns_fake_ip_active" {
                Write-Status "INFO" "Next actions:"
                Write-Status "INFO" "  1. Confirm dns_config.yaml was patched and Clash Verge restarted"
                Write-Status "INFO" "  2. nslookup claude.ai — should NOT return 198.18.*"
                Write-Status "INFO" "  3. Run -Mode recovery again"
            }
            "proxy_residual" {
                Write-Status "INFO" "Clear system proxy, env proxy, and extra proxy entries, then retry"
            }
            default {
                Write-Status "INFO" "Run -Mode network for detailed network diagnostics"
            }
        }
        return
    }

    Write-Host ""
    Write-Status "OK" "Auth readiness confirmed — launching OAuth reset"
    Write-Host ""
    Invoke-AuthReset
}
