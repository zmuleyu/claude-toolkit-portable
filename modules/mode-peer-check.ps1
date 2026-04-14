# mode-peer-check.ps1 — Mode 8: A<->B Cross-Machine Communication Diagnostic
# Part of Claude Code Diagnostic & Repair Toolkit v7.3

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

function Get-PeersConfig {
    $toolkitRoot = Split-Path -Parent $PSScriptRoot
    $peersFile = Join-Path $toolkitRoot "config\peers.json"
    $exampleFile = Join-Path $toolkitRoot "config\peers.example.json"

    if (Test-Path $peersFile) {
        try {
            return (Get-Content $peersFile -Raw | ConvertFrom-Json)
        } catch {
            Write-Status "WARN" "peers.json 解析失败，使用默认配置"
        }
    }

    # Default: Machine B at 192.168.3.11
    Write-Status "INFO" "未找到 config\peers.json，使用内置默认配置 (B: 192.168.3.11)"
    Write-Status "INFO" "如需自定义，复制 config\peers.example.json -> config\peers.json"
    return [pscustomobject]@{
        peers = [pscustomobject]@{
            B = [pscustomobject]@{
                ip    = "192.168.3.11"
                label = "Machine B (AOC Dev)"
                ports = @(
                    @{ port = 22;    label = "SSH" }
                    @{ port = 3389;  label = "RDP" }
                    @{ port = 445;   label = "SMB" }
                    @{ port = 18850; label = "lan-toolkit preview" }
                    @{ port = 19001; label = "lan-toolkit send" }
                    @{ port = 8384;  label = "Syncthing" }
                    @{ port = 18766; label = "devmanager" }
                )
            }
        }
    }
}

function Invoke-PingTest {
    param([string]$Ip)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Ip, 2000)
        return [pscustomobject]@{
            Success    = ($reply.Status -eq "Success")
            RoundTrip  = $reply.RoundtripTime
            Status     = $reply.Status.ToString()
        }
    } catch {
        return [pscustomobject]@{ Success = $false; RoundTrip = -1; Status = $_.ToString() }
    }
}

function Get-LocalSubnet {
    $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Tunnel' -and $_.IPAddress -ne '127.0.0.1' }
    return $adapters | Select-Object -First 1
}

function Test-ClashLanIntercept {
    # Check if Clash TUN is enabled which might intercept LAN traffic
    $clashProc = Get-Process -Name $PROXY_PROC_NAMES -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $clashProc) { return [pscustomobject]@{ Running = $false; TunEnabled = $false; Mode = "N/A" } }

    $apiCfg = Find-ClashApi
    if (-not $apiCfg) { return [pscustomobject]@{ Running = $true; TunEnabled = $false; Mode = "API不可达" } }

    try {
        $tunConfig = Invoke-RestMethod "http://$($apiCfg.Host):$($apiCfg.Port)/tun" -TimeoutSec 3 -ErrorAction Stop
        $tunEnabled = ($tunConfig.enable -eq $true)
    } catch { $tunEnabled = $false }

    try {
        $proxyMode = (Invoke-RestMethod "http://$($apiCfg.Host):$($apiCfg.Port)/configs" -TimeoutSec 3 -ErrorAction Stop).mode
    } catch { $proxyMode = "未知" }

    return [pscustomobject]@{ Running = $true; TunEnabled = $tunEnabled; Mode = $proxyMode }
}

function Get-FirewallLanStatus {
    # Check if Windows Firewall might block outbound LAN connections
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $blockingProfiles = @($profiles | Where-Object { $_.DefaultOutboundAction -eq "Block" })
        return [pscustomobject]@{
            Checked = $true
            BlockingProfiles = $blockingProfiles.Name
            AnyBlocking = ($blockingProfiles.Count -gt 0)
        }
    } catch {
        return [pscustomobject]@{ Checked = $false; AnyBlocking = $false; BlockingProfiles = @() }
    }
}

