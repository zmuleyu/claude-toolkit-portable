# Run-Auth-Recovery.ps1 - v7.0+ backward-compatible wrapper
# Full recovery logic is now Mode 7 in Claude-Toolkit.ps1.
# Prefer: Claude-Toolkit.ps1 -Mode recovery
#
# This wrapper loads the required modules and calls Invoke-AuthRecovery directly,
# so it still works as a standalone script or from shortcuts/documentation links.

param(
    [string]$ExpectedAccountUuid,
    [string]$ExpectedEmail,
    [string]$ExpectedOrgUuid,
    [string]$AuthBrowserProfile
)

$ErrorActionPreference = "Continue"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($mod in @(
    "constants.ps1",
    "utils.ps1",
    "clash-helpers.ps1",
    "clash-fake-ip-fix.ps1",
    "mode-auth.ps1",
    "mode-recovery.ps1"
)) {
    . (Join-Path $scriptRoot "modules" $mod)
}

$script:AutoFixEnabled      = $false
$script:ExpectedAccountUuid = $ExpectedAccountUuid
$script:ExpectedEmail       = $ExpectedEmail
$script:ExpectedOrgUuid     = $ExpectedOrgUuid
$script:AuthBrowserProfile  = $AuthBrowserProfile
$script:PythonExe           = $null

Find-PythonCmd | Out-Null

Write-Host ""
Write-Host "  Claude Code Auth Recovery  (v7.0 - Mode 7)" -ForegroundColor Cyan
Write-Host "  For the full toolkit: Claude-Toolkit.ps1 -Mode recovery" -ForegroundColor DarkGray
Write-Host ""

Invoke-AuthRecovery

Write-Host ""
Read-Host 'Press Enter to exit'
