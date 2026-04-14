# utils.ps1 — Shared utility functions
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

# ══════════════════════════════════════════════════════════════
# ── Write-Status: Standardized color-coded output ────────────
# ══════════════════════════════════════════════════════════════

function Write-Status {
    param(
        [ValidateSet("OK","WARN","ERROR","INFO","SKIP","ACTION")]
        [string]$Level,
        [string]$Message,
        [int]$Indent = 6
    )
    $prefix = " " * $Indent
    switch ($Level) {
        "OK"     { Write-Host "$prefix[OK] $Message" -ForegroundColor Green }
        "WARN"   { Write-Host "$prefix[!]  $Message" -ForegroundColor Yellow }
        "ERROR"  { Write-Host "$prefix[!!] $Message" -ForegroundColor Red }
        "INFO"   { Write-Host "$prefix[i]  $Message" -ForegroundColor DarkGray }
        "SKIP"   { Write-Host "$prefix[--] $Message" -ForegroundColor DarkGray }
        "ACTION" { Write-Host "$prefix[=>] $Message" -ForegroundColor Cyan }
    }
}

# ══════════════════════════════════════════════════════════════
# ── Write-Section: Section header ────────────────────────────
# ══════════════════════════════════════════════════════════════

function Write-Section {
    param([string]$Title, [string]$StepLabel = "")
    Write-Host ""
    if ($StepLabel) {
        Write-Host "  $StepLabel $Title" -ForegroundColor Yellow
    } else {
        Write-Host "  $Title" -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════════════════════
# ── Find-PythonCmd: Cached Python detection ──────────────────
# ══════════════════════════════════════════════════════════════

function Find-PythonCmd {
    if ($script:PythonExe) { return $script:PythonExe }
    foreach ($name in @("python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $script:PythonExe = $cmd.Source
            return $script:PythonExe
        }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════
# ── Get-DirSize: Directory size in bytes + human-readable ────
# ══════════════════════════════════════════════════════════════

function Get-DirSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @{ Bytes = 0; Display = "0 B"; FileCount = 0 }
    }
    try {
        $items = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
        $totalBytes = ($items | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if (-not $totalBytes) { $totalBytes = 0 }
        $fileCount = @($items).Count

        $display = if ($totalBytes -ge 1GB) { "{0:N2} GB" -f ($totalBytes / 1GB) }
                   elseif ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                   elseif ($totalBytes -ge 1KB) { "{0:N0} KB" -f ($totalBytes / 1KB) }
                   else { "$totalBytes B" }
        return @{ Bytes = [long]$totalBytes; Display = $display; FileCount = $fileCount }
    } catch {
        return @{ Bytes = 0; Display = "Error"; FileCount = 0 }
    }
}

# ══════════════════════════════════════════════════════════════
# ── Confirm-Action: Chinese confirmation prompt ──────────────
# ══════════════════════════════════════════════════════════════

function Confirm-Action {
    param(
        [string]$Message,
        [bool]$DefaultYes = $true
    )
    $suffix = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }
    $resp = Read-Host "      $Message $suffix"
    if ($resp -eq "") { return $DefaultYes }
    return ($resp -match "^[Yy]")
}

# ══════════════════════════════════════════════════════════════
# ── Backup-File: Timestamped backup before modification ──────
# ══════════════════════════════════════════════════════════════

function Backup-File {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backupRoot = Join-Path $BACKUP_DIR $timestamp
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    $drive = [System.IO.Path]::GetPathRoot($FilePath)
    $relativeName = $FilePath.Substring($drive.Length).TrimStart('\')
    if (-not $relativeName) { $relativeName = Split-Path $FilePath -Leaf }
    $safeRelativeName = ($relativeName -replace '[\\/:*?"<>|]', '_')
    $backupPath = Join-Path $backupRoot $safeRelativeName
    Copy-Item $FilePath $backupPath -Force
    Write-Status "INFO" "备份: $backupPath"
    return $backupPath
}

# ══════════════════════════════════════════════════════════════
# ── Backup-Path: Backup file or directory into timestamp root ─
# ══════════════════════════════════════════════════════════════

function Backup-Path {
    param(
        [string]$Path,
        [string]$Label = $null
    )
    if (-not (Test-Path $Path)) { return $null }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backupRoot = Join-Path $BACKUP_DIR $timestamp
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    if ($Label) {
        $leaf = $Label
    } else {
        $root = [System.IO.Path]::GetPathRoot($Path)
        $leaf = $Path.Substring($root.Length).TrimStart('\')
        if (-not $leaf) { $leaf = Split-Path $Path -Leaf }
    }
    $safeLeaf = ($leaf -replace '[\\/:*?"<>|]', '_')
    $backupPath = Join-Path $backupRoot $safeLeaf

    if ((Get-Item $Path).PSIsContainer) {
        Copy-Item $Path $backupPath -Recurse -Force
    } else {
        Copy-Item $Path $backupPath -Force
    }

    Write-Status "INFO" "备份: $backupPath"
    return $backupPath
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-PythonSnippet: Run a short Python helper safely ───
# ══════════════════════════════════════════════════════════════

function Invoke-PythonSnippet {
    param(
        [string]$Script,
        [string[]]$Arguments = @()
    )
    $pyCmd = Find-PythonCmd
    if (-not $pyCmd) {
        return @{ Success = $false; Output = @("Python not found") }
    }

    $tmpPy = Join-Path $env:TEMP ("claude_toolkit_" + [guid]::NewGuid().ToString() + ".py")
    try {
        $Script | Set-Content $tmpPy -Encoding UTF8
        $output = & $pyCmd $tmpPy @Arguments 2>&1
        return @{ Success = ($LASTEXITCODE -eq 0); Output = @($output) }
    } finally {
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
    }
}

# ══════════════════════════════════════════════════════════════
# ── Read-JsonSafe: JSON reader with Python fallback ──────────
# ══════════════════════════════════════════════════════════════

function Read-JsonSafe {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }

    $pyCmd = Find-PythonCmd
    if ($pyCmd) {
        try {
            $pyScript = @"
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8-sig') as f:
    print(json.dumps(json.load(f), ensure_ascii=False))
"@
            $tmpPy = "$env:TEMP\claude_read_json.py"
            $pyScript | Set-Content $tmpPy -Encoding UTF8
            $result = & $pyCmd $tmpPy $FilePath 2>&1
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -eq 0 -and $result) {
                return ($result | ConvertFrom-Json)
            }
        } catch { }
    }

    # Fallback: PowerShell ConvertFrom-Json
    try {
        $content = Get-Content $FilePath -Raw -Encoding UTF8
        return ($content | ConvertFrom-Json)
    } catch {
        Write-Status "WARN" "无法解析 JSON: $FilePath"
        return $null
    }
}

# ══════════════════════════════════════════════════════════════
# ── Write-JsonSafe: JSON writer with backup + Python ─────────
# ══════════════════════════════════════════════════════════════

function Write-JsonSafe {
    param(
        [string]$FilePath,
        [string]$JsonContent,
        [switch]$NoBackup
    )
    if (-not $NoBackup -and (Test-Path $FilePath)) {
        Backup-File $FilePath | Out-Null
    }

    $pyCmd = Find-PythonCmd
    if ($pyCmd) {
        try {
            $pyScript = @"
import json, sys
data = json.loads(sys.argv[2])
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('OK')
"@
            $tmpPy = "$env:TEMP\claude_write_json.py"
            $pyScript | Set-Content $tmpPy -Encoding UTF8
            $result = & $pyCmd $tmpPy $FilePath $JsonContent 2>&1
            Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch { }
    }

    # Fallback: direct write
    try {
        $JsonContent | Set-Content $FilePath -Encoding UTF8
        return $true
    } catch {
        Write-Status "ERROR" "写入失败: $FilePath — $_"
        return $false
    }
}

# ══════════════════════════════════════════════════════════════
# ── Test-ProcessRunning: Check if a PID is alive ─────────────
# ══════════════════════════════════════════════════════════════

function Test-ProcessRunning {
    param([int]$ProcessId)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    return ($null -ne $proc)
}

# ══════════════════════════════════════════════════════════════
# ── Get-ClaudeVersion: Detect claude CLI version ─────────────
# ══════════════════════════════════════════════════════════════

function Get-ClaudeVersion {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $output = & claude --version 2>&1
        if ($output -match "(\d+\.\d+\.\d+)") {
            return $Matches[1]
        }
        return $output.Trim()
    } catch {
        return $null
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-VscodeExtVersion: Detect VS Code extension version ───
# ══════════════════════════════════════════════════════════════

function Get-VscodeExtVersion {
    if (-not (Test-Path $VSCODE_EXT_DIR)) { return $null }
    $extDirs = Get-ChildItem $VSCODE_EXT_DIR -Directory -Filter "anthropic.claude-code-*" -ErrorAction SilentlyContinue
    if (-not $extDirs) { return $null }
    $latest = $extDirs |
        Sort-Object `
            @{ Expression = {
                    if ($_.Name -match "anthropic\.claude-code-(\d+)\.(\d+)\.(\d+)") {
                        [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
                    } else {
                        [version]"0.0.0"
                    }
                }; Descending = $true },
            @{ Expression = { $_.Name }; Descending = $true } |
        Select-Object -First 1
    if ($latest.Name -match "anthropic\.claude-code-(\d+\.\d+\.\d+)") {
        return $Matches[1]
    }
    return $latest.Name
}

# ══════════════════════════════════════════════════════════════
# ── Get-ClaudeAuthStatusInfo: Read `claude auth status` JSON ─
# ══════════════════════════════════════════════════════════════

function Get-ClaudeAuthStatusInfo {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $raw = & $cmd.Source auth status 2>$null
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-ProxyEnvironmentSnapshot {
    $rows = @()
    foreach ($pv in $PROXY_ENV_VARS + @('NO_PROXY', 'no_proxy')) {
        $userVal = [System.Environment]::GetEnvironmentVariable($pv, 'User')
        $procVal = [System.Environment]::GetEnvironmentVariable($pv, 'Process')
        if ($userVal -or $procVal) {
            $rows += [pscustomobject]@{
                Key = $pv
                User = $userVal
                Process = $procVal
            }
        }
    }
    return $rows
}

function Get-SystemProxySnapshot {
    $proxyReg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    $enabled = $false
    $server = $null
    $autoConfigUrl = $null
    if ($proxyReg) {
        $enabled = [bool]$proxyReg.ProxyEnable
        $server = $proxyReg.ProxyServer
        $autoConfigUrl = $proxyReg.AutoConfigURL
    }
    return [pscustomobject]@{
        Enabled = $enabled
        Server = $server
        AutoConfigUrl = $autoConfigUrl
    }
}

function Resolve-EndpointAddresses {
    param([string]$EndpointHost)

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($EndpointHost) |
            ForEach-Object { $_.IPAddressToString } |
            Select-Object -Unique
        [pscustomobject]@{
            Host = $EndpointHost
            Success = ($addresses.Count -gt 0)
            Addresses = @($addresses)
            HasFakeIp = (@($addresses | Where-Object { $_ -match $FAKE_IP_REGEX }).Count -gt 0)
            Error = $null
        }
    } catch {
        [pscustomobject]@{
            Host = $EndpointHost
            Success = $false
            Addresses = @()
            HasFakeIp = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-AuthNetworkReadiness {
    $systemProxy = Get-SystemProxySnapshot
    $proxyEnv = Get-ProxyEnvironmentSnapshot
    $endpointResolutions = @()
    foreach ($ep in $AUTH_REQUIRED_ENDPOINTS) {
        $endpointResolutions += Resolve-EndpointAddresses -EndpointHost $ep.Host
    }

    $proxyEnvRows = @($proxyEnv | Where-Object { $_.Key -in $PROXY_ENV_VARS })
    $fakeIpEndpoints = @($endpointResolutions | Where-Object { $_.HasFakeIp })
    $dnsFailures = @($endpointResolutions | Where-Object { -not $_.Success })

    $clashProc = Get-Process -Name $PROXY_PROC_NAMES -ErrorAction SilentlyContinue | Select-Object -First 1
    $clashDetected = ($null -ne $clashProc)
    $clashApiReachable = $false
    $clashMode = $null
    $clashApiCfg = $null
    $proxyVerificationIncomplete = $false
    if ($clashDetected) {
        $clashApiCfg = Get-ClashApiConfig
        $clashMode = Get-ClashMode -ApiCfg $clashApiCfg
        $clashApiReachable = ($null -ne $clashMode)
        $proxyVerificationIncomplete = (-not $clashApiReachable)
    }

    $status = "auth_ready"
    $reason = "ready for manual OAuth login"
    $ready = $true

    if ($fakeIpEndpoints.Count -gt 0) {
        $status = "dns_fake_ip_active"
        $reason = "Auth domains still resolve to Clash/TUN fake-IP addresses"
        $ready = $false
    } elseif ($systemProxy.Enabled -or $systemProxy.Server -or $systemProxy.AutoConfigUrl) {
        $status = "proxy_residual"
        if ($systemProxy.AutoConfigUrl) {
            $reason = "System PAC proxy is still enabled"
        } else {
            $reason = "System proxy is still enabled"
        }
        $ready = $false
    } elseif ($proxyEnvRows.Count -gt 0) {
        $status = "proxy_residual"
        $reason = "Proxy environment variables are still present"
        $ready = $false
    } elseif ($dnsFailures.Count -gt 0) {
        $status = "network_not_ready"
        $reason = "Required auth domains failed DNS resolution"
        $ready = $false
    } elseif ($clashDetected -and -not $clashApiReachable) {
        $status = "auth_ready"
        $reason = "Clash API is unreachable, but auth domains resolve to real addresses and no proxy residue is active"
        $ready = $true
    }

    [pscustomobject]@{
        Ready = $ready
        Status = $status
        Reason = $reason
        SystemProxy = $systemProxy
        ProxyEnvironment = @($proxyEnv)
        EndpointResolutions = @($endpointResolutions)
        FakeIpEndpoints = @($fakeIpEndpoints)
        DnsFailures = @($dnsFailures)
        ClashDetected = $clashDetected
        ClashMode = $clashMode
        ClashApiReachable = $clashApiReachable
        ClashApiCfg = $clashApiCfg
        ProxyVerificationIncomplete = $proxyVerificationIncomplete
    }
}

function Get-AuthReadinessLabel {
    param([object]$Readiness)

    switch ($Readiness.Status) {
        "auth_ready"         { return "真直连" }
        "proxy_residual"     { return "代理残留，禁止继续" }
        "dns_fake_ip_active" { return "代理残留，禁止继续" }
        default              { return "仅清环境变量" }
    }
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-ClaudeCapabilityProbe: Real inference availability ─
# ══════════════════════════════════════════════════════════════

function Invoke-ClaudeCapabilityProbe {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return [pscustomobject]@{
            Status = "cli_missing"
            Detail = "Claude CLI not found"
            ExitCode = $null
            RawOutput = ""
        }
    }

    try {
        $output = & $cmd.Source -p "Reply with OK only." --output-format text --permission-mode bypassPermissions 2>&1
        $joined = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
        $exitCode = $LASTEXITCODE
    } catch {
        $joined = "$_"
        $exitCode = 1
    }

    $status = "unknown_error"
    $detail = $joined

    if ($exitCode -eq 0 -and $joined -match '^\s*OK\s*$') {
        $status = "ok"
        $detail = "Inference request succeeded"
    } elseif ($joined -match 'organization does not have access to Claude' -or
              $joined -match 'OAuth authentication is currently not allowed for this organization') {
        $status = "permission_error_org_access"
        $detail = "Organization lacks Claude Code/API inference access"
    } elseif ($joined -match 'Credit balance is too low') {
        $status = "credit_low"
        $detail = "Credit balance is too low"
    } elseif ($joined -match 'ECONN|ENOTFOUND|network|timeout|timed out|certificate|TLS') {
        $status = "network_error"
        $detail = "Network/TLS error during inference request"
    }

    return [pscustomobject]@{
        Status = $status
        Detail = $detail
        ExitCode = $exitCode
        RawOutput = $joined
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-ClaudeAccountInfo: Read local non-secret account info ─
# ══════════════════════════════════════════════════════════════

function Get-ClaudeAccountInfo {
    $stateFile = "$env:USERPROFILE\.claude.json"
    if (-not (Test-Path $stateFile)) { return $null }

    $state = Read-JsonSafe $stateFile
    if (-not $state -or -not $state.oauthAccount) { return $null }

    $acct = $state.oauthAccount
    return [pscustomobject]@{
        AccountUuid = $acct.accountUuid
        Email = $acct.emailAddress
        DisplayName = $acct.displayName
        OrganizationName = $acct.organizationName
        OrganizationUuid = $acct.organizationUuid
        OrganizationRole = $acct.organizationRole
        BillingType = $acct.billingType
        WorkspaceRole = $acct.workspaceRole
        StateFileLastWriteTime = (Get-Item $stateFile).LastWriteTime
    }
}

function Test-ClaudeAccountExpectation {
    param(
        [string]$ExpectedAccountUuid,
        [string]$ExpectedEmail,
        [string]$ExpectedOrgUuid,
        [object]$ActualAccount = $null
    )

    if (-not $ActualAccount) { $ActualAccount = Get-ClaudeAccountInfo }

    $checks = @()
    if ($ExpectedAccountUuid) {
        $checks += [pscustomobject]@{
            Field = "accountUuid"
            Expected = $ExpectedAccountUuid
            Actual = if ($ActualAccount) { $ActualAccount.AccountUuid } else { $null }
            Match = ($ActualAccount -and $ActualAccount.AccountUuid -eq $ExpectedAccountUuid)
        }
    }
    if ($ExpectedEmail) {
        $checks += [pscustomobject]@{
            Field = "email"
            Expected = $ExpectedEmail
            Actual = if ($ActualAccount) { $ActualAccount.Email } else { $null }
            Match = ($ActualAccount -and $ActualAccount.Email -eq $ExpectedEmail)
        }
    }
    if ($ExpectedOrgUuid) {
        $checks += [pscustomobject]@{
            Field = "organizationUuid"
            Expected = $ExpectedOrgUuid
            Actual = if ($ActualAccount) { $ActualAccount.OrganizationUuid } else { $null }
            Match = ($ActualAccount -and $ActualAccount.OrganizationUuid -eq $ExpectedOrgUuid)
        }
    }

    $strictMode = ($checks.Count -gt 0)
    $allMatched = ($strictMode -and @($checks | Where-Object { -not $_.Match }).Count -eq 0)

    return [pscustomobject]@{
        StrictMode = $strictMode
        ActualAccount = $ActualAccount
        Checks = @($checks)
        Matched = $allMatched
        FailedChecks = @($checks | Where-Object { -not $_.Match })
    }
}

function Wait-ForClaudeLoginCompletion {
    param(
        [int]$TimeoutSeconds = 180,
        [int]$PollIntervalSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastAccountWrite = $null
    $stateFile = "$env:USERPROFILE\.claude.json"
    if (Test-Path $stateFile) {
        $lastAccountWrite = (Get-Item $stateFile).LastWriteTimeUtc
    }

    do {
        $authInfo = Get-ClaudeAuthStatusInfo
        $accountInfo = Get-ClaudeAccountInfo
        $stateChanged = $false
        if (Test-Path $stateFile) {
            $currentWrite = (Get-Item $stateFile).LastWriteTimeUtc
            if (-not $lastAccountWrite -or $currentWrite -gt $lastAccountWrite) {
                $lastAccountWrite = $currentWrite
                $stateChanged = $true
            }
        }

        if ($authInfo -and $authInfo.loggedIn -and $accountInfo) {
            return [pscustomobject]@{
                Success = $true
                TimedOut = $false
                AuthInfo = $authInfo
                AccountInfo = $accountInfo
                LastStateChanged = $lastAccountWrite
            }
        }

        if ($stateChanged -and $accountInfo) {
            return [pscustomobject]@{
                Success = $true
                TimedOut = $false
                AuthInfo = $authInfo
                AccountInfo = $accountInfo
                LastStateChanged = $lastAccountWrite
            }
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)

    [pscustomobject]@{
        Success = $false
        TimedOut = $true
        AuthInfo = Get-ClaudeAuthStatusInfo
        AccountInfo = Get-ClaudeAccountInfo
        LastStateChanged = $lastAccountWrite
    }
}

# ══════════════════════════════════════════════════════════════
# ── Clean-SettingsFile: JSON-aware settings cleaner (from v3.1)
# ══════════════════════════════════════════════════════════════

function Clean-SettingsFile {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        Write-Status "SKIP" "$Label 未找到"
        return
    }

    Write-Status "INFO" "处理 $Label ..."
    Backup-File $FilePath | Out-Null

    $cleaned = $false
    $pyCmd = Find-PythonCmd

    # -- Method A: Python (most reliable) --
    if ($pyCmd) {
        $pyScript = @"
import json, sys
path   = sys.argv[1]
keys   = sys.argv[2].split(',')
with open(path, 'r', encoding='utf-8-sig') as f:
    cfg = json.load(f)
for k in keys:
    cfg.pop(k, None)
if isinstance(cfg.get('env'), dict):
    for k in keys:
        cfg['env'].pop(k, None)
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print('OK')
"@
        $tmpPy   = "$env:TEMP\fix_claude.py"
        $keyList = $BAD_SETTINGS_KEYS -join ","
        $pyScript | Set-Content $tmpPy -Encoding UTF8
        $result  = & $pyCmd $tmpPy $FilePath $keyList 2>&1
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -eq 0) {
            Write-Status "OK" "$Label 已清理 (Python)"
            $cleaned = $true
        } else {
            Write-Status "WARN" "Python 清理失败: $result"
        }
    }

    # -- Method B: Regex fallback --
    if (-not $cleaned) {
        try {
            $content = Get-Content $FilePath -Raw -Encoding UTF8
            foreach ($k in $BAD_SETTINGS_KEYS) {
                $content = $content -replace ",?\s*`"$k`"\s*:\s*`"[^`"]*`"", ""
                $content = $content -replace ",?\s*`"$k`"\s*:\s*''", ""
                $content = $content -replace ",?\s*`"$k`"\s*:\s*null", ""
            }
            $content = $content -replace ",(\s*[}\]])", '$1'
            $content | Set-Content $FilePath -Encoding UTF8
            Write-Status "OK" "$Label 已清理 (Regex)"
            $cleaned = $true
        } catch {
            Write-Status "WARN" "Regex 清理失败: $_"
        }
    }

    # -- Method C: Full reset --
    if (-not $cleaned) {
        '{ "env": {} }' | Set-Content $FilePath -Encoding UTF8
        Write-Status "WARN" "$Label 已重置为空 (备份已保存)"
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-VscodeClaudeState: Inspect VS Code extension state ───
# ══════════════════════════════════════════════════════════════

function Get-VscodeClaudeState {
    if (-not (Test-Path $VSCODE_STATE_DB)) { return $null }

    $script = @"
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
cur = con.cursor()
row = cur.execute("select value from ItemTable where key = 'Anthropic.claude-code'").fetchone()
if row is None:
    print("")
else:
    value = row[0]
    if isinstance(value, bytes):
        print(value.decode('utf-8', 'ignore'))
    else:
        print(value)
"@
    $result = Invoke-PythonSnippet -Script $script -Arguments @($VSCODE_STATE_DB)
    if (-not $result.Success) { return $null }
    $joined = ($result.Output -join "`n").Trim()
    if (-not $joined) { return $null }
    try {
        return ($joined | ConvertFrom-Json)
    } catch {
        return $joined
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-VscodeClaudeLogStatus: Current vs historical log error ─
# ══════════════════════════════════════════════════════════════

function Get-VscodeClaudeLogStatus {
    $recentClaudeLogs = @()
    if (Test-Path $VSCODE_LOGS_DIR) {
        $recentClaudeLogs = Get-ChildItem -Recurse -File $VSCODE_LOGS_DIR -Filter "Claude VSCode.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5
    }
    if ($recentClaudeLogs.Count -eq 0) { return $null }

    $timestampPattern = '^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})'
    $latest403 = $null
    $latestLogin = $null
    $latest403Path = $null

    foreach ($logFile in $recentClaudeLogs) {
        $matches = Select-String -Path $logFile.FullName -Pattern "OAuth authentication is currently not allowed for this organization|Received message from webview: .*""type"":""login"",""method"":""claudeai""" -ErrorAction SilentlyContinue
        foreach ($m in $matches) {
            $line = $m.Line
            $ts = $null
            if ($line -match $timestampPattern) {
                $ts = [datetime]::ParseExact($Matches['ts'], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            }

            if ($line -like "*OAuth authentication is currently not allowed for this organization*") {
                if (-not $latest403 -or ($ts -and $ts -gt $latest403)) {
                    $latest403 = $ts
                    $latest403Path = $logFile.FullName
                }
            }
            if ($line -like '*"type":"login","method":"claudeai"*') {
                if (-not $latestLogin -or ($ts -and $ts -gt $latestLogin)) {
                    $latestLogin = $ts
                }
            }
        }
    }

    if (-not $latest403) {
        return [pscustomobject]@{
            Status = "clear"
            Latest403Time = $null
            LatestLoginTime = $latestLogin
            Latest403Path = $null
        }
    }

    $status = "current_403"
    if ($latestLogin -and $latest403 -and $latestLogin -gt $latest403) {
        $status = "historical_403"
    }

    return [pscustomobject]@{
        Status = $status
        Latest403Time = $latest403
        LatestLoginTime = $latestLogin
        Latest403Path = $latest403Path
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-VscodeLoginLoopStatus: Detect 403 -> login -> 403 loop ─
# ══════════════════════════════════════════════════════════════

function Get-VscodeLoginLoopStatus {
    if (-not (Test-Path $VSCODE_LOGS_DIR)) { return $null }

    $logFile = Get-ChildItem -Recurse -File $VSCODE_LOGS_DIR -Filter "Claude VSCode.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $logFile) { return $null }

    $pattern403 = "OAuth authentication is currently not allowed for this organization"
    $patternLogin = '"type":"login","method":"claudeai"'
    $lines = Get-Content $logFile.FullName -Tail 400 -ErrorAction SilentlyContinue
    $hits403 = @()
    $hitsLogin = @()

    foreach ($line in $lines) {
        if ($line -match '^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
            $ts = [datetime]::ParseExact($Matches['ts'], 'yyyy-MM-dd HH:mm:ss.fff', $null)
            if ($line -like "*$pattern403*") { $hits403 += $ts }
            if ($line -like "*$patternLogin*") { $hitsLogin += $ts }
        }
    }

    if ($hits403.Count -lt 2 -or $hitsLogin.Count -lt 1) {
        return [pscustomobject]@{
            IsLoop = $false
            LogFile = $logFile.FullName
            First403 = $null
            LoginTime = $null
            Second403 = $null
        }
    }

    $first403 = $hits403[0]
    $login = $hitsLogin | Where-Object { $_ -gt $first403 } | Select-Object -First 1
    $second403 = $hits403 | Where-Object { $login -and $_ -gt $login } | Select-Object -First 1

    return [pscustomobject]@{
        IsLoop = ($null -ne $first403 -and $null -ne $login -and $null -ne $second403)
        LogFile = $logFile.FullName
        First403 = $first403
        LoginTime = $login
        Second403 = $second403
    }
}

# ══════════════════════════════════════════════════════════════
# ── Export-AuthBaseline: Save login/proxy baseline snapshot ──
# ══════════════════════════════════════════════════════════════

function Export-AuthBaseline {
    param([string]$Reason = "manual")

    if (-not (Test-Path $AUTH_BASELINE_DIR)) {
        New-Item -ItemType Directory -Path $AUTH_BASELINE_DIR -Force | Out-Null
    }

    $oauthInfo = $null
    if (Test-Path "$env:USERPROFILE\.claude.json") {
        $oauthInfo = Read-JsonSafe "$env:USERPROFILE\.claude.json"
    }

    $proxySnapshot = [ordered]@{}
    foreach ($pv in $PROXY_ENV_VARS) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'User')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process') }
        if ($val) { $proxySnapshot[$pv] = $val }
    }

    $state = Get-VscodeClaudeState
    $payload = [ordered]@{
        generatedAt = (Get-Date).ToString("s")
        reason = $Reason
        claudeCliVersion = Get-ClaudeVersion
        vscodeExtensionVersion = Get-VscodeExtVersion
        proxyEnv = $proxySnapshot
        oauthAccount = if ($oauthInfo -and $oauthInfo.oauthAccount) { $oauthInfo.oauthAccount } else { $null }
        expectedAccount = [ordered]@{
            accountUuid = $script:ExpectedAccountUuid
            email = $script:ExpectedEmail
            organizationUuid = $script:ExpectedOrgUuid
            authBrowserProfile = $script:AuthBrowserProfile
        }
        vscodeClaudeState = $state
    }

    $fileName = "auth-baseline-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    $target = Join-Path $AUTH_BASELINE_DIR $fileName
    ($payload | ConvertTo-Json -Depth 10) | Set-Content $target -Encoding UTF8
    Write-Status "INFO" "认证基线已保存: $target"
    return $target
}

# ══════════════════════════════════════════════════════════════
# ── Export-ClaudeSupportBundle: Save non-secret evidence bundle ─
# ══════════════════════════════════════════════════════════════

function Export-ClaudeSupportBundle {
    param(
        [object]$ProbeResult = $null
    )

    if (-not (Test-Path $SUPPORT_BUNDLE_DIR)) {
        New-Item -ItemType Directory -Path $SUPPORT_BUNDLE_DIR -Force | Out-Null
    }

    $bundleDir = Join-Path $SUPPORT_BUNDLE_DIR ("bundle-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

    $authStatus = Get-ClaudeAuthStatusInfo
    $accountInfo = Get-ClaudeAccountInfo
    $loopInfo = Get-VscodeLoginLoopStatus
    if (-not $ProbeResult) { $ProbeResult = Invoke-ClaudeCapabilityProbe }

    $logFiles = @()
    if (Test-Path $VSCODE_LOGS_DIR) {
        $logFiles = Get-ChildItem -Recurse -File $VSCODE_LOGS_DIR -Filter "Claude VSCode.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 3
    }

    $logSnippets = @()
    foreach ($log in $logFiles) {
        $snippet = Select-String -Path $log.FullName -Pattern 'OAuth authentication is currently not allowed for this organization|Received message from webview: .*"type":"login","method":"claudeai"|request_id"|x-client-request-id=' -ErrorAction SilentlyContinue |
            Select-Object -First 40 |
            ForEach-Object { $_.Line }
        $logSnippets += [pscustomobject]@{
            Path = $log.FullName
            LastWriteTime = $log.LastWriteTime
            Lines = @($snippet)
        }
    }

    $payload = [ordered]@{
        generatedAt = (Get-Date).ToString("s")
        claudeCliVersion = Get-ClaudeVersion
        vscodeExtensionVersion = Get-VscodeExtVersion
        authStatus = $authStatus
        accountInfo = $accountInfo
        capabilityProbe = [ordered]@{
            status = $ProbeResult.Status
            detail = $ProbeResult.Detail
            exitCode = $ProbeResult.ExitCode
            rawOutput = $ProbeResult.RawOutput
        }
        loginLoop = $loopInfo
        logSnippets = $logSnippets
    }

    $jsonPath = Join-Path $bundleDir "support-bundle.json"
    ($payload | ConvertTo-Json -Depth 8) | Set-Content $jsonPath -Encoding UTF8

    $summary = @"
Claude Code support bundle

Generated: $($payload.generatedAt)
CLI version: $($payload.claudeCliVersion)
VS Code extension: $($payload.vscodeExtensionVersion)
Email: $($authStatus.email)
Organization: $($authStatus.orgName)
Auth method: $($authStatus.authMethod)
Capability probe: $($ProbeResult.Status)
Probe detail: $($ProbeResult.Detail)
Login loop detected: $($loopInfo.IsLoop)
"@
    $summaryPath = Join-Path $bundleDir "support-summary.txt"
    $summary | Set-Content $summaryPath -Encoding UTF8

    Write-Status "INFO" "支持证据包已导出: $bundleDir"
    return $bundleDir
}

# ══════════════════════════════════════════════════════════════
# ── Reset-VscodeClaudeState: Clear extension state caches ────
# ══════════════════════════════════════════════════════════════

function Reset-VscodeClaudeState {
    Write-Section "重置 VS Code Claude 扩展状态..." "[附加步骤 A]"

    if (Test-Path $VSCODE_STATE_DB) {
        Backup-Path $VSCODE_STATE_DB "vscode-state.vscdb" | Out-Null
    }
    if (Test-Path $VSCODE_STATE_DB_BACKUP) {
        Backup-Path $VSCODE_STATE_DB_BACKUP "vscode-state.vscdb.backup" | Out-Null
    }
    if (Test-Path $VSCODE_STORAGE_JSON) {
        Backup-Path $VSCODE_STORAGE_JSON "vscode-storage.json" | Out-Null
    }

    $globalScript = @"
import sqlite3, sys
db = sys.argv[1]
keys = sys.argv[2:]
con = sqlite3.connect(db)
cur = con.cursor()
for key in keys:
    cur.execute("delete from ItemTable where key = ?", (key,))
con.commit()
print("OK")
"@
    if (Test-Path $VSCODE_STATE_DB) {
        $res = Invoke-PythonSnippet -Script $globalScript -Arguments @($VSCODE_STATE_DB) + $VSCODE_CLAUDE_STATE_KEYS
        if ($res.Success) {
            Write-Status "OK" "已清理 VS Code 全局 Claude 状态键"
        } else {
            Write-Status "WARN" "清理 VS Code 全局状态失败: $($res.Output -join ' ')"
        }
    } else {
        Write-Status "SKIP" "未找到 VS Code 全局状态数据库"
    }

    if (Test-Path $VSCODE_WORKSPACE_STORAGE_DIR) {
        $workspaceDbs = Get-ChildItem $VSCODE_WORKSPACE_STORAGE_DIR -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "state.vscdb" } |
            Where-Object { Test-Path $_ }

        foreach ($db in $workspaceDbs) {
            $res = Invoke-PythonSnippet -Script $globalScript -Arguments @($db) + $VSCODE_CLAUDE_WORKSPACE_KEYS
            if (-not $res.Success) {
                Write-Status "WARN" "清理工作区状态失败: $db"
            }
        }
        if ($workspaceDbs.Count -gt 0) {
            Write-Status "OK" "已清理 $($workspaceDbs.Count) 个工作区中的 Claude 视图状态"
        }
    }

    if (Test-Path $VSCODE_CLAUDE_USER_DIR) {
        Backup-Path $VSCODE_CLAUDE_USER_DIR "vscode-user-Claude" | Out-Null
        $targetFile = Join-Path $VSCODE_CLAUDE_USER_DIR "claude_desktop_config.json"
        if (Test-Path $targetFile) {
            '{ "mcpServers": {} }' | Set-Content $targetFile -Encoding UTF8
            Write-Status "OK" "已重置 VS Code 用户 Claude 配置"
        }
    }
}
