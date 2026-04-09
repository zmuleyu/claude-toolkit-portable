# mode-health.ps1 — Mode 1: Health Check (read-only diagnostic)
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

function Invoke-HealthCheck {
    $results = @()

    # ── 1. OAuth Token Status ────────────────────────────────
    Write-Section "检查 OAuth 令牌状态..." "[1/12]"
    $tokenStatus = "ERROR"; $tokenDetail = "未登录"
    if (Test-Path $CREDENTIALS_FILE) {
        $creds = Read-JsonSafe $CREDENTIALS_FILE
        if ($creds -and $creds.claudeAiOauth) {
            $oauth = $creds.claudeAiOauth
            $expiresAt = $null
            if ($oauth.expiresAt) {
                $expiresAt = [long]$oauth.expiresAt
                $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $remainMs = $expiresAt - $nowMs
                $remainHours = [math]::Round($remainMs / 3600000, 1)

                if ($remainMs -le 0) {
                    $tokenStatus = "ERROR"
                    $tokenDetail = "已过期"
                    Write-Status "ERROR" "OAuth 令牌已过期 (过期于 $remainHours 小时前)"
                } elseif ($remainHours -lt 2) {
                    $tokenStatus = "WARN"
                    $tokenDetail = "即将过期 (${remainHours}h)"
                    Write-Status "WARN" "OAuth 令牌即将过期: 剩余 $remainHours 小时"
                } else {
                    $tokenStatus = "OK"
                    $tokenDetail = "有效 (${remainHours}h)"
                    Write-Status "OK" "OAuth 令牌有效: 剩余 $remainHours 小时"
                }
            } else {
                $tokenStatus = "WARN"
                $tokenDetail = "无过期时间"
                Write-Status "WARN" "OAuth 令牌存在但无 expiresAt 字段"
            }

            if ($oauth.refreshToken) {
                Write-Status "OK" "Refresh token 存在"
            } else {
                Write-Status "WARN" "无 refresh token"
            }
        } else {
            Write-Status "ERROR" "凭证文件存在但无 claudeAiOauth 字段"
        }
    } else {
        Write-Status "ERROR" "凭证文件不存在: $CREDENTIALS_FILE"
    }
    $results += @{ Name = "OAuth 令牌"; Status = $tokenStatus; Detail = $tokenDetail }

    # ── 2. Claude CLI ────────────────────────────────────────
    Write-Section "检查 Claude CLI..." "[2/12]"
    $cliVer = Get-ClaudeVersion
    if ($cliVer) {
        Write-Status "OK" "Claude CLI 版本: $cliVer"
        $cliCmd = Get-Command claude -ErrorAction SilentlyContinue
        if ($cliCmd) {
            Write-Status "INFO" "路径: $($cliCmd.Source)"
        }
        $authInfo = Get-ClaudeAuthStatusInfo
        if ($authInfo -and $authInfo.loggedIn) {
            Write-Status "INFO" "当前账号: $($authInfo.email)"
            Write-Status "INFO" "当前组织: $($authInfo.orgName)"
            Write-Status "INFO" "登录方式: $($authInfo.authMethod)"
        }
        $probe = Invoke-ClaudeCapabilityProbe
        switch ($probe.Status) {
            "ok" {
                Write-Status "OK" "实时推理探针通过"
                $results += @{ Name = "Claude CLI"; Status = "OK"; Detail = $cliVer }
            }
            "permission_error_org_access" {
                Write-Status "ERROR" "实时推理仍被组织权限拒绝"
                $results += @{ Name = "Claude CLI"; Status = "ERROR"; Detail = "已登录但无推理权限" }
            }
            "credit_low" {
                Write-Status "ERROR" "实时推理失败: 余额不足"
                $results += @{ Name = "Claude CLI"; Status = "ERROR"; Detail = "余额不足" }
            }
            "network_error" {
                Write-Status "ERROR" "实时推理失败: 网络/TLS 问题"
                $results += @{ Name = "Claude CLI"; Status = "ERROR"; Detail = "网络错误" }
            }
            default {
                Write-Status "WARN" "实时推理探针未得到成功结果"
                $results += @{ Name = "Claude CLI"; Status = "WARN"; Detail = $cliVer }
            }
        }
    } else {
        Write-Status "ERROR" "Claude CLI 未找到 (不在 PATH 中)"
        Write-Status "INFO" "安装: npm install -g @anthropic-ai/claude-code"
        $results += @{ Name = "Claude CLI"; Status = "ERROR"; Detail = "未安装" }
    }

    # ── 3. VS Code Extension ─────────────────────────────────
    Write-Section "检查 VS Code 扩展..." "[3/12]"
    $extVer = Get-VscodeExtVersion
    if ($extVer) {
        Write-Status "OK" "Claude Code 扩展版本: $extVer"
        $vscodeState = Get-VscodeClaudeState
        if ($vscodeState) {
            Write-Status "INFO" "检测到 VS Code 扩展持久化状态键: Anthropic.claude-code"
        }

        $accountInfo = Get-ClaudeAccountInfo
        if ($accountInfo) {
            Write-Status "INFO" "本地组织: $($accountInfo.OrganizationName)"
            if ($accountInfo.StateFileLastWriteTime) {
                Write-Status "INFO" "最近认证写入: $($accountInfo.StateFileLastWriteTime)"
            }
        }

        $logStatus = Get-VscodeClaudeLogStatus
        $loopInfo = Get-VscodeLoginLoopStatus
        if ($loopInfo -and $loopInfo.IsLoop) {
            Write-Status "ERROR" "检测到 403 -> 重新登录 -> 再次 403 的登录循环"
            Write-Status "INFO" "日志: $($loopInfo.LogFile)"
            Write-Status "INFO" "首次 403: $($loopInfo.First403)"
            Write-Status "INFO" "重新登录: $($loopInfo.LoginTime)"
            Write-Status "INFO" "再次 403: $($loopInfo.Second403)"
            $results += @{ Name = "VS Code 扩展"; Status = "ERROR"; Detail = "登录循环 / $extVer" }
        } elseif ($logStatus) {
            switch ($logStatus.Status) {
                "current_403" {
                    Write-Status "ERROR" "最近扩展日志存在组织权限 403: $($logStatus.Latest403Path)"
                    $results += @{ Name = "VS Code 扩展"; Status = "ERROR"; Detail = "当前 403 / $extVer" }
                }
                "historical_403" {
                    Write-Status "WARN" "检测到历史组织权限 403，但之后已重新登录"
                    Write-Status "INFO" "403 时间: $($logStatus.Latest403Time)"
                    Write-Status "INFO" "最近登录: $($logStatus.LatestLoginTime)"
                    $results += @{ Name = "VS Code 扩展"; Status = "WARN"; Detail = "历史 403 / $extVer" }
                }
                default {
                    Write-Status "OK" "最近扩展日志未发现组织权限 403"
                    $results += @{ Name = "VS Code 扩展"; Status = "OK"; Detail = $extVer }
                }
            }
        } else {
            Write-Status "OK" "未找到 Claude VS Code 扩展日志"
            $results += @{ Name = "VS Code 扩展"; Status = "OK"; Detail = $extVer }
        }
    } else {
        Write-Status "WARN" "Claude Code VS Code 扩展未安装"
        $results += @{ Name = "VS Code 扩展"; Status = "WARN"; Detail = "未安装" }
    }

    # ── 4. Quick Network Test ────────────────────────────────
    Write-Section "快速网络连接测试..." "[4/12]"
    $netOk = 0; $netFail = 0
    foreach ($ep in $TEST_ENDPOINTS) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            [System.Net.Dns]::GetHostEntry($ep.Host) | Out-Null
            $sw.Stop()
            $dnsMs = $sw.ElapsedMilliseconds
            Write-Status "OK" "$($ep.Name) DNS: ${dnsMs}ms"
            $netOk++
        } catch {
            Write-Status "ERROR" "$($ep.Name) DNS: 解析失败"
            $netFail++
        }
    }
    if ($netFail -eq 0) {
        $results += @{ Name = "网络连接"; Status = "OK"; Detail = "全部通过" }
    } elseif ($netOk -gt 0) {
        $results += @{ Name = "网络连接"; Status = "WARN"; Detail = "${netFail}个失败" }
    } else {
        $results += @{ Name = "网络连接"; Status = "ERROR"; Detail = "全部失败" }
    }

    # ── 5. MCP Server Auth Status ────────────────────────────
    Write-Section "检查 MCP 服务器认证状态..." "[5/12]"
    if (Test-Path $MCP_AUTH_CACHE) {
        $mcpCache = Read-JsonSafe $MCP_AUTH_CACHE
        if ($mcpCache) {
            $needAuth = @()
            $mcpCache.PSObject.Properties | ForEach-Object {
                $needAuth += $_.Name
            }
            if ($needAuth.Count -gt 0) {
                Write-Status "WARN" "以下 MCP 服务器需要重新认证:"
                foreach ($s in $needAuth) {
                    Write-Status "INFO" "  - $s"
                }
                $results += @{ Name = "MCP 状态"; Status = "WARN"; Detail = "$($needAuth.Count)个需认证" }
            } else {
                Write-Status "OK" "所有 MCP 服务器认证正常"
                $results += @{ Name = "MCP 状态"; Status = "OK"; Detail = "正常" }
            }
        } else {
            Write-Status "OK" "无 MCP 认证缓存 (正常)"
            $results += @{ Name = "MCP 状态"; Status = "OK"; Detail = "正常" }
        }
    } else {
        Write-Status "OK" "无 MCP 认证缓存文件 (正常)"
        $results += @{ Name = "MCP 状态"; Status = "OK"; Detail = "正常" }
    }

    # ── 6. Disk Usage ────────────────────────────────────────
    Write-Section "磁盘使用统计..." "[6/12]"
    $totalBytes = 0
    $diskItems = @(
        @{ Label = "projects/";       Path = $PROJECTS_DIR },
        @{ Label = "plugins/";        Path = $PLUGINS_DIR },
        @{ Label = "file-history/";   Path = $FILE_HISTORY_DIR },
        @{ Label = "shell-snapshots/";Path = $SHELL_SNAP_DIR },
        @{ Label = "debug/";          Path = $DEBUG_DIR },
        @{ Label = "plans/";          Path = "$CLAUDE_HOME\plans" },
        @{ Label = "telemetry/";      Path = $TELEMETRY_DIR },
        @{ Label = "data/";           Path = $DATA_DIR },
        @{ Label = "session-env/";    Path = $SESSION_ENV_DIR },
        @{ Label = "cache/";          Path = $CACHE_DIR }
    )

    Write-Host ""
    Write-Host ("      {0,-22} {1,10} {2,8}" -f "目录", "大小", "文件数") -ForegroundColor DarkGray
    Write-Host ("      {0,-22} {1,10} {2,8}" -f ("─" * 22), ("─" * 10), ("─" * 8)) -ForegroundColor DarkGray

    foreach ($item in $diskItems) {
        $size = Get-DirSize $item.Path
        $totalBytes += $size.Bytes
        $color = if ($size.Bytes -gt 500MB) { "Red" }
                 elseif ($size.Bytes -gt 50MB) { "Yellow" }
                 else { "Green" }
        Write-Host ("      {0,-22} {1,10} {2,8}" -f $item.Label, $size.Display, $size.FileCount) -ForegroundColor $color
    }

    $totalDisplay = if ($totalBytes -ge 1GB) { "{0:N2} GB" -f ($totalBytes / 1GB) }
                    elseif ($totalBytes -ge 1MB) { "{0:N1} MB" -f ($totalBytes / 1MB) }
                    else { "$totalBytes B" }
    Write-Host ""
    Write-Host "      总计: $totalDisplay" -ForegroundColor White

    $diskStatus = if ($totalBytes -gt 5GB) { "WARN" } else { "OK" }
    $results += @{ Name = "磁盘使用"; Status = $diskStatus; Detail = $totalDisplay }

    # ── 7. Stale IDE Lock Files ──────────────────────────────
    Write-Section "检查 IDE 锁文件..." "[7/12]"
    $staleLocks = 0
    if (Test-Path $IDE_LOCK_DIR) {
        $lockFiles = Get-ChildItem $IDE_LOCK_DIR -Filter "*.lock" -ErrorAction SilentlyContinue
        foreach ($lf in $lockFiles) {
            try {
                $lockRaw = Get-Content $lf.FullName -Raw
                $lockContent = $lockRaw | ConvertFrom-Json
                $lockPid = $lockContent.pid
                if ($lockPid -and -not (Test-ProcessRunning $lockPid)) {
                    Write-Status "WARN" "过期锁文件: $($lf.Name) (PID $lockPid 已终止)"
                    $staleLocks++
                } elseif ($lockPid) {
                    Write-Status "OK" "活跃锁文件: $($lf.Name) (PID $lockPid)"
                } else {
                    Write-Status "INFO" "锁文件无 PID: $($lf.Name)"
                }
            } catch {
                Write-Status "INFO" "无法解析锁文件: $($lf.Name)"
            }
        }
        if ($staleLocks -eq 0 -and $lockFiles.Count -eq 0) {
            Write-Status "OK" "无锁文件"
        }
    } else {
        Write-Status "OK" "无 IDE 锁文件目录"
    }
    if ($staleLocks -gt 0) {
        $results += @{ Name = "IDE 锁文件"; Status = "WARN"; Detail = "${staleLocks}个过期" }
    } else {
        $results += @{ Name = "IDE 锁文件"; Status = "OK"; Detail = "正常" }
    }

    # ── 8. Environment Variables ─────────────────────────────
    Write-Section "检查环境变量..." "[8/12]"
    $badVars = @()
    $proxyVars = @()
    foreach ($v in $BAD_ENV_KEYS) {
        $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($v, 'Process') }
        if ($val) {
            $masked = if ($val -match "^sk-") { "sk-***" + $val.Substring([math]::Max(0, $val.Length - 4)) } else { $val }
            Write-Status "ERROR" "$v = $masked"
            $badVars += $v
        }
    }
    foreach ($v in $PROXY_ENV_VARS) {
        $val = [System.Environment]::GetEnvironmentVariable($v, 'User')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($v, 'Process') }
        if ($val) {
            Write-Status "INFO" "$v = $val"
            $proxyVars += $v
        }
    }
    if ($badVars.Count -gt 0) {
        $results += @{ Name = "环境变量"; Status = "ERROR"; Detail = "$($badVars.Count)个异常" }
    } elseif ($proxyVars.Count -gt 0) {
        Write-Status "OK" "仅检测到代理变量 (正常)"
        $results += @{ Name = "环境变量"; Status = "OK"; Detail = "正常" }
    } else {
        Write-Status "OK" "环境变量干净"
        $results += @{ Name = "环境变量"; Status = "OK"; Detail = "干净" }
    }

    # ── 9. VS Code Settings Audit ────────────────────────────
    Write-Section "审计 VS Code 设置..." "[9/12]"
    $vsIssues = 0
    if (Test-Path $VSCODE_SETTINGS) {
        $vsContent = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8

        # Check [1m] suffix
        if ($vsContent -match '"claudeCode\.selectedModel"\s*:\s*"([^"]*\[1m\][^"]*)"') {
            Write-Status "ERROR" "模型含 [1m] 后缀: $($Matches[1]) (导致 429 错误)"
            $vsIssues++
        } else {
            $modelMatch = [regex]::Match($vsContent, '"claudeCode\.selectedModel"\s*:\s*"([^"]*)"')
            if ($modelMatch.Success) {
                Write-Status "OK" "模型: $($modelMatch.Groups[1].Value)"
            } else {
                Write-Status "OK" "使用默认模型"
            }
        }

        # Check disableLoginPrompt
        if ($vsContent -match '"claudeCode\.disableLoginPrompt"\s*:\s*true') {
            Write-Status "ERROR" "disableLoginPrompt = true (阻止重新登录)"
            $vsIssues++
        } else {
            Write-Status "OK" "disableLoginPrompt 未阻塞"
        }

        # Check proxy port consistency
        $portMatches = [regex]::Matches($vsContent, ':\s*(\d{4,5})\s*["/]')
        $ports = @($portMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($ports.Count -gt 1) {
            Write-Status "WARN" "检测到多个代理端口: $($ports -join ', ')"
            $vsIssues++
        } elseif ($ports.Count -eq 1) {
            Write-Status "OK" "代理端口一致: $($ports[0])"
        }
    } else {
        Write-Status "SKIP" "VS Code settings.json 未找到"
    }
    if ($vsIssues -gt 0) {
        $results += @{ Name = "VS Code 设置"; Status = "ERROR"; Detail = "${vsIssues}个问题" }
    } else {
        $results += @{ Name = "VS Code 设置"; Status = "OK"; Detail = "正常" }
    }

    # ── 10. LAN Connectivity Quick Check ─────────────────────
    Write-Section "LAN 连接快速检查..." "[10/12]"
    $ipconfigOutput = ipconfig 2>&1 | Out-String
    $localIPs = @()
    $currentAdapter = ""
    foreach ($line in $ipconfigOutput -split "`n") {
        if ($line -match "^(\S.+):$") { $currentAdapter = $Matches[1].Trim() }
        if ($line -match "IPv4.*?:\s*([\d.]+)") {
            $localIPs += @{ IP = $Matches[1].Trim(); Adapter = $currentAdapter }
        }
    }

    $tunDetected = $false
    $primaryLanIP = $null
    foreach ($entry in $localIPs) {
        $ip = $entry.IP
        $isVirtual = $false
        foreach ($prefix in $VIRTUAL_ADAPTER_PREFIXES) {
            if ($ip.StartsWith($prefix)) { $isVirtual = $true; break }
        }
        if ($ip.StartsWith($TUN_IP_PREFIX)) {
            Write-Status "WARN" "TUN 接口: $ip ($($entry.Adapter)) — Clash TUN 模式激活，LAN 可能不可达"
            $tunDetected = $true
        } elseif ($isVirtual) {
            Write-Status "INFO" "虚拟适配器: $ip ($($entry.Adapter)) — 已跳过"
        } else {
            Write-Status "OK" "LAN IP: $ip ($($entry.Adapter))"
            if (-not $primaryLanIP -and $ip.StartsWith("192.168.")) { $primaryLanIP = $ip }
            if (-not $primaryLanIP -and $ip.StartsWith("10.")) { $primaryLanIP = $ip }
        }
    }
    if (-not $primaryLanIP -and $localIPs.Count -gt 0) {
        $primaryLanIP = ($localIPs | Where-Object { -not $_.IP.StartsWith($TUN_IP_PREFIX) } | Select-Object -First 1).IP
    }
    if ($primaryLanIP) {
        Write-Status "INFO" "主 LAN IP: $primaryLanIP"
    }
    if ($tunDetected) {
        $results += @{ Name = "LAN 连接"; Status = "WARN"; Detail = "TUN 模式" }
    } elseif ($primaryLanIP) {
        $results += @{ Name = "LAN 连接"; Status = "OK"; Detail = $primaryLanIP }
    } else {
        $results += @{ Name = "LAN 连接"; Status = "ERROR"; Detail = "无 LAN IP" }
    }

    # ── 11. Proxy Port Consistency ───────────────────────────
    Write-Section "代理端口一致性检查..." "[11/12]"
    $portSources = @()

    # Source: environment variables
    foreach ($pv in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')) {
        $val = [System.Environment]::GetEnvironmentVariable($pv, 'User')
        if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($pv, 'Process') }
        if ($val -and $val -match ':(\d{4,5})') {
            $portSources += @{ Source = "ENV $pv"; Port = $Matches[1] }
        }
    }

    # Source: VS Code http.proxy
    if (Test-Path $VSCODE_SETTINGS) {
        $vsRaw = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8
        $vsPMatch = [regex]::Match($vsRaw, '"http\.proxy"\s*:\s*"[^"]*:(\d{4,5})"')
        if ($vsPMatch.Success) {
            $portSources += @{ Source = "VS Code http.proxy"; Port = $vsPMatch.Groups[1].Value }
        }
    }

    # Source: System proxy registry
    $proxyReg = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($proxyReg -and $proxyReg.ProxyEnable -and $proxyReg.ProxyServer -and $proxyReg.ProxyServer -match ':(\d{4,5})') {
        $portSources += @{ Source = "系统代理"; Port = $Matches[1] }
    }

    # Source: Clash API
    $clashProc = Get-Process -Name $PROXY_PROC_NAMES -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($clashProc) {
        $apiCfg = Get-ClashApiConfig
        if ($apiCfg.MixedPort) {
            $portSources += @{ Source = "Clash mixed-port"; Port = $apiCfg.MixedPort }
        }
    }

    if ($portSources.Count -gt 0) {
        $uniquePorts = @($portSources | ForEach-Object { $_.Port } | Sort-Object -Unique)
        foreach ($ps in $portSources) {
            Write-Status "INFO" "$($ps.Source): 端口 $($ps.Port)"
        }
        if ($uniquePorts.Count -eq 1) {
            Write-Status "OK" "所有来源代理端口一致: $($uniquePorts[0])"
            $results += @{ Name = "代理端口"; Status = "OK"; Detail = "一致: $($uniquePorts[0])" }
        } else {
            Write-Status "ERROR" "端口不一致: $($uniquePorts -join ', ')"
            $results += @{ Name = "代理端口"; Status = "ERROR"; Detail = "不一致" }
        }
    } else {
        Write-Status "OK" "未配置代理端口"
        $results += @{ Name = "代理端口"; Status = "OK"; Detail = "未配置" }
    }

    # AI provider fake-IP filter sub-check (Anthropic + OpenAI — both use SSE streams)
    if (Get-Command -Name Test-AnthropicFakeIpFilter -ErrorAction SilentlyContinue) {
        $healthFakeIp = Test-AnthropicFakeIpFilter
        if ($healthFakeIp.Pass) {
            Write-Status "OK" "dns_config.yaml fake-ip-filter: all 7 AI provider entries present"
            $results += @{ Name = "Fake-IP Filter"; Status = "OK"; Detail = "Anthropic + OpenAI excluded from fake-IP" }
        } else {
            Write-Status "WARN" "dns_config.yaml fake-ip-filter missing: $($healthFakeIp.Missing -join ', ')"
            Write-Status "INFO" "Run -Mode network to auto-patch, or run Run-Auth-Recovery.ps1"
            $results += @{ Name = "Fake-IP Filter"; Status = "WARN"; Detail = $healthFakeIp.Reason }
        }
    }

    # ── 12. Claude Code Desktop App ──────────────────────────
    Write-Section "检查 Claude Code 桌面应用..." "[12/12]"
    $desktopInstalled = $false
    $desktopPath = $null
    foreach ($dp in $CLAUDE_DESKTOP_PATHS) {
        if (Test-Path $dp) {
            $desktopInstalled = $true
            $desktopPath = $dp
            break
        }
    }

    if ($desktopInstalled) {
        Write-Status "OK" "Claude Desktop 已安装: $desktopPath"
        $desktopProcs = Get-Process -Name $CLAUDE_CODE_DESKTOP_PROC -ErrorAction SilentlyContinue
        if ($desktopProcs) {
            Write-Status "OK" "桌面应用运行中 ($($desktopProcs.Count) 个进程)"
        } else {
            Write-Status "INFO" "桌面应用未运行"
        }
        $results += @{ Name = "Claude Desktop"; Status = "OK"; Detail = "已安装" }
    } else {
        Write-Status "INFO" "Claude Desktop 未安装"
        $results += @{ Name = "Claude Desktop"; Status = "INFO"; Detail = "未安装" }
    }

    # ── Summary Dashboard ────────────────────────────────────
    Write-Host ""
    Write-Host "  ┌──────────────────────┬──────────────────┐" -ForegroundColor Cyan
    Write-Host "  │ 检查项目             │ 状态             │" -ForegroundColor Cyan
    Write-Host "  ├──────────────────────┼──────────────────┤" -ForegroundColor Cyan

    foreach ($r in $results) {
        $icon = switch ($r.Status) {
            "OK"    { "OK" }
            "WARN"  { "! " }
            "ERROR" { "!!" }
            "INFO"  { "i " }
        }
        $color = switch ($r.Status) {
            "OK"    { "Green" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            "INFO"  { "DarkGray" }
        }
        $namePad  = $r.Name.PadRight(18)
        $detPad   = ("$icon $($r.Detail)").PadRight(16)
        Write-Host "  │ " -ForegroundColor Cyan -NoNewline
        Write-Host $namePad -NoNewline
        Write-Host " │ " -ForegroundColor Cyan -NoNewline
        Write-Host $detPad -ForegroundColor $color -NoNewline
        Write-Host " │" -ForegroundColor Cyan
    }

    Write-Host "  └──────────────────────┴──────────────────┘" -ForegroundColor Cyan

    # Quick recommendations
    $errors = @($results | Where-Object { $_.Status -eq "ERROR" })
    $warns  = @($results | Where-Object { $_.Status -eq "WARN" })
    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  建议操作:" -ForegroundColor Red
        foreach ($e in $errors) {
            switch ($e.Name) {
                "OAuth 令牌"   { Write-Host "    → 运行模式 2 (认证重置) 重新登录" -ForegroundColor White }
                "Claude CLI"   { Write-Host "    → 若已登录仍报无权限，请停止重复登录并导出支持证据包" -ForegroundColor White }
                "环境变量"     { Write-Host "    → 运行模式 5 (设置重置) 清除异常变量" -ForegroundColor White }
                "VS Code 设置" { Write-Host "    → 运行模式 5 (设置重置) 修复配置问题" -ForegroundColor White }
                "网络连接"     { Write-Host "    → 运行模式 4 (网络诊断) 详细排查" -ForegroundColor White }
                "LAN 连接"     { Write-Host "    → 运行模式 6 (LAN 诊断) 跨设备排查" -ForegroundColor White }
                "代理端口"     { Write-Host "    → 运行模式 5 (设置重置) 统一代理端口配置" -ForegroundColor White }
                "VS Code 扩展" { Write-Host "    → 若检测到登录循环，请停止网页登录重试并导出支持证据包" -ForegroundColor White }
            }
        }
    } elseif ($warns.Count -gt 0) {
        Write-Host ""
        Write-Host "  检测到 $($warns.Count) 个警告，但不影响基本使用。" -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "  所有检查通过，Claude Code 状态健康。" -ForegroundColor Green
    }
}
