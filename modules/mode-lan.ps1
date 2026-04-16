# mode-lan.ps1 — Mode 6: LAN Diagnostics & Cross-Device Connectivity
# Part of Claude Code Diagnostic & Repair Toolkit v7.5
# Includes peer-check functionality (consolidated from mode-peer-check.ps1 in v7.5)

# ── Shared helpers for peer scanning ─────────────────────────

function Test-TcpPort {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 2000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $tcp.BeginConnect($Ip, $Port, $null, $null)
        $wait = $result.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait -and $tcp.Connected) { return $true }
        return $false
    } catch { return $false }
    finally { $tcp.Close() }
}

function Invoke-PingTest {
    param([string]$Ip)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Ip, 2000)
        return [pscustomobject]@{
            Success   = ($reply.Status -eq "Success")
            RoundTrip = $reply.RoundtripTime
            Status    = $reply.Status.ToString()
        }
    } catch {
        return [pscustomobject]@{ Success = $false; RoundTrip = -1; Status = $_.ToString() }
    }
}

function Get-PeersConfig {
    $toolkitRoot = Split-Path -Parent $PSScriptRoot
    $peersFile   = Join-Path $toolkitRoot "config\peers.json"

    if (Test-Path $peersFile) {
        try {
            return (Get-Content $peersFile -Raw | ConvertFrom-Json)
        } catch {
            Write-Status "WARN" "peers.json 解析失败，使用默认配置"
        }
    }
    return $null
}

function Invoke-PeerScan {
    # Scan all peers from the loaded config object
    param($PeersConfig)
    $peers = $PeersConfig.peers
    foreach ($peerName in ($peers.PSObject.Properties.Name)) {
        $peer  = $peers.$peerName
        $ip    = $peer.ip
        $label = if ($peer.PSObject.Properties["label"]) { $peer.label } else { $peerName }

        Write-Host ""
        Write-Host "  ── Peer: $label ($ip) ───────────────────────────" -ForegroundColor Cyan

        $pingResult = Invoke-PingTest $ip
        if ($pingResult.Success) {
            Write-Status "OK"   "Ping $ip : 成功 ($($pingResult.RoundTrip) ms)"
        } else {
            Write-Status "FAIL" "Ping $ip : 失败 ($($pingResult.Status))"
        }

        $openCount  = 0
        $portResults = @()
        foreach ($portDef in $peer.ports) {
            $portNum   = if ($portDef -is [int]) { $portDef } else { [int]$portDef.port }
            $portLabel = if ($portDef -is [hashtable] -or ($portDef.PSObject.Properties["label"])) { $portDef.label } else { "port $portNum" }
            $open = Test-TcpPort -Ip $ip -Port $portNum -TimeoutMs 2000
            if ($open) { $openCount++ }
            $portResults += [pscustomobject]@{ Port = $portNum; Label = $portLabel; Open = $open }
        }

        Write-Host ""
        Write-Host ("  {0,-6} {1,-28} {2}" -f "端口", "用途", "状态") -ForegroundColor DarkGray
        Write-Host ("  {0}" -f ("-" * 48)) -ForegroundColor DarkGray
        foreach ($r in $portResults) {
            $statusTxt = if ($r.Open) { "OPEN  ✔" } else { "closed" }
            $color     = if ($r.Open) { "Green" } else { "DarkGray" }
            Write-Host ("  {0,-6} {1,-28} {2}" -f $r.Port, $r.Label, $statusTxt) -ForegroundColor $color
        }

        Write-Host ""
        if ($openCount -eq 0 -and -not $pingResult.Success) {
            Write-Host "  ── 根因诊断 ─────────────────────────────────────" -ForegroundColor Yellow
            Write-Host "  Ping 不通 + 所有端口关闭。可能原因:" -ForegroundColor Yellow
            Write-Host "    1. $ip 目标机器已关机或不在线" -ForegroundColor White
            Write-Host "    2. 本机 / 对端防火墙拦截 ICMP + TCP" -ForegroundColor White
            Write-Host "    3. 两机不在同一子网或 VLAN" -ForegroundColor White
            Write-Host "    4. Clash TUN 代理了所有流量（包括 LAN）" -ForegroundColor White
        } elseif ($openCount -eq 0 -and $pingResult.Success) {
            Write-Host "  ── 根因诊断 ─────────────────────────────────────" -ForegroundColor Yellow
            Write-Host "  Ping 通但所有服务端口关闭。最可能原因:" -ForegroundColor Yellow
            Write-Host "    1. [高概率] 目标机器服务未启动 (lan-toolkit/SSH/RDP)" -ForegroundColor White
            Write-Host "    2. [高概率] 目标机器 Windows 防火墙拦截入站连接" -ForegroundColor White
            Write-Host "    3. [低概率] 本机出站被 Clash TUN 规则重定向" -ForegroundColor White
        } else {
            Write-Status "OK" "$openCount / $($portResults.Count) 个端口可达"
        }
    }
}

