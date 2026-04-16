# diagnostics-shared.ps1 — Shared diagnostic utilities (v7.5)
# Extracted common checks used by mode-health.ps1 and mode-network.ps1
# These functions provide a stable API for future refactoring.

# ── DNS Resolution Batch Test ─────────────────────────────────
# Returns: @{ OkCount; FailCount; Results }
# Used by: mode-health (quick summary), mode-network (detailed report)
function Invoke-DnsResolutionBatch {
    param(
        [Parameter(Mandatory)]
        [array]$Endpoints,          # Each item: @{ Name; Host }
        [int]$TimeoutMs = 3000
    )

    $results = @()
    foreach ($ep in $Endpoints) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            [System.Net.Dns]::GetHostAddresses($ep.Host) | Out-Null
            $sw.Stop()
            $results += [pscustomobject]@{
                Name    = $ep.Name
                Host    = $ep.Host
                Success = $true
                Ms      = $sw.ElapsedMilliseconds
                Error   = $null
            }
        } catch {
            $sw.Stop()
            $results += [pscustomobject]@{
                Name    = $ep.Name
                Host    = $ep.Host
                Success = $false
                Ms      = $sw.ElapsedMilliseconds
                Error   = $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        Results  = $results
        OkCount  = @($results | Where-Object { $_.Success }).Count
        FailCount = @($results | Where-Object { -not $_.Success }).Count
    }
}

# ── Proxy Port Topology Summary ───────────────────────────────
# Collects proxy port from: ENV vars / VS Code settings / System proxy / Clash API
# Returns: @{ Sources; UniquePorts; Consistent; Port }
function Get-ProxyPortTopology {
    param(
        [string]$VscodeSettingsPath = $null
    )

    $sources = @()

    # Env vars
    foreach ($pv in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'User')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process') }
        if ($val -and $val -match ':(\d{4,5})') {
            $sources += [pscustomobject]@{ Source = "ENV:$pv"; Port = $Matches[1] }
        }
    }

    # VS Code settings
    $vsPath = if ($VscodeSettingsPath) { $VscodeSettingsPath } else {
        if (Get-Variable -Name 'VSCODE_SETTINGS' -Scope Script -ErrorAction SilentlyContinue) { $VSCODE_SETTINGS } else { $null }
    }
    if ($vsPath -and (Test-Path $vsPath)) {
        $vsRaw = Get-Content $vsPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($vsRaw) {
            $vsPMatch = [regex]::Match($vsRaw, '"http\.proxy"\s*:\s*"[^"]*:(\d{4,5})"')
            if ($vsPMatch.Success) {
                $sources += [pscustomobject]@{ Source = "VS Code http.proxy"; Port = $vsPMatch.Groups[1].Value }
            }
        }
    }

    # System proxy registry
    try {
        $proxyReg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
        if ($proxyReg -and $proxyReg.ProxyEnable -and $proxyReg.ProxyServer -and $proxyReg.ProxyServer -match ':(\d{4,5})') {
            $sources += [pscustomobject]@{ Source = "System proxy"; Port = $Matches[1] }
        }
    } catch { }

    # Clash API
    if (Get-Command -Name Get-ClashApiConfig -ErrorAction SilentlyContinue) {
        try {
            $apiCfg = Get-ClashApiConfig
            if ($apiCfg -and $apiCfg.MixedPort) {
                $sources += [pscustomobject]@{ Source = "Clash mixed-port"; Port = "$($apiCfg.MixedPort)" }
            }
        } catch { }
    }

    $uniquePorts = @($sources | ForEach-Object { $_.Port } | Sort-Object -Unique)
    $consistent  = ($uniquePorts.Count -le 1)
    $port        = if ($uniquePorts.Count -eq 1) { $uniquePorts[0] } else { $null }

    return [pscustomobject]@{
        Sources     = $sources
        UniquePorts = $uniquePorts
        Consistent  = $consistent
        Port        = $port
    }
}

# ── Endpoint Reachability Quick Matrix ────────────────────────
# Lightweight HTTP HEAD check (no TLS inspection, no fake-IP analysis)
# For deep diagnostics use mode-network.ps1
# Returns: array of @{ Name; Url; StatusCode; Ms; Ok }
function Test-EndpointReachabilityBatch {
    param(
        [Parameter(Mandatory)]
        [array]$Endpoints,   # Each: @{ Name; Url }
        [int]$TimeoutSec = 8
    )

    $results = @()
    foreach ($ep in $Endpoints) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -UseBasicParsing -TimeoutSec $TimeoutSec -Method Head -ErrorAction Stop
            $sw.Stop()
            $results += [pscustomobject]@{
                Name       = $ep.Name
                Url        = $ep.Url
                StatusCode = [int]$resp.StatusCode
                Ms         = $sw.ElapsedMilliseconds
                Ok         = ($resp.StatusCode -ge 200 -and $resp.StatusCode -le 399)
            }
        } catch {
            $sw.Stop()
            $sc = $null
            if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
            $results += [pscustomobject]@{
                Name       = $ep.Name
                Url        = $ep.Url
                StatusCode = $sc
                Ms         = $sw.ElapsedMilliseconds
                Ok         = $false
            }
        }
    }
    return $results
}
