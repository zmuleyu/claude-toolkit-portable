# mode-network.ps1 - Mode 4: Network Diagnostics & Repair
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

function Invoke-NetworkDiagnostics {

    $script:NetResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:NetContext = [ordered]@{
        DetectedProxy = $null
        ClashMode = $null
        ClashMixedPort = $null
        HasTun = $false
        HasSecondaryTunnel = $false
        HasIpv4RouteConflict = $false
        HasIpv6RouteConflict = $false
        PrimaryLanIP = $null
        NoProxyValue = $null
        RecommendedNoProxy = $null
        VscodeProxy = $null
    }

    function Add-NetResult {
        param(
            [string]$Check,
            [string]$Status,
            [string]$Detail
        )
        $script:NetResults.Add([PSCustomObject]@{
            Check = $Check
            Status = $Status
            Detail = $Detail
        })
    }

    function Test-PortOpen {
        param(
            [string]$TargetHost,
            [int]$Port,
            [int]$TimeoutMs = 800
        )
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
            $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($ok -and $tcp.Connected) {
                $tcp.EndConnect($ar)
                $tcp.Close()
                return $true
            }
            $tcp.Close()
            return $false
        } catch {
            return $false
        }
    }

    function Test-HttpReachability {
        param(
            [string]$Url,
            [string]$Proxy = $null,
            [switch]$DisableSystemProxy
        )

        $result = [ordered]@{
            Reachability = "unreachable"
            StatusCode = $null
            DurationMs = 0
            Detail = ""
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($DisableSystemProxy -and -not $Proxy) {
                $req = [System.Net.HttpWebRequest]::Create($Url)
                $req.Method = "GET"
                $req.Timeout = 10000
                $req.ReadWriteTimeout = 10000
                $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                $resp = $req.GetResponse()
                $statusCode = [int]([System.Net.HttpWebResponse]$resp).StatusCode
                $resp.Close()
                $result.StatusCode = $statusCode
            } else {
                $params = @{
                    Uri = $Url
                    UseBasicParsing = $true
                    TimeoutSec = 10
                    ErrorAction = "Stop"
                }
                if ($Proxy) {
                    $params.Proxy = $Proxy
                }

                $resp = Invoke-WebRequest @params
                $result.StatusCode = [int]$resp.StatusCode
            }
            $sw.Stop()
            $result.DurationMs = $sw.ElapsedMilliseconds

            if ($result.StatusCode -ge 200 -and $result.StatusCode -le 299) {
                $result.Reachability = "reachable_ok"
                $result.Detail = "HTTP $($result.StatusCode)"
            } elseif ($result.StatusCode -ge 300 -and $result.StatusCode -le 499) {
                $result.Reachability = "reachable_non_200"
                $result.Detail = "HTTP $($result.StatusCode)"
            } else {
                $result.Reachability = "unreachable"
                $result.Detail = "HTTP $($result.StatusCode)"
            }
            return [pscustomobject]$result
        } catch {
            $sw.Stop()
            $result.DurationMs = $sw.ElapsedMilliseconds

            $statusCode = $null
            try {
                if ($_.Exception.Response) {
                    $statusCode = [int]([System.Net.HttpWebResponse]$_.Exception.Response).StatusCode
                } elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
                    $statusCode = [int]([System.Net.HttpWebResponse]$_.Exception.InnerException.Response).StatusCode
                }
            } catch { }

            if ($statusCode) {
                $result.StatusCode = $statusCode
                if ($statusCode -ge 300 -and $statusCode -le 499) {
                    $result.Reachability = "reachable_non_200"
                    $result.Detail = "HTTP $statusCode"
                } elseif ($statusCode -ge 200 -and $statusCode -le 299) {
                    $result.Reachability = "reachable_ok"
                    $result.Detail = "HTTP $statusCode"
                } else {
                    $result.Reachability = "unreachable"
                    $result.Detail = "HTTP $statusCode"
                }
            } else {
                $msg = $_.Exception.Message
                if ($msg -match 'timed out|timeout') {
                    $result.Detail = "Timeout"
                } elseif ($msg -match 'remote name could not be resolved|name resolution') {
                    $result.Detail = "DNS failure"
                } elseif ($msg -match 'SSL|TLS|certificate|secure channel') {
                    $result.Detail = "TLS failure"
                } elseif ($msg -match 'Unable to connect|actively refused') {
                    $result.Detail = "Connection refused"
                } elseif ($msg -match 'proxy') {
                    $result.Detail = "Proxy failure"
                } else {
                    $result.Detail = $msg
                }
            }

            return [pscustomobject]$result
        }
    }

    function Format-ReachabilityCell {
        param($Result)
        switch ($Result.Reachability) {
            "reachable_ok" { return @{ Text = ("OK {0,4}ms" -f $Result.DurationMs); Color = "Green" } }
            "reachable_non_200" { return @{ Text = ("ST {0,4}" -f $Result.StatusCode); Color = "Yellow" } }
            default { return @{ Text = "FAIL    "; Color = "Red" } }
        }
    }

    function Get-ReachabilitySummaryStatus {
        param([array]$Results)
        $reachable = @($Results | Where-Object { $_.Reachability -ne "unreachable" }).Count
        $ok = @($Results | Where-Object { $_.Reachability -eq "reachable_ok" }).Count
        if ($reachable -eq 0) { return "FAIL" }
        if ($ok -eq $Results.Count) { return "PASS" }
        return "WARN"
    }

    function Get-ReachabilitySummaryDetail {
        param([array]$Results)
        $reachable = @($Results | Where-Object { $_.Reachability -ne "unreachable" }).Count
        $statusOnly = @($Results | Where-Object { $_.Reachability -eq "reachable_non_200" }).Count
        $failed = @($Results | Where-Object { $_.Reachability -eq "unreachable" }).Count
        return "reachable=$reachable status_only=$statusOnly failed=$failed"
    }

    $generalEndpoints = @(
        @{ Name = "claude.ai"; URL = "https://claude.ai"; Host = "claude.ai" },
        @{ Name = "api.anthropic.com"; URL = "https://api.anthropic.com"; Host = "api.anthropic.com" },
        @{ Name = "statsig.anthropic.com"; URL = "https://statsig.anthropic.com"; Host = "statsig.anthropic.com" },
        @{ Name = "console.anthropic.com"; URL = "https://console.anthropic.com"; Host = "console.anthropic.com" },
        @{ Name = "api.openai.com"; URL = "https://api.openai.com"; Host = "api.openai.com" }
    )
    $devEndpoints = @(
        @{ Name = "github.com"; URL = "https://github.com"; Host = "github.com" },
        @{ Name = "registry.npmjs.org"; URL = "https://registry.npmjs.org"; Host = "registry.npmjs.org" },
        @{ Name = "pypi.org"; URL = "https://pypi.org"; Host = "pypi.org" }
    )

    Write-Section "Proxy Topology and Tunnels" "[1/11]"
    $proxyProcs = Get-Process -Name $PROXY_PROC_NAMES -ErrorAction SilentlyContinue
    if ($proxyProcs) {
        foreach ($p in $proxyProcs) {
            Write-Status "WARN" "Proxy process: $($p.Name) (PID $($p.Id))"
        }
    } else {
        Write-Status "OK" "No proxy process detected"
    }

    $clashApiCfg = Get-ClashApiConfig
    $clashMode = Get-ClashMode -ApiCfg $clashApiCfg
    if ($clashMode) {
        $script:NetContext.ClashMode = $clashMode
        Write-Status "INFO" "Clash mode: $clashMode"
    }
    if ($clashApiCfg.MixedPort) {
        $script:NetContext.ClashMixedPort = $clashApiCfg.MixedPort
        $script:NetContext.DetectedProxy = "http://127.0.0.1:$($clashApiCfg.MixedPort)"
        Write-Status "INFO" "Clash mixed-port: $($clashApiCfg.MixedPort)"
    }

    $systemProxy = $null
    $proxyReg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($proxyReg -and [bool]$proxyReg.ProxyEnable -and $proxyReg.ProxyServer) {
        $systemProxy = $proxyReg.ProxyServer
        Write-Status "INFO" "System proxy: $systemProxy"
        Add-NetResult "System Proxy Active" "WARN" $systemProxy
    } else {
        Write-Status "INFO" "System proxy disabled"
        Add-NetResult "System Proxy Active" "PASS" "Disabled"
    }

    $envProxyHits = @()
    foreach ($pv in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','https_proxy','http_proxy','all_proxy')) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'User') }
        if ($val) { $envProxyHits += "$pv=$val" }
    }
    if ($envProxyHits.Count -gt 0) {
        foreach ($hit in $envProxyHits) {
            Write-Status "INFO" "Env proxy: $hit"
        }
    } else {
        Write-Status "OK" "No env proxy configured"
    }

    if (Test-Path $VSCODE_SETTINGS) {
        $vsContent = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8
        $vsProxyMatch = [regex]::Match($vsContent, '"http\.proxy"\s*:\s*"([^"]+)"')
        if ($vsProxyMatch.Success) {
            $script:NetContext.VscodeProxy = $vsProxyMatch.Groups[1].Value
            Write-Status "INFO" "VS Code http.proxy: $($script:NetContext.VscodeProxy)"
        } else {
            Write-Status "OK" "VS Code http.proxy not set"
        }
    }

    $tunAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "Clash|TUN|TAP|WireGuard|VPN|warp|utun|tailscale" -or
        $_.InterfaceDescription -match "TAP|TUN|WireGuard|Wintun|Tailscale"
    }
    $secondaryTunnelNames = @()
    if ($tunAdapters) {
        foreach ($adapter in $tunAdapters) {
            Write-Status "OK" "Tunnel adapter: $($adapter.Name) [$($adapter.InterfaceDescription)] - $($adapter.Status)"
            if ($adapter.Name -match "Tailscale|WireGuard|warp" -or $adapter.InterfaceDescription -match "Tailscale|WireGuard") {
                $secondaryTunnelNames += $adapter.Name
            }
            if ($adapter.Name -match "Clash|Mihomo|TUN" -or $adapter.InterfaceDescription -match "Wintun|Meta Tunnel") {
                $script:NetContext.HasTun = $true
            }
        }
    }
    if ($secondaryTunnelNames.Count -gt 0) {
        $script:NetContext.HasSecondaryTunnel = $true
        Write-Status "WARN" "Multiple tunnels detected: $($secondaryTunnelNames -join ', ')"
    } else {
        Write-Status "OK" "No secondary tunnel detected"
    }

    $ipv4Defaults = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric,InterfaceAlias
    if ($ipv4Defaults) {
        foreach ($route in $ipv4Defaults) {
            Write-Status "INFO" "IPv4 default route: $($route.InterfaceAlias) -> $($route.NextHop) (metric $($route.RouteMetric))"
        }
        $tunnelDefaults = @($ipv4Defaults | Where-Object { $_.InterfaceAlias -match 'Mihomo|Tailscale|WireGuard|VPN|TUN|Meta' })
        if ($tunnelDefaults.Count -gt 1) {
            $script:NetContext.HasIpv4RouteConflict = $true
            Write-Status "ERROR" "Multiple tunnel-backed IPv4 default routes detected"
        } elseif ($tunnelDefaults.Count -eq 1) {
            Write-Status "OK" "Exactly one tunnel-backed IPv4 default route is active"
        } else {
            Write-Status "INFO" "IPv4 default route is not owned by a tunnel interface"
        }
    }

    $ipv6Defaults = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric,InterfaceAlias
    if ($ipv6Defaults) {
        foreach ($route in $ipv6Defaults) {
            Write-Status "INFO" "IPv6 default route: $($route.InterfaceAlias) -> $($route.NextHop) (metric $($route.RouteMetric))"
        }
        $tunnelIpv6Defaults = @($ipv6Defaults | Where-Object { $_.InterfaceAlias -match 'Mihomo|Tailscale|WireGuard|VPN|TUN|Meta' })
        if ($tunnelIpv6Defaults.Count -gt 1) {
            $script:NetContext.HasIpv6RouteConflict = $true
            Write-Status "WARN" "Multiple tunnel-backed IPv6 default routes detected"
        }
    }

    if ($script:NetContext.HasIpv4RouteConflict) {
        Add-NetResult "Tunnel Topology" "ERROR" "Multiple tunnel default routes on IPv4"
    } elseif ($script:NetContext.HasSecondaryTunnel -and $script:NetContext.HasIpv6RouteConflict) {
        Add-NetResult "Tunnel Topology" "WARN" "Secondary tunnel coexists and IPv6 default routes overlap"
    } elseif ($script:NetContext.HasSecondaryTunnel) {
        Add-NetResult "Tunnel Topology" "WARN" "Secondary tunnel present but IPv4 default route is not conflicting"
    } else {
        Add-NetResult "Tunnel Topology" "PASS" "Topology discovered"
    }

    Write-Section "DNS Resolution and Tunnel Control" "[2/11]"
    $dnsResults = @()
    $fakeIpHits = @()
    foreach ($ep in $generalEndpoints) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $entry = [System.Net.Dns]::GetHostEntry($ep.Host)
            $sw.Stop()
            $ips = @($entry.AddressList | ForEach-Object { $_.IPAddressToString })
            $hasFakeIp = (@($ips | Where-Object { $_ -match $FAKE_IP_REGEX }).Count -gt 0)
            if ($hasFakeIp) {
                Write-Status "WARN" "$($ep.Name) -> $($ips -join ', ') ($($sw.ElapsedMilliseconds)ms) [TUN intercepted fake-IP]"
                $fakeIpHits += $ep.Name
            } else {
                Write-Status "OK" "$($ep.Name) -> $($ips -join ', ') ($($sw.ElapsedMilliseconds)ms)"
            }
            $dnsResults += [pscustomobject]@{ Name = $ep.Name; OK = $true; Ms = $sw.ElapsedMilliseconds; IPs = $ips; HasFakeIp = $hasFakeIp }
        } catch {
            Write-Status "ERROR" "$($ep.Name) -> DNS resolution failed"
            $dnsResults += [pscustomobject]@{ Name = $ep.Name; OK = $false; Ms = 0; IPs = @(); HasFakeIp = $false }
        }
    }
    $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Select-Object -ExpandProperty ServerAddresses -Unique
    if ($dnsServers) {
        Write-Status "INFO" "System DNS servers: $($dnsServers -join ', ')"
    }
    $dnsFails = @($dnsResults | Where-Object { -not $_.OK })
    if ($dnsFails.Count -gt 0) {
        Add-NetResult "DNS Resolution" "FAIL" "Failed: $(($dnsFails | ForEach-Object { $_.Name }) -join ', ')"
    } else {
        Add-NetResult "DNS Resolution" "PASS" "AI endpoints resolved"
    }
    if ($fakeIpHits.Count -gt 0) {
        Add-NetResult "Fake-IP DNS" "WARN" "TUN intercepted: $($fakeIpHits -join ', ')"
    } else {
        Add-NetResult "Fake-IP DNS" "PASS" "No fake-IP detected"
    }

    # Source-of-truth audit: Anthropic + OpenAI must be in dns_config.yaml fake-ip-filter.
    # Both use long-lived SSE streams that break under fake-ip (error decoding response body).
    # Requires modules\clash-fake-ip-fix.ps1 (loaded as a required module).
    $script:FakeIpFilterStale = $false
    if (Get-Command -Name Test-AnthropicFakeIpFilter -ErrorAction SilentlyContinue) {
        $filterCheck = Test-AnthropicFakeIpFilter
        $script:FakeIpFilterCheck = $filterCheck
        if ($filterCheck.Pass) {
            Write-Status "OK" "dns_config.yaml fake-ip-filter: all 7 AI provider entries present"
            # Stale-patch check: entries present in file but mihomo may not have loaded them yet
            if (Get-Command -Name Test-MihomoLoadedCurrentConfig -ErrorAction SilentlyContinue) {
                $script:MihomoLoadCheck = Test-MihomoLoadedCurrentConfig
                if (-not $script:MihomoLoadCheck.Loaded) {
                    $script:FakeIpFilterStale = $true
                    Write-Status "WARN" "dns_config.yaml patched AFTER mihomo started — entries NOT yet active"
                    Write-Status "INFO" "  mihomo start : $($script:MihomoLoadCheck.MihomoStart)"
                    Write-Status "INFO" "  dns_config   : $($script:MihomoLoadCheck.FileMtime)"
                    Write-Status "INFO" "  See ACTION section to restart Clash Verge and apply."
                    Add-NetResult "AI Provider Fake-IP Filter" "WARN" $script:MihomoLoadCheck.Reason
                } else {
                    Add-NetResult "AI Provider Fake-IP Filter" "PASS" "Anthropic (4) + OpenAI (3) all excluded from fake-IP pool"
                }
            } else {
                Add-NetResult "AI Provider Fake-IP Filter" "PASS" "Anthropic (4) + OpenAI (3) all excluded from fake-IP pool"
            }
        } else {
            Write-Status "WARN" "dns_config.yaml fake-ip-filter missing: $($filterCheck.Missing -join ', ')"
            Write-Status "INFO" "See ACTION section below to auto-patch, or run Run-Auth-Recovery.ps1"
            Add-NetResult "AI Provider Fake-IP Filter" "WARN" $filterCheck.Reason
        }
    }

    Write-Section "Public IP, TCP, TLS Baseline" "[3/11]"
    $publicIp = $null
    foreach ($url in $IP_CHECK_URLS) {
        try {
            $publicIp = (Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop).Content.Trim()
            if ($publicIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
                Write-Status "OK" "Public IP: $publicIp (via $url)"
                break
            }
        } catch { }
    }
    if (-not $publicIp) {
        Write-Status "WARN" "Unable to get public IP"
    }

    foreach ($targetHost in @("api.anthropic.com", "github.com")) {
        if (Test-PortOpen -TargetHost $targetHost -Port 443 -TimeoutMs 5000) {
            Write-Status "OK" "${targetHost}:443 TCP handshake succeeded"
        } else {
            Write-Status "ERROR" "${targetHost}:443 TCP handshake failed"
        }
    }

    $tlsOk = $true
    foreach ($ep in $generalEndpoints[0..1]) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.ConnectAsync($ep.Host, 443).Wait(5000) | Out-Null
            if (-not $tcp.Connected) { throw "TCP timeout" }
            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
            $ssl.AuthenticateAsClient($ep.Host)
            $issuer = $ssl.RemoteCertificate.Issuer
            $expiry = [datetime]::Parse($ssl.RemoteCertificate.GetExpirationDateString())
            $daysLeft = ($expiry - (Get-Date)).Days
            Write-Status "OK" "$($ep.Name): TLS valid ($daysLeft days left, issuer: $issuer)"
            $ssl.Close()
            $tcp.Close()
        } catch {
            $tlsOk = $false
            Write-Status "ERROR" "$($ep.Name): TLS validation failed - $($_.Exception.Message)"
        }
    }
    if ($tlsOk) {
        Add-NetResult "Transport Baseline" "PASS" "Public IP, TCP, TLS are healthy"
    } else {
        Add-NetResult "Transport Baseline" "FAIL" "TCP/TLS baseline failed"
    }

    Write-Section "HTTPS Direct Reachability" "[4/11]"
    $savedProxy = @{}
    foreach ($pv in $PROXY_ENV_VARS) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process')
        if ($val) {
            $savedProxy[$pv] = $val
            [System.Environment]::SetEnvironmentVariable($pv, $null, 'Process')
        }
    }

    $directResults = @()
    foreach ($ep in $generalEndpoints) {
        $res = Test-HttpReachability -Url $ep.URL -DisableSystemProxy
        $directResults += [pscustomobject]@{
            Name = $ep.Name
            Reachability = $res.Reachability
            StatusCode = $res.StatusCode
            DurationMs = $res.DurationMs
            Detail = $res.Detail
        }
        switch ($res.Reachability) {
            "reachable_ok" { Write-Status "OK" "$($ep.Name): HTTP $($res.StatusCode) ($($res.DurationMs)ms)" }
            "reachable_non_200" { Write-Status "WARN" "$($ep.Name): reachable but returned $($res.Detail)" }
            default { Write-Status "ERROR" "$($ep.Name): unreachable ($($res.Detail))" }
        }
    }
    foreach ($kv in $savedProxy.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    }
    if ($systemProxy) {
        Write-Status "WARN" "System proxy is enabled. Direct HTTP test above bypassed it explicitly; browser/CLI traffic may still differ until system proxy is disabled."
    }
    Add-NetResult "HTTPS Direct" (Get-ReachabilitySummaryStatus -Results $directResults) (Get-ReachabilitySummaryDetail -Results $directResults)

    Write-Section "HTTPS Proxy Reachability" "[5/11]"
    $proxyResults = @()
    if ($script:NetContext.DetectedProxy) {
        Write-Status "INFO" "Using proxy: $($script:NetContext.DetectedProxy)"
        foreach ($ep in $generalEndpoints) {
            $res = Test-HttpReachability -Url $ep.URL -Proxy $script:NetContext.DetectedProxy
            $proxyResults += [pscustomobject]@{
                Name = $ep.Name
                Reachability = $res.Reachability
                StatusCode = $res.StatusCode
                DurationMs = $res.DurationMs
                Detail = $res.Detail
            }
            switch ($res.Reachability) {
                "reachable_ok" { Write-Status "OK" "$($ep.Name): HTTP $($res.StatusCode) ($($res.DurationMs)ms)" }
                "reachable_non_200" { Write-Status "WARN" "$($ep.Name): proxy reachable but returned $($res.Detail)" }
                default { Write-Status "ERROR" "$($ep.Name): proxy unreachable ($($res.Detail))" }
            }
        }
        Add-NetResult "HTTPS Proxy" (Get-ReachabilitySummaryStatus -Results $proxyResults) (Get-ReachabilitySummaryDetail -Results $proxyResults)
    } else {
        Write-Status "SKIP" "No proxy detected, proxy test skipped"
        Add-NetResult "HTTPS Proxy" "INFO" "Skipped"
    }

    Write-Section "Single Proxy Entry Audit" "[6/11]"
    $portSources = @()
    if ($systemProxy -and $systemProxy -match ':(\d{4,5})') {
        $portSources += [pscustomobject]@{ Source = "System proxy"; Port = $Matches[1] }
    }
    foreach ($hit in $envProxyHits) {
        if ($hit -match '=(.+):(\d{4,5})') {
            $portSources += [pscustomobject]@{ Source = ($hit -split '=')[0]; Port = $Matches[2] }
        }
    }
    if ($script:NetContext.VscodeProxy -and $script:NetContext.VscodeProxy -match ':(\d{4,5})') {
        $portSources += [pscustomobject]@{ Source = "VS Code http.proxy"; Port = $Matches[1] }
    }
    if ($script:NetContext.ClashMixedPort) {
        $portSources += [pscustomobject]@{ Source = "Clash mixed-port"; Port = $script:NetContext.ClashMixedPort }
    }
    foreach ($ps in $portSources) {
        Write-Status "INFO" "$($ps.Source): port $($ps.Port)"
    }
    if ($portSources.Count -eq 0) {
        Write-Status "OK" "No extra proxy entry found"
        Add-NetResult "Proxy Entry" "PASS" "No conflict"
    } else {
        $uniquePorts = @($portSources | Select-Object -ExpandProperty Port -Unique)
        if ($uniquePorts.Count -eq 1) {
            Write-Status "OK" "Proxy entry is converged to port $($uniquePorts[0])"
            Add-NetResult "Proxy Entry" "PASS" "Single entry"
        } else {
            Write-Status "WARN" "Proxy ports are inconsistent: $($uniquePorts -join ', ')"
            Add-NetResult "Proxy Entry" "WARN" "Ports differ: $($uniquePorts -join ', ')"
        }
    }

    Write-Section "NO_PROXY and LAN Bypass" "[7/11]"
    $noProxy = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "User")
    if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "Process") }
    if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("no_proxy", "User") }
    if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("no_proxy", "Process") }
    $script:NetContext.NoProxyValue = $noProxy

    if ($noProxy) {
        Write-Status "INFO" "NO_PROXY: $noProxy"
    } else {
        Write-Status "WARN" "NO_PROXY is not set"
    }

    $requiredHints = @("localhost", "127.0.0.1", "::1", "192.168.", "10.", "172.16.")
    $missingNoProxy = @()
    foreach ($hint in $requiredHints) {
        if (-not $noProxy -or $noProxy -notmatch [regex]::Escape($hint)) {
            $missingNoProxy += $hint
        }
    }
    $recommendedNoProxy = "localhost,127.0.0.1,::1,192.168.*,10.*,172.16.*,172.17.*,172.18.*,172.19.*,172.2*,172.30.*,172.31.*"
    $script:NetContext.RecommendedNoProxy = $recommendedNoProxy
    if ($missingNoProxy.Count -gt 0) {
        Write-Status "WARN" "LAN bypass is incomplete, missing: $($missingNoProxy -join ', ')"
        Write-Status "INFO" "Recommended NO_PROXY: $recommendedNoProxy"
        Add-NetResult "NO_PROXY Audit" "WARN" "LAN bypass incomplete"
    } else {
        Write-Status "OK" "NO_PROXY covers local and LAN ranges"
        Add-NetResult "NO_PROXY Audit" "PASS" "LAN bypass complete"
    }

    Write-Section "Clash Exclude Route Audit" "[8/11]"
    if ($clashApiCfg.ConfigFile -and (Test-Path $clashApiCfg.ConfigFile)) {
        $tunCfgContent = Get-Content $clashApiCfg.ConfigFile -Raw -ErrorAction SilentlyContinue
        $excludeOk = $false
        if ($tunCfgContent -match '192\.168\.0\.0/16' -or
            $tunCfgContent -match '10\.0\.0\.0/8' -or
            $tunCfgContent -match '172\.16\.0\.0/12') {
            $excludeOk = $true
        }
        if ($excludeOk) {
            Write-Status "OK" "Clash exclude-route includes LAN ranges"
            Add-NetResult "Clash Exclude Route" "PASS" "LAN ranges excluded"
        } else {
            Write-Status "WARN" "Clash exclude-route does not clearly include all LAN ranges"
            Write-Status "INFO" "Recommended: 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12"
            Add-NetResult "Clash Exclude Route" "WARN" "LAN exclude-route incomplete"
        }
    } else {
        Write-Status "WARN" "Unable to audit Clash config"
        Add-NetResult "Clash Exclude Route" "WARN" "Unknown"
    }

    Write-Section "Developer Network Checks" "[9/11]"
    $devResults = @()
    foreach ($ep in $devEndpoints) {
        $res = if ($script:NetContext.DetectedProxy) {
            Test-HttpReachability -Url $ep.URL -Proxy $script:NetContext.DetectedProxy
        } else {
            Test-HttpReachability -Url $ep.URL
        }
        $devResults += [pscustomobject]@{
            Name = $ep.Name
            Reachability = $res.Reachability
            StatusCode = $res.StatusCode
            DurationMs = $res.DurationMs
            Detail = $res.Detail
        }
        switch ($res.Reachability) {
            "reachable_ok" { Write-Status "OK" "$($ep.Name): HTTP $($res.StatusCode) ($($res.DurationMs)ms)" }
            "reachable_non_200" { Write-Status "WARN" "$($ep.Name): reachable but returned $($res.Detail)" }
            default { Write-Status "ERROR" "$($ep.Name): unreachable ($($res.Detail))" }
        }
    }
    Add-NetResult "Dev Endpoints" (Get-ReachabilitySummaryStatus -Results $devResults) (Get-ReachabilitySummaryDetail -Results $devResults)

    Write-Section "Loopback and LAN Dev Path" "[10/11]"
    $loopbackPorts = @(3000, 5173, 8000, 8080, 8787)
    $openLoopbacks = @()
    foreach ($port in $loopbackPorts) {
        if (Test-PortOpen -TargetHost "127.0.0.1" -Port $port -TimeoutMs 200) {
            $openLoopbacks += $port
        }
    }
    if ($openLoopbacks.Count -gt 0) {
        Write-Status "OK" "Loopback listening ports: $($openLoopbacks -join ', ')"
    } else {
        Write-Status "INFO" "No common local dev port is listening"
    }

    $ipconfigOut = ipconfig 2>&1 | Out-String
    $lanIPs = @()
    foreach ($line in $ipconfigOut -split "`n") {
        if ($line -match "IPv4.*?:\s*([\d.]+)") {
            $ip = $Matches[1].Trim()
            if ($ip -notmatch '^198\.18\.' -and $ip -notmatch '^169\.254\.' -and $ip -notmatch '^192\.168\.137\.') {
                $lanIPs += $ip
            }
        }
    }
    $script:NetContext.PrimaryLanIP = ($lanIPs | Select-Object -First 1)
    if ($script:NetContext.PrimaryLanIP) {
        Write-Status "INFO" "Primary LAN IP: $($script:NetContext.PrimaryLanIP)"
        Add-NetResult "LAN Dev Path" "PASS" "Primary LAN IP available"
    } else {
        Write-Status "WARN" "Stable LAN IP not detected"
        Add-NetResult "LAN Dev Path" "WARN" "LAN IP unstable or tunnel-only"
    }

    Write-Section "Baseline and Layered Actions" "[11/11]"
    Write-Host ""
    Write-Host "  Endpoint Summary" -ForegroundColor Cyan
    Write-Host "  Endpoint                 DNS       Direct    Proxy" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------" -ForegroundColor Cyan
    for ($i = 0; $i -lt $generalEndpoints.Count; $i++) {
        $ep = $generalEndpoints[$i]
        $dnsCell = if ($dnsResults[$i].OK) { @{ Text = ("OK {0,4}ms" -f $dnsResults[$i].Ms); Color = "Green" } } else { @{ Text = "FAIL    "; Color = "Red" } }
        $directCell = Format-ReachabilityCell -Result $directResults[$i]
        $proxyCell = if ($proxyResults.Count -gt 0) { Format-ReachabilityCell -Result $proxyResults[$i] } else { @{ Text = "--      "; Color = "DarkGray" } }
        $name = $ep.Name.PadRight(24)

        Write-Host "  " -ForegroundColor Cyan -NoNewline
        Write-Host $name -NoNewline
        Write-Host "  " -ForegroundColor Cyan -NoNewline
        Write-Host $dnsCell.Text.PadRight(8) -ForegroundColor $dnsCell.Color -NoNewline
        Write-Host "  " -ForegroundColor Cyan -NoNewline
        Write-Host $directCell.Text.PadRight(8) -ForegroundColor $directCell.Color -NoNewline
        Write-Host "  " -ForegroundColor Cyan -NoNewline
        Write-Host $proxyCell.Text.PadRight(8) -ForegroundColor $proxyCell.Color -NoNewline
        Write-Host ""
    }
    Write-Host "  ---------------------------------------------------" -ForegroundColor Cyan
    if ($fakeIpHits.Count -gt 0) {
        Write-Host ""
        Write-Host "  [!] Fake-IP active on: $($fakeIpHits -join ', ')" -ForegroundColor Yellow
        Write-Host "  [!] OAuth/HTTPS to these hosts will time out until Clash is restarted after patching." -ForegroundColor Yellow
    }

    $directSummary = Get-ReachabilitySummaryStatus -Results $directResults
    $proxySummary = if ($proxyResults.Count -gt 0) { Get-ReachabilitySummaryStatus -Results $proxyResults } else { "INFO" }
    $transportHealthy = @($script:NetResults | Where-Object { $_.Check -eq "Transport Baseline" -and $_.Status -eq "PASS" }).Count -gt 0

    if ($transportHealthy -and $directSummary -ne "FAIL") {
        Write-Status "OK" "Network transport is healthy. 403/404 are service responses, not network failures."
    } elseif ($transportHealthy -and $proxySummary -ne "FAIL") {
        Write-Status "WARN" "Base transport is healthy but the environment depends on proxy routing."
    } else {
        Write-Status "ERROR" "A real transport issue is present."
    }

    Write-Host ""
    Write-Status "ACTION" "Do now"
    if ($script:NetContext.HasIpv4RouteConflict) {
        Write-Status "INFO" "Resolve IPv4 default-route conflict before further app-level debugging."
    } elseif ($script:NetContext.HasSecondaryTunnel -or $script:NetContext.HasIpv6RouteConflict) {
        Write-Status "INFO" "Audit route priority between Clash TUN and Tailscale/WireGuard."
    }
    # Stale-patch case: entries present in file but mihomo hasn't reloaded — restart only, no patch needed
    if ($script:FakeIpFilterStale -and (Get-Command -Name Restart-ClashVerge -ErrorAction SilentlyContinue)) {
        Write-Status "INFO" "dns_config.yaml is correct but Clash Verge has NOT loaded the latest entries."
        Write-Status "INFO" "  Anthropic + OpenAI fake-IP protection will NOT work until Clash Verge is restarted."
        if ($script:AutoFixEnabled -or (Confirm-Action "Restart Clash Verge now to activate existing patch?")) {
            Restart-ClashVerge | Out-Null
            Write-Status "OK" "Clash Verge restarted. Fake-IP entries for Anthropic + OpenAI are now active."
        } else {
            Write-Status "WARN" "Skipped. Codex/Claude SSE disconnections will continue until Clash Verge is restarted."
        }
    } elseif (@($script:NetResults | Where-Object { $_.Check -eq "AI Provider Fake-IP Filter" -and $_.Status -eq "WARN" }).Count -gt 0) {
        Write-Status "INFO" "Patch dns_config.yaml to exclude Anthropic + OpenAI domains from Clash fake-IP pool."
        if (Get-Command -Name Add-AnthropicFakeIpFilter -ErrorAction SilentlyContinue) {
            $patched = $false
            if ($script:AutoFixEnabled) {
                if (Add-AnthropicFakeIpFilter) {
                    if (Get-Command -Name Save-LastGoodDnsConfig -ErrorAction SilentlyContinue) {
                        Save-LastGoodDnsConfig | Out-Null
                    }
                    Write-Status "OK" "dns_config.yaml patched automatically"
                    $patched = $true
                }
            } elseif (Confirm-Action "Patch dns_config.yaml now?") {
                if (Add-AnthropicFakeIpFilter) {
                    if (Get-Command -Name Save-LastGoodDnsConfig -ErrorAction SilentlyContinue) {
                        Save-LastGoodDnsConfig | Out-Null
                    }
                    Write-Status "OK" "dns_config.yaml patched"
                    $patched = $true
                } else {
                    Write-Status "ERROR" "Add-AnthropicFakeIpFilter failed"
                }
            } else {
                Write-Status "SKIP" "dns_config.yaml not patched. Run Run-Auth-Recovery.ps1 to fix later."
            }
            if ($patched -and (Get-Command -Name Restart-ClashVerge -ErrorAction SilentlyContinue)) {
                if (Confirm-Action "Restart Clash Verge to apply the patch?") {
                    Restart-ClashVerge | Out-Null
                    Write-Status "OK" "Clash Verge restarted. DNS fake-IP should clear in ~5s."
                } else {
                    Write-Status "INFO" "Patch applied but not active until Clash Verge is restarted."
                }
            }
            # Offer to install persistent guard (ClashDnsFilterCheck Task Scheduler task)
            if ($patched -and (Get-Command -Name Test-DnsFilterGuardRegistered -ErrorAction SilentlyContinue)) {
                if (-not (Test-DnsFilterGuardRegistered)) {
                    Write-Status "INFO" "DNS filter guard task not installed (prevents future drift)."
                    $registerScript = Join-Path $ScriptRoot "Register-DnsFilterCheck.ps1"
                    if ((Test-Path $registerScript) -and ($script:AutoFixEnabled -or (Confirm-Action "Install ClashDnsFilterCheck guard task (runs at logon + 09:07 daily)?"))) {
                        try {
                            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $registerScript
                            Write-Status "OK" "ClashDnsFilterCheck task registered — persistent protection active."
                        } catch {
                            Write-Status "WARN" "Guard task registration failed: $_"
                        }
                    } else {
                        Write-Status "INFO" "Skip guard install. Run Register-DnsFilterCheck.ps1 manually later."
                    }
                } else {
                    Write-Status "OK" "ClashDnsFilterCheck guard task already installed."
                }
            }
        } else {
            Write-Status "INFO" "Run Run-Auth-Recovery.ps1 for guided auto-patch."
        }
    }
    if (@($script:NetResults | Where-Object { $_.Check -eq "NO_PROXY Audit" -and $_.Status -eq "WARN" }).Count -gt 0) {
        Write-Status "INFO" "Expand NO_PROXY to cover localhost, 127.0.0.1, ::1, 192.168.*, 10.*, 172.16-31.*."
        if ($script:AutoFixEnabled) {
            [System.Environment]::SetEnvironmentVariable("NO_PROXY", $script:NetContext.RecommendedNoProxy, "User")
            [System.Environment]::SetEnvironmentVariable("NO_PROXY", $script:NetContext.RecommendedNoProxy, "Process")
            [System.Environment]::SetEnvironmentVariable("no_proxy", $script:NetContext.RecommendedNoProxy, "User")
            [System.Environment]::SetEnvironmentVariable("no_proxy", $script:NetContext.RecommendedNoProxy, "Process")
            Write-Status "OK" "NO_PROXY has been updated automatically"
        } elseif (Confirm-Action "Apply recommended NO_PROXY now?") {
            [System.Environment]::SetEnvironmentVariable("NO_PROXY", $script:NetContext.RecommendedNoProxy, "User")
            [System.Environment]::SetEnvironmentVariable("NO_PROXY", $script:NetContext.RecommendedNoProxy, "Process")
            [System.Environment]::SetEnvironmentVariable("no_proxy", $script:NetContext.RecommendedNoProxy, "User")
            [System.Environment]::SetEnvironmentVariable("no_proxy", $script:NetContext.RecommendedNoProxy, "Process")
            Write-Status "OK" "NO_PROXY has been updated"
        } else {
            Write-Status "SKIP" "NO_PROXY change skipped"
        }
    }
    if (@($script:NetResults | Where-Object { $_.Check -eq "Proxy Entry" -and $_.Status -eq "WARN" }).Count -gt 0) {
        Write-Status "INFO" "Converge to a single proxy entry across system proxy, env vars, and VS Code."
    }
    if (@($script:NetResults | Where-Object { $_.Check -eq "Clash Exclude Route" -and $_.Status -eq "WARN" }).Count -gt 0) {
        Write-Status "INFO" "Add LAN exclude-route entries: 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12."
    }

    $authReadiness = Get-AuthNetworkReadiness
    $authReadinessStatus = if ($authReadiness.Ready) {
        if ($authReadiness.ProxyVerificationIncomplete) { "WARN" } else { "PASS" }
    } else {
        "FAIL"
    }
    Add-NetResult "Auth Readiness" $authReadinessStatus "$($authReadiness.Status): $($authReadiness.Reason)"
    Write-Host ""
    Write-Status "ACTION" "Auth readiness"
    Write-Status "INFO" "Status: $($authReadiness.Status)"
    Write-Status "INFO" "Reason: $($authReadiness.Reason)"
    if ($authReadiness.ProxyVerificationIncomplete -and $authReadiness.Ready) {
        Write-Status "WARN" "Clash API could not be verified, but the current path looks safe enough for auth."
    } elseif (-not $authReadiness.Ready) {
        Write-Status "INFO" "Mode auth will block claude login until this state is cleared."
    }

    Write-Host ""
    Write-Status "ACTION" "Maintenance window only"
    Write-Status "INFO" "Run ipconfig /flushdns and Clear-DnsClientCache only if DNS issues persist."
    Write-Status "INFO" "Run netsh winsock reset only if the socket stack is clearly broken and a reboot is acceptable."

    Write-Host ""
    Write-Status "ACTION" "Daily stable baseline"
    Write-Status "INFO" "Keep Clash/TUN and keep system proxy aligned with Clash mixed-port."
    Write-Status "INFO" "Avoid duplicate user-level HTTP_PROXY and HTTPS_PROXY definitions."
    Write-Status "INFO" "Add local dev services and LAN resources to NO_PROXY or Clash bypass rules."
    Write-Status "INFO" "Treat 403/404 as application status unless DNS, TCP, or TLS also fail."
}