function Invoke-LanDiagnostics {

    $script:LanResults = New-Object System.Collections.ArrayList

    function Add-LanResult {
        param([string]$Check, [string]$Status, [string]$Detail)
        $script:LanResults.Add([PSCustomObject]@{ Check=$Check; Status=$Status; Detail=$Detail }) | Out-Null
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    # ── 1/7. Local IP Detection ──────────────────────────────
    Write-Section "本机 IP 检测" "[1/7]"

    $ipconfigOutput = ipconfig 2>&1 | Out-String
    $allLocalIPs = @()
    $currentAdapter = ""
    foreach ($line in $ipconfigOutput -split "`n") {
        if ($line -match "^(\S.+):$") { $currentAdapter = $Matches[1].Trim() }
        if ($line -match 'IPv4.*?:\s*([\d.]+)') {
            $allLocalIPs += @{ IP = $Matches[1].Trim(); Adapter = $currentAdapter }
        }
    }

    $tunIP = $null
    $primaryLanIP = $null
    $primaryAdapter = ""
    $virtualIPs = @()

    foreach ($entry in $allLocalIPs) {
        $ip = $entry.IP
        $isVirtual = $false
        foreach ($prefix in $VIRTUAL_ADAPTER_PREFIXES) {
            if ($ip.StartsWith($prefix)) { $isVirtual = $true; break }
        }

        if ($ip.StartsWith($TUN_IP_PREFIX)) {
            $tunIP = $ip
            Write-Status "WARN" "TUN: $ip ($($entry.Adapter))"
        } elseif ($isVirtual) {
            $virtualIPs += $entry
            Write-Status "INFO" "虚拟: $ip ($($entry.Adapter)) — 已跳过"
        } else {
            Write-Status "OK" "LAN: $ip ($($entry.Adapter))"
            if (-not $primaryLanIP) {
                if ($ip.StartsWith("192.168.") -or $ip.StartsWith("10.") -or $ip -match '^172\.(1[6-9]|2\d|3[01])\.') {
                    $primaryLanIP = $ip
                    $primaryAdapter = $entry.Adapter
                }
            }
        }
    }

    if ($primaryLanIP) {
        Write-Status "OK" "主 LAN IP: $primaryLanIP ($primaryAdapter)"
        Add-LanResult "Local IP" "PASS" $primaryLanIP
    } else {
        Write-Status "ERROR" "未检测到有效的 LAN IP"
        Add-LanResult "Local IP" "FAIL" "无 LAN IP"
    }

    # ── 2/7. TUN Mode Check ──────────────────────────────────
    Write-Section "TUN 模式检测" "[2/7]"

    if ($tunIP) {
        Write-Status "WARN" "Clash TUN 模式激活: $tunIP"
        Write-Status "INFO" "TUN 会劫持所有流量，包括 LAN 通信"

        # Check Clash Verge config for exclude-route
        $clashApiCfg = Get-ClashApiConfig
        $excludeOk = $false
        if ($clashApiCfg.ConfigFile -and (Test-Path $clashApiCfg.ConfigFile)) {
            $cfgContent = Get-Content $clashApiCfg.ConfigFile -Raw -ErrorAction SilentlyContinue
            if ($cfgContent -match '192\.168\.0\.0' -and ($cfgContent -match '10\.0\.0\.0' -or $cfgContent -match 'exclude')) {
                $excludeOk = $true
                Write-Status "OK" "Clash 配置含私有网段排除规则"
            }
        }

        if (-not $excludeOk) {
            Write-Status "ERROR" "Clash 配置未排除私有网段 — LAN 流量被 TUN 劫持"
            Write-Status "INFO" "  修复方法:"
            Write-Status "INFO" "  Clash Verge → 设置 → TUN → exclude-route 添加:"
            Write-Status "INFO" "    - 192.168.0.0/16"
            Write-Status "INFO" "    - 10.0.0.0/8"
            Write-Status "INFO" "    - 172.16.0.0/12"
            Add-LanResult "TUN Mode" "FAIL" "未排除 LAN 段"
        } else {
            Add-LanResult "TUN Mode" "WARN" "TUN 激活但已排除 LAN"
        }
    } else {
        Write-Status "OK" "未检测到 TUN 模式"
        Add-LanResult "TUN Mode" "PASS" "无 TUN"
    }

    # ── 3/7. Network Profile ─────────────────────────────────
    Write-Section "网络配置文件类型" "[3/7]"

    $profileIssues = @()
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop
        foreach ($p in $profiles) {
            if ($p.NetworkCategory -eq 0) { $catName = "Public" }
            elseif ($p.NetworkCategory -eq 1) { $catName = "Private" }
            elseif ($p.NetworkCategory -eq 2) { $catName = "DomainAuthenticated" }
            else { $catName = "Unknown" }

            if ($catName -eq "Public") {
                Write-Status "ERROR" "$($p.InterfaceAlias): Public 网络 — 文件共享和设备发现被阻止"
                $profileIssues += @{ Alias = $p.InterfaceAlias; Name = $p.Name }
            } else {
                Write-Status "OK" "$($p.InterfaceAlias): $catName 网络"
            }
        }
    } catch {
        Write-Status "WARN" "无法获取网络配置文件: $_"
    }

    if ($profileIssues.Count -gt 0) {
        Add-LanResult "Network Profile" "FAIL" "$($profileIssues.Count) 个 Public 网络"

        # Offer repair
        if ($isAdmin) {
            foreach ($issue in $profileIssues) {
                if (Confirm-Action "将 '$($issue.Alias)' 从 Public 改为 Private?") {
                    try {
                        Set-NetConnectionProfile -InterfaceAlias $issue.Alias -NetworkCategory Private -ErrorAction Stop
                        Write-Status "OK" "已将 '$($issue.Alias)' 改为 Private"
                    } catch {
                        Write-Status "ERROR" "修改失败: $_"
                    }
                } else {
                    Write-Status "SKIP" "跳过: $($issue.Alias)"
                }
            }
        } else {
            Write-Status "INFO" "修复需要管理员权限:"
            foreach ($issue in $profileIssues) {
                Write-Status "INFO" "  Set-NetConnectionProfile -InterfaceAlias '$($issue.Alias)' -NetworkCategory Private"
            }
        }
    } else {
        Add-LanResult "Network Profile" "PASS" "全部 Private/Domain"
    }

    # ── 4/7. Firewall Audit ──────────────────────────────────
    Write-Section "防火墙入站规则审计" "[4/7]"

    $fwIssues = @()
    try {
        # Check for Node.js block rules
        $fwRules = netsh advfirewall firewall show rule name=all dir=in 2>&1 | Out-String
        $blockRules = @()
        $currentRule = ""
        $isBlock = $false
        $isNode = $false

        foreach ($fwLine in $fwRules -split "`n") {
            if ($fwLine -match "^Rule Name:\s*(.+)$" -or $fwLine -match "^规则名称:\s*(.+)$") {
                if ($isBlock -and $isNode -and $currentRule) {
                    $blockRules += $currentRule
                }
                $currentRule = $Matches[1].Trim()
                $isBlock = $false
                $isNode = $false
            }
            if ($fwLine -match "Action:\s*Block" -or $fwLine -match "操作:\s*阻止") { $isBlock = $true }
            if ($fwLine -match "node" -or $currentRule -match "node") { $isNode = $true }
        }
        if ($isBlock -and $isNode -and $currentRule) {
            $blockRules += $currentRule
        }

        if ($blockRules.Count -gt 0) {
            foreach ($br in $blockRules) {
                Write-Status "ERROR" "Node.js 入站阻止规则: $br"
                $fwIssues += $br
            }
        } else {
            Write-Status "OK" "未检测到 Node.js 阻止规则"
        }

        # Check if lan-toolkit ports have allow rules
        $hasLanAllow = $false
        if ($fwRules -match "LAN" -and $fwRules -match "Allow") {
            $hasLanAllow = $true
            Write-Status "OK" "检测到 LAN 允许规则"
        }
    } catch {
        Write-Status "WARN" "防火墙检查失败: $_"
    }

    if ($fwIssues.Count -gt 0) {
        Add-LanResult "Firewall" "FAIL" "$($fwIssues.Count) 个阻止规则"

        if ($isAdmin) {
            if (Confirm-Action "为 Node.js LAN 通信创建允许规则?") {
                $portsToAllow = @(8789) + $LAN_TOOLKIT_PORTS[0..2]
                foreach ($port in $portsToAllow) {
                    try {
                        $ruleName = "Node.js LAN Allow TCP $port"
                        netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$port | Out-Null
                        Write-Status "OK" "已创建规则: $ruleName"
                    } catch {
                        Write-Status "ERROR" "创建规则失败 (端口 $port): $_"
                    }
                }
            }
        } else {
            Write-Status "INFO" "修复需要管理员权限:"
            Write-Status "INFO" "  netsh advfirewall firewall add rule name=`"Node.js LAN`" dir=in action=allow protocol=TCP localport=8789,18850"
        }
    } else {
        Add-LanResult "Firewall" "PASS" "无阻止规则"
    }

    # ── 5/7. Target Connectivity (peers.json or manual) ─────────
    Write-Section "目标设备连接测试" "[5/7]"

    $peersConfig = Get-PeersConfig
    if ($peersConfig) {
        Write-Status "INFO" "检测到 config\peers.json — 扫描预配置对端"
        Write-Status "INFO" "提示: 如需修改对端配置，编辑 config\peers.json"
        Invoke-PeerScan -PeersConfig $peersConfig
        Add-LanResult "Target Connect" "PASS" "peers.json 扫描完成"
    } else {
        Write-Status "INFO" "未找到 config\peers.json — 手动输入目标 IP"
        Write-Status "INFO" "提示: 复制 config\peers.example.json -> config\peers.json 可固化对端配置"
        $targetIP = $null
        $resp = Read-Host "      输入目标 IP (留空跳过)"
        if ($resp -and $resp -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
            $targetIP = $resp.Trim()
        }

        if ($targetIP) {
            # Subnet check
            if ($primaryLanIP) {
                $localSubnet  = ($primaryLanIP -split '\.')[0..2] -join '.'
                $targetSubnet = ($targetIP -split '\.')[0..2] -join '.'
                if ($localSubnet -ne $targetSubnet) {
                    Write-Status "WARN" "子网不匹配: 本机 $localSubnet.x vs 目标 $targetSubnet.x"
                } else {
                    Write-Status "OK" "同一子网: ${localSubnet}.0/24"
                }
            }

            # ICMP ping
            Write-Status "INFO" "Ping $targetIP ..."
            try {
                $pingResult2 = Test-Connection $targetIP -Count 2 -ErrorAction Stop
                $avgMs = ($pingResult2 | Measure-Object -Property ResponseTime -Average).Average
                Write-Status "OK" "Ping 成功: 平均 ${avgMs}ms"
            } catch {
                Write-Status "ERROR" "Ping 失败: $_"
            }

            # TCP probe on common ports
            $testPorts = @(8789, 18850, 19000, 3000, 5173, 8080)
            Write-Status "INFO" "TCP 端口探测: $($testPorts -join ', ')"
            foreach ($port in $testPorts) {
                if (Test-TcpPort -Ip $targetIP -Port $port -TimeoutMs 1000) {
                    Write-Status "OK" "  :$port 开放"
                }
            }

            Add-LanResult "Target Connect" "PASS" $targetIP
        } else {
            Write-Status "SKIP" "跳过目标设备测试"
            Add-LanResult "Target Connect" "INFO" "已跳过"
        }
    }

    # ── 6/7. Service Discovery (ARP) ─────────────────────────
    Write-Section "LAN 设备发现 (ARP)" "[6/7]"

    if ($primaryLanIP) {
        $subnet = ($primaryLanIP -split '\.')[0..2] -join '.'
        $arpOutput = arp -a 2>&1 | Out-String
        $arpPeers = @()

        foreach ($arpLine in $arpOutput -split "`n") {
            $arpPattern = "($subnet\.\d+)\s+"
            if ($arpLine -match $arpPattern -and ($arpLine -match 'dynamic' -or $arpLine -match '动态')) {
                $peerIP = $Matches[1].Trim()
                if ($peerIP -ne $primaryLanIP -and -not $peerIP.EndsWith(".255")) {
                    $arpPeers += $peerIP
                }
            }
        }

        if ($arpPeers.Count -gt 0) {
            Write-Status "OK" "发现 $($arpPeers.Count) 个 ARP 邻居"

            foreach ($peer in $arpPeers | Select-Object -First 10) {
                $openPorts = @()
                foreach ($lp in @(8789, 18850, 19000)) {
                    try {
                        $tc = New-Object System.Net.Sockets.TcpClient
                        $ar2 = $tc.BeginConnect($peer, $lp, $null, $null)
                        $ok2 = $ar2.AsyncWaitHandle.WaitOne(300, $false)
                        if ($ok2 -and $tc.Connected) {
                            $tc.EndConnect($ar2)
                            $openPorts += $lp
                        }
                        $tc.Close()
                    } catch { }
                }
                if ($openPorts.Count -gt 0) {
                    Write-Status "OK" "  $peer — LAN toolkit 端口: $($openPorts -join ', ')"
                } else {
                    Write-Status "INFO" "  $peer — 无 LAN toolkit 服务"
                }
            }
            Add-LanResult "ARP Discovery" "PASS" "$($arpPeers.Count) 设备"
        } else {
            Write-Status "INFO" "ARP 表无其他设备（尝试先 ping 目标设备）"
            Add-LanResult "ARP Discovery" "INFO" "无邻居"
        }
    } else {
        Write-Status "SKIP" "无 LAN IP，跳过 ARP 发现"
        Add-LanResult "ARP Discovery" "INFO" "跳过"
    }

    # ── 7/7. HTTP Proxy LAN Interference ─────────────────────
    Write-Section "HTTP 代理 LAN 干扰检测" "[7/7]"

    $proxyVarSet = $false
    $proxyValue = $null
    foreach ($pv in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY')) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'User') }
        if ($val) {
            $proxyVarSet = $true
            $proxyValue = $val
            break
        }
    }

    if ($proxyVarSet) {
        Write-Status "INFO" "检测到代理: $proxyValue"

        $noProxy = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
        if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "User") }
        if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("no_proxy", "Process") }
        if (-not $noProxy) { $noProxy = [System.Environment]::GetEnvironmentVariable("no_proxy", "User") }

        $lanExcluded = $false
        if ($noProxy) {
            if ($noProxy -match "192\.168" -or $noProxy -match "10\." -or $noProxy -match "\*" -or $noProxy -match "local") {
                $lanExcluded = $true
            }
        }

        if ($lanExcluded) {
            Write-Status "OK" "NO_PROXY 已排除 LAN: $noProxy"
            Add-LanResult "Proxy LAN" "PASS" "NO_PROXY 已配置"
        } else {
            Write-Status "ERROR" "NO_PROXY 未排除 LAN 段 — LAN 请求会走代理"
            if ($noProxy) { $noProxyDisplay = $noProxy } else { $noProxyDisplay = "(未设置)" }
            Write-Status "INFO" "  当前 NO_PROXY: $noProxyDisplay"
            Write-Status "INFO" "  建议修复:"
            Write-Status "INFO" "  PS: SetEnvironmentVariable('NO_PROXY', 'localhost,127.0.0.1,192.168.*,10.*', 'User')"
            Add-LanResult "Proxy LAN" "FAIL" "NO_PROXY 缺 LAN 段"

            if (Confirm-Action "自动设置 NO_PROXY 环境变量?" -DefaultYes $false) {
                $newNoProxy = "localhost,127.0.0.1,192.168.*,10.*,172.16.*"
                if ($noProxy) { $newNoProxy = "$noProxy,$newNoProxy" }
                [System.Environment]::SetEnvironmentVariable("NO_PROXY", $newNoProxy, "User")
                [System.Environment]::SetEnvironmentVariable("NO_PROXY", $newNoProxy, "Process")
                Write-Status "OK" "NO_PROXY 已设置: $newNoProxy"
            } else {
                Write-Status "SKIP" "跳过 NO_PROXY 设置"
            }
        }
    } else {
        Write-Status "OK" "未设置代理环境变量，LAN 通信不受干扰"
        Add-LanResult "Proxy LAN" "PASS" "无代理"
    }

    # ── Summary ──────────────────────────────────────────────
    Write-Host ""
    Write-Host "  ┌──────────────────────┬──────────┬────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │ 检查项               │ 状态     │ 详情                   │" -ForegroundColor Cyan
    Write-Host "  ├──────────────────────┼──────────┼────────────────────────┤" -ForegroundColor Cyan

    foreach ($r in $script:LanResults) {
        if ($r.Status -eq "PASS") { $icon = "OK" }
        elseif ($r.Status -eq "WARN") { $icon = "! " }
        elseif ($r.Status -eq "FAIL") { $icon = "!!" }
        else { $icon = "--" }

        if ($r.Status -eq "PASS") { $color = "Green" }
        elseif ($r.Status -eq "WARN") { $color = "Yellow" }
        elseif ($r.Status -eq "FAIL") { $color = "Red" }
        else { $color = "DarkGray" }

        $checkPad = $r.Check.PadRight(18)
        $statusPad = ("$icon $($r.Status)").PadRight(8)
        $detailPad = $r.Detail
        if ($detailPad.Length -gt 22) { $detailPad = $detailPad.Substring(0, 22) }
        $detailPad = $detailPad.PadRight(22)

        Write-Host "  │ " -ForegroundColor Cyan -NoNewline
        Write-Host $checkPad -NoNewline
        Write-Host " │ " -ForegroundColor Cyan -NoNewline
        Write-Host $statusPad -ForegroundColor $color -NoNewline
        Write-Host " │ " -ForegroundColor Cyan -NoNewline
        Write-Host $detailPad -NoNewline
        Write-Host " │" -ForegroundColor Cyan
    }

    Write-Host "  └──────────────────────┴──────────┴────────────────────────┘" -ForegroundColor Cyan

    $failCount = @($script:LanResults | Where-Object { $_.Status -eq "FAIL" }).Count
    $warnCount = @($script:LanResults | Where-Object { $_.Status -eq "WARN" }).Count

    Write-Host ""
    if ($failCount -eq 0 -and $warnCount -eq 0) {
        Write-Status "OK" "LAN 环境正常，跨设备连接应可用"
    } elseif ($failCount -eq 0) {
        Write-Status "WARN" "$warnCount 个警告，请关注 TUN 模式和代理配置"
    } else {
        Write-Status "ERROR" "$failCount 个问题需要修复"
        if (-not $isAdmin) {
            Write-Host ""
            Write-Status "INFO" "部分修复需要管理员权限。以管理员身份运行:"
            Write-Status "INFO" "  powershell -ExecutionPolicy Bypass -File Claude-Toolkit.ps1 -Mode lan"
        }
    }
}
