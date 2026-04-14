# mode-recovery.ps1 - Mode 7: Guided Auth Recovery
# Part of Claude Code Diagnostic & Repair Toolkit v7.0
#
# Integrates the full recovery sequence into a single mode:
#   system proxy disable → fake-ip-filter patch → Clash Direct → OAuth reset
#
# Replaces the standalone Run-Auth-Recovery.ps1 (kept as thin wrapper).

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