function Invoke-PeerCheck {
    Write-Section "A<->B 跨机通信诊断" "[Mode 8]"

    # 1. Load peer config
    $config = Get-PeersConfig
    $peers = $config.peers

    # 2. Local environment
    Write-Host ""
    Write-Host "  ── 本机环境 ─────────────────────────────────────────" -ForegroundColor DarkGray
    $localAdapter = Get-LocalSubnet
    if ($localAdapter) {
        Write-Status "INFO" "本机 IP: $($localAdapter.IPAddress)/$($localAdapter.PrefixLength) (适配器: $($localAdapter.InterfaceAlias))"
    } else {
        Write-Status "WARN" "未检测到有效 IPv4 适配器"
    }

    # 3. Clash TUN check
    $clashState = Test-ClashLanIntercept
    if ($clashState.Running) {
        if ($clashState.TunEnabled) {
            Write-Status "WARN" "Clash TUN 已启用 (mode: $($clashState.Mode)) — TUN 可能拦截 LAN 流量"
        } else {
            Write-Status "OK"   "Clash 运行中 (mode: $($clashState.Mode))，TUN 未启用，LAN 流量不受影响"
        }
    } else {
        Write-Status "OK" "Clash/Mihomo 未运行，无 TUN 拦截风险"
    }

    # 4. Firewall check
    $fwStatus = Get-FirewallLanStatus
    if ($fwStatus.Checked) {
        if ($fwStatus.AnyBlocking) {
            Write-Status "WARN" "防火墙配置文件 [$($fwStatus.BlockingProfiles -join ', ')] 默认出站策略为 Block"
        } else {
            Write-Status "OK" "防火墙出站策略: 允许 (所有配置文件)"
        }
    } else {
        Write-Status "INFO" "防火墙状态检查跳过 (需管理员权限)"
    }

    # 5. Per-peer scan
    foreach ($peerName in ($peers.PSObject.Properties.Name)) {
        $peer = $peers.$peerName
        $ip = $peer.ip
        $label = if ($peer.PSObject.Properties["label"]) { $peer.label } else { $peerName }

        Write-Host ""
        Write-Host "  ── Peer: $label ($ip) ───────────────────────────" -ForegroundColor Cyan

        # Ping
        $pingResult = Invoke-PingTest $ip
        if ($pingResult.Success) {
            Write-Status "OK"   "Ping $ip : 成功 ($($pingResult.RoundTrip) ms)"
        } else {
            Write-Status "FAIL" "Ping $ip : 失败 ($($pingResult.Status))"
        }

        # Port scan
        $openCount = 0
        $portResults = @()
        foreach ($portDef in $peer.ports) {
            $portNum = if ($portDef -is [int]) { $portDef } else { [int]$portDef.port }
            $portLabel = if ($portDef -is [hashtable] -or ($portDef.PSObject.Properties["label"])) { $portDef.label } else { "port $portNum" }
            $open = Test-TcpPort -Ip $ip -Port $portNum -TimeoutMs 2000
            if ($open) { $openCount++ }
            $portResults += [pscustomobject]@{ Port = $portNum; Label = $portLabel; Open = $open }
        }

        # Print port table
        Write-Host ""
        Write-Host ("  {0,-6} {1,-28} {2}" -f "端口", "用途", "状态") -ForegroundColor DarkGray
        Write-Host ("  {0}" -f ("-" * 48)) -ForegroundColor DarkGray
        foreach ($r in $portResults) {
            $statusTxt = if ($r.Open) { "OPEN  ✔" } else { "closed" }
            $color = if ($r.Open) { "Green" } else { "DarkGray" }
            Write-Host ("  {0,-6} {1,-28} {2}" -f $r.Port, $r.Label, $statusTxt) -ForegroundColor $color
        }

        # 6. Root cause diagnosis
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
            Write-Host ""
            Write-Host "  ── 建议行动 ─────────────────────────────────────" -ForegroundColor Cyan
            Write-Host "  在 Machine $peerName 上执行:" -ForegroundColor White
            Write-Host "  1. 安装并启动 lan-toolkit: D:\tools\lan-toolkit\" -ForegroundColor White
            Write-Host "  2. 或手动开放 RDP: 系统属性 -> 远程 -> 允许远程连接" -ForegroundColor White
            Write-Host "  3. 防火墙放行入站: New-NetFirewallRule -DisplayName 'Claude LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 18850,19001,22" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "  安装 Claude-Toolkit 到 Machine $peerName (PowerShell one-liner):" -ForegroundColor Cyan
            Write-Host "  iwr https://raw.githubusercontent.com/zmuleyu/claude-toolkit-portable/master/scripts/bootstrap-remote.ps1 -UseBasicParsing | iex" -ForegroundColor Yellow
        } else {
            Write-Status "OK" "$openCount / $($portResults.Count) 个端口可达"
        }
    }

    Write-Host ""
    Write-Status "INFO" "诊断完成。如需修复本机 Clash TUN 拦截，请在 Clash Verge 中禁用 TUN 模式后重试"
}
