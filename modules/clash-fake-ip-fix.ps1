# clash-fake-ip-fix.ps1 - Anthropic fake-ip-filter detect/patch/restart
# Part of Claude Code Diagnostic & Repair Toolkit v5+
#
# Purpose: keep claude.ai / api.anthropic.com / *.anthropic.com / *.claude.ai
# OUT of Mihomo's fake-ip pool so that OAuth and HTTPS work correctly when
# Clash Verge runs in TUN + fake-ip mode.
#
# The single source of truth is Clash Verge's GUI "DNS Settings" file:
#   %APPDATA%\io.github.clash-verge-rev.clash-verge-rev\dns_config.yaml
# When verge.yaml has `enable_dns_settings: true`, this file overrides every
# profile's dns section, so patching profile/merge files is futile.
#
# Exported functions:
#   Get-DnsConfigPath
#   Get-AnthropicFakeIpFilterRequired
#   Test-AnthropicFakeIpFilter           -> $true if all required entries present
#   Add-AnthropicFakeIpFilter            -> idempotent patch with timestamped backup
#   Save-LastGoodDnsConfig               -> snapshot to backups/dns_config.yaml.last-good
#   Restore-LastGoodDnsConfig            -> restore from snapshot if drift detected
#   Restart-ClashVerge                   -> stop UI + mihomo and relaunch UI

$script:ClashVergeAppData = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$script:ClashVergeUiExe   = "C:\Program Files\Clash Verge\clash-verge.exe"
$script:ToolkitBackupDir  = Join-Path $PSScriptRoot "..\backups"

function Get-DnsConfigPath {
    return (Join-Path $script:ClashVergeAppData "dns_config.yaml")
}

function Get-AnthropicFakeIpFilterRequired {
    # Domains that must be excluded from fake-ip pool. Use mihomo's `+.` prefix
    # to cover every subdomain in one entry.
    # Includes Anthropic/Claude AND OpenAI — both use long-lived SSE streams
    # that break under fake-ip (error decoding response body).
    return @(
        'claude.ai',
        '+.claude.ai',
        'api.anthropic.com',
        '+.anthropic.com',
        'openai.com',
        '+.openai.com',
        'api.openai.com'
    )
}

function Test-AnthropicFakeIpFilter {
    param([string]$DnsConfigPath = (Get-DnsConfigPath))

    if (-not (Test-Path $DnsConfigPath)) {
        return [pscustomobject]@{
            Pass    = $false
            Reason  = "dns_config.yaml not found at $DnsConfigPath"
            Missing = (Get-AnthropicFakeIpFilterRequired)
        }
    }

    $required = Get-AnthropicFakeIpFilterRequired
    $content  = Get-Content -LiteralPath $DnsConfigPath -Raw -Encoding UTF8

    # Extract the fake-ip-filter list block. We avoid YAML parsing to keep zero
    # external dependencies; the file format is stable enough for regex.
    $blockMatch = [regex]::Match(
        $content,
        '(?ms)^\s*fake-ip-filter:\s*\r?\n((?:\s*-\s*[^\r\n]+\r?\n)+)'
    )
    if (-not $blockMatch.Success) {
        return [pscustomobject]@{
            Pass    = $false
            Reason  = "fake-ip-filter block not found"
            Missing = $required
        }
    }

    $block = $blockMatch.Groups[1].Value
    $items = @()
    foreach ($line in $block -split "`n") {
        $line = $line.Trim()
        if ($line -match '^-\s*[''"]?([^''"\s#]+)[''"]?') {
            $items += $matches[1]
        }
    }

    $missing = @()
    foreach ($req in $required) {
        if ($items -notcontains $req) { $missing += $req }
    }

    return [pscustomobject]@{
        Pass    = ($missing.Count -eq 0)
        Reason  = if ($missing.Count -eq 0) { "All required entries present" } else { "Missing: $($missing -join ', ')" }
        Missing = $missing
        Items   = $items
    }
}

