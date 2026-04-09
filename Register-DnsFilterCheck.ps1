# Register-DnsFilterCheck.ps1 — One-time Task Scheduler registration
# Part of Claude Code Diagnostic & Repair Toolkit v5.0 Portable
#
# Registers ClaudeCron\ClashDnsFilterCheck with two triggers:
#   1. At startup (Windows boot) — catches proxy reconfiguration after reboot
#   2. Daily at 09:07             — daily drift detection
#
# Run once as: powershell -NoProfile -ExecutionPolicy Bypass -File Register-DnsFilterCheck.ps1

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskPath  = '\ClaudeCron\'
$TaskName  = 'ClashDnsFilterCheck'
$FullName  = $TaskPath + $TaskName

$VerifyScript = Join-Path $ScriptDir "Verify-DnsFilter.ps1"
if (-not (Test-Path $VerifyScript)) {
    Write-Host "[ERROR] Verify-DnsFilter.ps1 not found at $VerifyScript" -ForegroundColor Red
    exit 1
}

# Action: run Verify-DnsFilter.ps1 silently
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$VerifyScript`"" `
    -WorkingDirectory $ScriptDir

# Trigger 1: At startup (runs after Windows session logon, not system boot,
# because Interactive logon is required on Win10 Home)
$triggerStartup = New-ScheduledTaskTrigger -AtLogOn

# Trigger 2: Daily at 09:07 (offset from :00 avoids resource contention)
$triggerDaily   = New-ScheduledTaskTrigger -Daily -At '09:07'

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

# Unregister previous version if exists (ignore error if task not found)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
schtasks /delete /tn ($FullName.TrimStart('\')) /f 2>&1 | Out-Null
$ErrorActionPreference = $prevEAP

Register-ScheduledTask `
    -TaskPath  $TaskPath `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   @($triggerStartup, $triggerDaily) `
    -Settings  $settings `
    -Principal $principal `
    -Description "Verify Anthropic + OpenAI domains (7 entries) in Clash Verge fake-ip-filter at logon and daily 09:07. Auto-patches dns_config.yaml if missing." `
    -Force | Out-Null

Write-Host "[OK] Registered: $FullName" -ForegroundColor Green
Write-Host "     Triggers: At logon + daily 09:07" -ForegroundColor DarkGray
Write-Host "     Script:   $VerifyScript" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Verify with: schtasks /query /fo LIST /tn ClaudeCron\ClashDnsFilterCheck" -ForegroundColor Cyan
