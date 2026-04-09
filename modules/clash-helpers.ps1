# clash-helpers.ps1 — Clash Verge / Mihomo API helpers
# Extracted from Fix-ClaudeAuth v3.1 (zero logic changes)
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

# ══════════════════════════════════════════════════════════════
# ── Clash Verge runtime config paths ─────────────────────────
# ══════════════════════════════════════════════════════════════

$clashVergeConfigPaths = @(
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\clash-verge-runtime.yaml",
    "$env:APPDATA\clash-verge\clash-verge-runtime.yaml",
    "$env:APPDATA\ClashVerge\clash-verge-runtime.yaml",
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\config.yaml",
    "$env:USERPROFILE\.config\clash-verge\clash-verge-runtime.yaml"
)

# ══════════════════════════════════════════════════════════════
# ── Get-ClashApiConfig ───────────────────────────────────────
# ══════════════════════════════════════════════════════════════

function Get-ClashApiConfig {
    foreach ($path in $clashVergeConfigPaths) {
        if (Test-Path $path) {
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $portMatch   = [regex]::Match($content, 'external-controller\s*:\s*[''"]?[\d.]+:(\d+)[''"]?')
                $secretMatch = [regex]::Match($content, 'secret\s*:\s*[''"]?([^''"\r\n]+)[''"]?')
                $port   = if ($portMatch.Success)   { $portMatch.Groups[1].Value.Trim() }   else { "9090" }
                $secret = if ($secretMatch.Success) { $secretMatch.Groups[1].Value.Trim() } else { "" }

                # Also try to extract mixed-port for proxy port detection
                $mixedPortMatch = [regex]::Match($content, 'mixed-port\s*:\s*(\d+)')
                $mixedPort = if ($mixedPortMatch.Success) { $mixedPortMatch.Groups[1].Value.Trim() } else { $null }

                return @{
                    Port       = $port
                    Secret     = $secret
                    ConfigFile = $path
                    MixedPort  = $mixedPort
                }
            }
        }
    }
    return @{ Port = "9090"; Secret = ""; ConfigFile = ""; MixedPort = $null }
}

# ══════════════════════════════════════════════════════════════
# ── Invoke-ClashApi ──────────────────────────────────────────
# ══════════════════════════════════════════════════════════════

function Invoke-ClashApi {
    param(
        [string]$Port,
        [string]$Secret,
        [string]$Method = "GET",
        [string]$Endpoint,
        [string]$Body = ""
    )
    $uri     = "http://127.0.0.1:$Port$Endpoint"
    $headers = @{ "Content-Type" = "application/json" }
    if ($Secret -ne "") { $headers["Authorization"] = "Bearer $Secret" }

    try {
        if ($Method -eq "GET") {
            $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop -TimeoutSec 3
        } else {
            $resp = Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $Body -ErrorAction Stop -TimeoutSec 3
        }
        return $resp
    } catch {
        return $null
    }
}

# ══════════════════════════════════════════════════════════════
# ── Get-ClashMode / Set-ClashMode ────────────────────────────
# ══════════════════════════════════════════════════════════════

function Get-ClashMode {
    param($ApiCfg)
    $resp = Invoke-ClashApi -Port $ApiCfg.Port -Secret $ApiCfg.Secret -Endpoint "/configs"
    if ($resp) { return $resp.mode } else { return $null }
}

function Set-ClashMode {
    param($ApiCfg, [string]$Mode)
    $body = "{`"mode`": `"$Mode`"}"
    $resp = Invoke-ClashApi -Port $ApiCfg.Port -Secret $ApiCfg.Secret -Method "PATCH" -Endpoint "/configs" -Body $body
    return ($null -ne $resp)
}

function Wait-ForClashMode {
    param(
        $ApiCfg,
        [string]$ExpectedMode,
        [int]$TimeoutSeconds = 8
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $currentMode = Get-ClashMode -ApiCfg $ApiCfg
        if ($currentMode -eq $ExpectedMode) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}