function Add-AnthropicFakeIpFilter {
    param(
        [string]$DnsConfigPath = (Get-DnsConfigPath),
        [switch]$Quiet
    )

    if (-not (Test-Path $DnsConfigPath)) {
        if (-not $Quiet) { Write-Host "[ERROR] dns_config.yaml not found: $DnsConfigPath" -ForegroundColor Red }
        return $false
    }

    $check = Test-AnthropicFakeIpFilter -DnsConfigPath $DnsConfigPath
    if ($check.Pass) {
        if (-not $Quiet) { Write-Host "[SKIP]  fake-ip-filter already complete" -ForegroundColor DarkGray }
        return $true
    }

    # Timestamped backup before mutation
    $ts = Get-Date -Format "yyyyMMddHHmmss"
    $backupPath = "$DnsConfigPath.bak.$ts"
    Copy-Item -LiteralPath $DnsConfigPath -Destination $backupPath -Force
    if (-not $Quiet) { Write-Host "[BACKUP] $backupPath" -ForegroundColor DarkGray }

    $content = Get-Content -LiteralPath $DnsConfigPath -Raw -Encoding UTF8

    # Insert each missing entry just before `fake-ip-filter-mode:` (which always
    # follows the list in the GUI-generated file).
    $insertion = ($check.Missing | ForEach-Object { "  - $_" }) -join "`n"
    $patched = [regex]::Replace(
        $content,
        '(?m)^(\s*)fake-ip-filter-mode:',
        ($insertion + "`n" + '$1fake-ip-filter-mode:')
    )

    if ($patched -eq $content) {
        if (-not $Quiet) { Write-Host "[ERROR] Failed to locate insertion anchor (fake-ip-filter-mode)" -ForegroundColor Red }
        return $false
    }

    Set-Content -LiteralPath $DnsConfigPath -Value $patched -Encoding UTF8 -NoNewline:$false
    if (-not $Quiet) {
        Write-Host "[PATCH] Added: $($check.Missing -join ', ')" -ForegroundColor Green
    }
    return $true
}

function Save-LastGoodDnsConfig {
    param([string]$DnsConfigPath = (Get-DnsConfigPath))
    if (-not (Test-Path $DnsConfigPath)) { return $false }

    if (-not (Test-Path $script:ToolkitBackupDir)) {
        New-Item -ItemType Directory -Path $script:ToolkitBackupDir -Force | Out-Null
    }
    $dest = Join-Path $script:ToolkitBackupDir "dns_config.yaml.last-good"
    Copy-Item -LiteralPath $DnsConfigPath -Destination $dest -Force
    return $true
}

function Restore-LastGoodDnsConfig {
    param([string]$DnsConfigPath = (Get-DnsConfigPath))
    $src = Join-Path $script:ToolkitBackupDir "dns_config.yaml.last-good"
    if (-not (Test-Path $src)) {
        Write-Host "[ERROR] No last-good snapshot at $src" -ForegroundColor Red
        return $false
    }
    $ts = Get-Date -Format "yyyyMMddHHmmss"
    Copy-Item -LiteralPath $DnsConfigPath -Destination "$DnsConfigPath.bak.before-restore.$ts" -Force
    Copy-Item -LiteralPath $src -Destination $DnsConfigPath -Force
    Write-Host "[RESTORED] dns_config.yaml from last-good snapshot" -ForegroundColor Green
    return $true
}

function Test-DnsFilterGuardRegistered {
    # Returns $true if the ClashDnsFilterCheck scheduled task exists.
    $task = Get-ScheduledTask -TaskName 'ClashDnsFilterCheck' -TaskPath '\ClaudeCron\' -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Restart-ClashVerge {
    param(
        [string]$UiExe = $script:ClashVergeUiExe,
        [int]$WaitSeconds = 4
    )

    $ui = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
    if ($ui) {
        $ui | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # Mihomo is auto-respawned by clash-verge-service when killed; we restart it
    # so that dns_config.yaml is reloaded into the new mihomo instance.
    $mihomo = Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue
    if ($mihomo) {
        $mihomo | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    if (-not (Test-Path $UiExe)) {
        Write-Host "[ERROR] Clash Verge UI not found at $UiExe" -ForegroundColor Red
        return $false
    }
    Start-Process -FilePath $UiExe
    Start-Sleep -Seconds $WaitSeconds

    $newUi = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
    if ($newUi) {
        Write-Host "[RESTART] clash-verge.exe PID $($newUi.Id)" -ForegroundColor Green
        return $true
    }
    Write-Host "[WARN] clash-verge.exe did not restart in time" -ForegroundColor Yellow
    return $false
}
