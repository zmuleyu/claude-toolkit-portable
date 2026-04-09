# Verify-DnsFilter.ps1 — Boot-time Anthropic fake-ip-filter guard
# Part of Claude Code Diagnostic & Repair Toolkit v5.0 Portable
#
# Purpose: Verify dns_config.yaml contains the 4 required Anthropic/Claude
# entries in fake-ip-filter. Auto-patches if missing. Designed to run at
# Windows startup and daily via Task Scheduler (see Register-DnsFilterCheck.ps1).
#
# Outputs:
#   - ~/.claude/agent-logs/YYYY-MM-DD.md  (append)
#   - ~/.claude/data/cron-log.jsonl       (append)
#   - Windows toast notification on WARN/ERROR
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File Verify-DnsFilter.ps1

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Load modules ──────────────────────────────────────────────
. (Join-Path $ScriptRoot "modules\clash-fake-ip-fix.ps1")

# ── Constants ─────────────────────────────────────────────────
$TaskName   = "clash-dns-filter-check"
$AgentLogDir = "$env:USERPROFILE\.claude\agent-logs"
$CronLogFile = "$env:USERPROFILE\.claude\data\cron-log.jsonl"
$DateStr     = Get-Date -Format "yyyy-MM-dd"
$TimeStr     = Get-Date -Format "HH:mm"
$AgentLogFile = Join-Path $AgentLogDir "$DateStr.md"

# ── Logging helpers ───────────────────────────────────────────
function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-AgentLog {
    param([string]$Level, [string]$Detail)
    Ensure-Dir $AgentLogDir
    $line = "[$TimeStr] $TaskName | $Level | $Detail"
    Add-Content -LiteralPath $AgentLogFile -Value $line -Encoding UTF8
}

function Write-CronLog {
    param([string]$Status, [string]$Detail)
    Ensure-Dir (Split-Path -Parent $CronLogFile)
    $entry = [ordered]@{
        ts     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        task   = $TaskName
        status = $Status
        detail = $Detail
    }
    $json = $entry | ConvertTo-Json -Compress
    Add-Content -LiteralPath $CronLogFile -Value $json -Encoding UTF8
}

function Show-Toast {
    param([string]$Title, [string]$Message)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        )
        $xml.GetElementsByTagName('text')[0].AppendChild($xml.CreateTextNode($Title))  | Out-Null
        $xml.GetElementsByTagName('text')[1].AppendChild($xml.CreateTextNode($Message)) | Out-Null
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Claude Toolkit")
        $toast    = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $notifier.Show($toast)
    } catch {
        # Toast API unavailable — silently ignore; log entry is the primary record
    }
}

# ── Main check ────────────────────────────────────────────────
$result = Test-AnthropicFakeIpFilter

if ($result.Pass) {
    # All good in file: save last-good snapshot
    Save-LastGoodDnsConfig | Out-Null

    # Stale-patch check: entries present in file but mihomo may not have loaded them yet
    if (Get-Command -Name Test-MihomoLoadedCurrentConfig -ErrorAction SilentlyContinue) {
        $loadCheck = Test-MihomoLoadedCurrentConfig
        if (-not $loadCheck.Loaded) {
            Write-AgentLog "warn" "fake-ip-filter OK in file but stale — mihomo started $($loadCheck.MihomoStart), dns patched $($loadCheck.FileMtime). Restart Clash Verge required."
            Write-CronLog  "warn" "stale-patch: dns_config.yaml patched $($loadCheck.FileMtime) but mihomo started $($loadCheck.MihomoStart). Restart Clash Verge to apply."
            Show-Toast `
                "Claude Toolkit: Restart Required" `
                "dns_config.yaml was updated after Clash Verge started.`nRestart Clash Verge to activate AI provider fake-IP protection."
            exit 0
        }
    }

    Write-AgentLog "pass" "fake-ip-filter OK — all 7 entries active in running mihomo"
    Write-CronLog  "pass" "fake-ip-filter OK: claude.ai, +.claude.ai, api.anthropic.com, +.anthropic.com, openai.com, +.openai.com, api.openai.com"
    exit 0
}

# ── Missing entries — attempt auto-patch ─────────────────────
$missingList = $result.Missing -join ", "
Write-AgentLog "warn" ("fake-ip-filter missing: $missingList — attempting auto-patch")

$patched = Add-AnthropicFakeIpFilter -Quiet
if ($patched) {
    Save-LastGoodDnsConfig | Out-Null
    Write-AgentLog "pass" "fake-ip-filter patched OK — restart Clash Verge to apply"
    Write-CronLog  "warn" "fake-ip-filter was missing ($missingList); auto-patched OK. Clash Verge restart required."
    Show-Toast `
        "Claude Toolkit: DNS Filter Patched" `
        "Added: $missingList`nRestart Clash Verge to apply."
    exit 0
}

# ── Patch failed ─────────────────────────────────────────────
Write-AgentLog "fail" ("fake-ip-filter patch FAILED — missing: $missingList. Manual fix required.")
Write-CronLog  "fail" "fake-ip-filter patch failed. Missing: $missingList. Check dns_config.yaml manually."
Show-Toast `
    "Claude Toolkit: DNS Filter ERROR" `
    "Could not patch dns_config.yaml.`nMissing: $missingList`nRun Verify-DnsFilter.ps1 manually."
exit 1
