# mode-settings.ps1 — Mode 5: Settings Reset / Restore Defaults
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

function Invoke-SettingsReset {
    Write-Host ""
    Write-Host "  设置重置将按类别逐项操作，每步需确认。" -ForegroundColor DarkGray
    Write-Host "  所有修改前自动创建备份。" -ForegroundColor DarkGray
    Write-Host ""

    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $backupRoot = Join-Path $BACKUP_DIR $timestamp

    # ── 1. VS Code Settings ──────────────────────────────────
    Write-Section "VS Code Claude 设置修复" "[1/7]"

    if (Test-Path $VSCODE_SETTINGS) {
        $vsContent = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8
        $vsModified = $false
        $backupDone = $false

        # Check selectedModel [1m] suffix
        if ($vsContent -match '"claudeCode\.selectedModel"\s*:\s*"([^"]*\[1m\][^"]*)"') {
            $oldModel = $Matches[1]
            $newModel = $oldModel -replace '\[1m\]', ''
            Write-Status "ERROR" "检测到: selectedModel = $oldModel"
            if (Confirm-Action "修复模型为 $newModel ?") {
                if (-not $backupDone) {
                    if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                    Copy-Item $VSCODE_SETTINGS (Join-Path $backupRoot "vscode-settings.json") -Force
                    Write-Status "INFO" "备份: $backupRoot\vscode-settings.json"
                    $backupDone = $true
                }
                $vsContent = $vsContent -replace """claudeCode\.selectedModel""\s*:\s*""[^""]*\[1m\][^""]*""", """claudeCode.selectedModel"": ""$newModel"""
                $vsModified = $true
                Write-Status "OK" "selectedModel -> $newModel"
            }
        } else {
            Write-Status "OK" "selectedModel 正常"
        }

        # Check disableLoginPrompt
        if ($vsContent -match '"claudeCode\.disableLoginPrompt"\s*:\s*true') {
            Write-Status "ERROR" "检测到: disableLoginPrompt = true"
            if (Confirm-Action "修复为 false ?") {
                if (-not $backupDone) {
                    if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                    Copy-Item $VSCODE_SETTINGS (Join-Path $backupRoot "vscode-settings.json") -Force
                    $backupDone = $true
                }
                $vsContent = $vsContent -replace '"claudeCode\.disableLoginPrompt"\s*:\s*true', '"claudeCode.disableLoginPrompt": false'
                $vsModified = $true
                Write-Status "OK" "disableLoginPrompt -> false"
            }
        } else {
            Write-Status "OK" "disableLoginPrompt 正常"
        }

        # Optional: clear proxy settings
        $hasProxy = ($vsContent -match '"claudeCode\.environmentVariables"' -or $vsContent -match '"http\.proxy"')
        if ($hasProxy) {
            Write-Host ""
            Write-Status "INFO" "检测到代理配置 (claudeCode.environmentVariables / http.proxy)"
            if (Confirm-Action "是否清除代理配置? (如不确定请选 No)" -DefaultYes $false) {
                if (-not $backupDone) {
                    if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                    Copy-Item $VSCODE_SETTINGS (Join-Path $backupRoot "vscode-settings.json") -Force
                    $backupDone = $true
                }
                # Remove claudeCode.environmentVariables array
                $vsContent = $vsContent -replace ',?\s*"claudeCode\.environmentVariables"\s*:\s*\[[\s\S]*?\]', ''
                # Remove http.proxy
                $vsContent = $vsContent -replace ',?\s*"http\.proxy"\s*:\s*"[^"]*"', ''
                # Clean trailing commas
                $vsContent = $vsContent -replace ',(\s*[}\]])', '$1'
                $vsModified = $true
                Write-Status "OK" "代理配置已清除"
            } else {
                Write-Status "SKIP" "保留代理配置"
            }
        }

        # Check Codex WSL setting (causes OAuth failure on Windows 10)
        if ($vsContent -match '"chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*true') {
            Write-Host ""
            Write-Status "ERROR" "检测到: chatgpt.runCodexInWindowsSubsystemForLinux = true"
            Write-Status "INFO"  "此设置导致 Codex 在 WSL2 内启动，OAuth 回调被网络隔离阻断"
            if (Confirm-Action "修复为 false ?" -DefaultYes $true) {
                if (-not $backupDone) {
                    if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                    Copy-Item $VSCODE_SETTINGS (Join-Path $backupRoot "vscode-settings.json") -Force
                    $backupDone = $true
                }
                $vsContent = $vsContent -replace '"chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*true', '"chatgpt.runCodexInWindowsSubsystemForLinux": false'
                $vsModified = $true
                Write-Status "OK" "runCodexInWindowsSubsystemForLinux -> false"
            }
        } else {
            Write-Status "OK" "Codex WSL 设置正常"
        }

        if ($vsModified) {
            $vsContent | Set-Content $VSCODE_SETTINGS -Encoding UTF8
            Write-Status "OK" "VS Code settings.json 已更新"
        }
    } else {
        Write-Status "SKIP" "VS Code settings.json 未找到"
    }

    # ── 2. Global settings.json ──────────────────────────────
    Write-Section "全局 Claude 设置 (~/.claude/settings.json)" "[2/7]"

    if (Test-Path $SETTINGS_FILE) {
        $cfg = Read-JsonSafe $SETTINGS_FILE
        if ($cfg) {
            $modified = $false

            # Check env block for ANTHROPIC_* keys
            if ($cfg.env) {
                $badKeys = @()
                $cfg.env.PSObject.Properties | ForEach-Object {
                    if ($_.Name -match "^ANTHROPIC_" -or $_.Name -in @('apiBaseUrl','authToken')) {
                        $badKeys += $_.Name
                    }
                }
                if ($badKeys.Count -gt 0) {
                    Write-Status "WARN" "env 块中检测到第三方配置键: $($badKeys -join ', ')"
                    if (Confirm-Action "清除这些键? (保留 CLAUDE_* 和其他自定义键)") {
                        foreach ($k in $badKeys) {
                            $cfg.env.PSObject.Properties.Remove($k)
                        }
                        $modified = $true
                        Write-Status "OK" "已清除 $($badKeys.Count) 个异常键"
                    }
                } else {
                    Write-Status "OK" "env 块正常"
                }
            }

            # Show what will be PRESERVED
            Write-Host ""
            Write-Status "INFO" "以下配置将被保留 (不会修改):"
            if ($cfg.hooks)          { Write-Status "INFO" "  hooks: $(($cfg.hooks.PSObject.Properties).Count) 个钩子类型" }
            if ($cfg.permissions)    { Write-Status "INFO" "  permissions: 已配置" }
            if ($cfg.enabledPlugins) { Write-Status "INFO" "  enabledPlugins: $(($cfg.enabledPlugins.PSObject.Properties).Count) 个插件" }
            if ($cfg.statusLine)     { Write-Status "INFO" "  statusLine: 已配置" }
            if ($cfg.model)          { Write-Status "INFO" "  model: $($cfg.model)" }

            if ($modified) {
                if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
                Copy-Item $SETTINGS_FILE (Join-Path $backupRoot "settings.json") -Force
                Write-Status "INFO" "备份: $backupRoot\settings.json"
                $jsonOut = $cfg | ConvertTo-Json -Depth 10
                $jsonOut | Set-Content $SETTINGS_FILE -Encoding UTF8
                Write-Status "OK" "settings.json 已更新"
            } else {
                Write-Status "OK" "settings.json 无需修改"
            }
        } else {
            Write-Status "WARN" "无法解析 settings.json"
        }
    } else {
        Write-Status "SKIP" "settings.json 未找到"
    }

    # ── 3. settings.local.json ───────────────────────────────
    Write-Section "本地设置 (~/.claude/settings.local.json)" "[3/7]"

    if (Test-Path $SETTINGS_LOCAL) {
        $localCfg = Read-JsonSafe $SETTINGS_LOCAL
        if ($localCfg) {
            # Check for bad keys at any level
            $rawContent = Get-Content $SETTINGS_LOCAL -Raw
            if ($rawContent -match "ANTHROPIC_BASE_URL|apiBaseUrl|authToken|ANTHROPIC_AUTH_TOKEN") {
                Write-Status "WARN" "检测到第三方配置"
                if (Confirm-Action "使用 Clean-SettingsFile 清理?") {
                    Clean-SettingsFile $SETTINGS_LOCAL "settings.local.json"
                }
            } else {
                Write-Status "OK" "settings.local.json 正常"
            }
        }
    } else {
        Write-Status "SKIP" "settings.local.json 未找到"
    }

    # ── 4. Project-level settings scan ───────────────────────
    Write-Section "项目级设置扫描" "[4/7]"

    $projectDirs = @()
    if (Test-Path $PROJECTS_DIR) {
        $projectDirs = Get-ChildItem $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
    }

    $foundBad = 0
    foreach ($pd in $projectDirs) {
        $projSettings = Join-Path $pd.FullName "settings.json"
        $projLocal    = Join-Path $pd.FullName "settings.local.json"

        foreach ($sf in @($projSettings, $projLocal)) {
            if (Test-Path $sf) {
                $content = Get-Content $sf -Raw -ErrorAction SilentlyContinue
                if ($content -match "ANTHROPIC_BASE_URL|openrouter|AUTH_TOKEN|apiBaseUrl") {
                    Write-Status "WARN" "第三方配置: $sf"
                    $foundBad++
                }
            }
        }
    }

    if ($foundBad -gt 0) {
        if (Confirm-Action "清理 $foundBad 个含第三方配置的项目设置文件?") {
            foreach ($pd in $projectDirs) {
                foreach ($sf in @(
                    (Join-Path $pd.FullName "settings.json"),
                    (Join-Path $pd.FullName "settings.local.json")
                )) {
                    if (Test-Path $sf) {
                        $content = Get-Content $sf -Raw -ErrorAction SilentlyContinue
                        if ($content -match "ANTHROPIC_BASE_URL|openrouter|AUTH_TOKEN|apiBaseUrl") {
                            Clean-SettingsFile $sf $sf
                        }
                    }
                }
            }
        }
    } else {
        Write-Status "OK" "无项目级第三方配置"
    }

    # ── 5. Claude Desktop Settings ──────────────────────────
    Write-Section "Claude Desktop 设置" "[5/7]"
    $desktopSettingsChecked = $false
    foreach ($dp in $CLAUDE_DESKTOP_PATHS) {
        $dsFile = Join-Path $dp "User Data\settings.json"
        if (-not (Test-Path $dsFile)) {
            $dsFile = Join-Path $dp "settings.json"
        }
        if (Test-Path $dsFile) {
            $desktopSettingsChecked = $true
            $dsContent = Get-Content $dsFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($dsContent -match "ANTHROPIC_BASE_URL|apiBaseUrl|authToken") {
                Write-Status "WARN" "Claude Desktop 设置含第三方配置: $dsFile"
                if (Confirm-Action "清理该文件?") {
                    Clean-SettingsFile $dsFile "Claude Desktop settings"
                }
            } else {
                Write-Status "OK" "Claude Desktop 设置正常: $dsFile"
            }
        }
    }
    if (-not $desktopSettingsChecked) {
        Write-Status "SKIP" "Claude Desktop 未安装或无设置文件"
    }

    # ── 6. Proxy Port Cross-Validation ───────────────────────
    Write-Section "代理端口交叉验证" "[6/7]"

    # Detect actual active proxy port
    $activeProxyPort = $null
    foreach ($port in $KNOWN_PROXY_PORTS) {
        try {
            $tc = New-Object System.Net.Sockets.TcpClient
            $ar = $tc.BeginConnect("127.0.0.1", $port, $null, $null)
            $ok = $ar.AsyncWaitHandle.WaitOne(500, $false)
            if ($ok -and $tc.Connected) {
                $tc.EndConnect($ar)
                $activeProxyPort = $port
                $tc.Close()
                break
            }
            $tc.Close()
        } catch { }
    }

    if ($activeProxyPort) {
        Write-Status "OK" "活跃代理端口: $activeProxyPort"

        # Check VS Code claudeCode.environmentVariables for stale ports
        if (Test-Path $VSCODE_SETTINGS) {
            $vsRaw = Get-Content $VSCODE_SETTINGS -Raw -Encoding UTF8
            $envVarPorts = [regex]::Matches($vsRaw, '"value"\s*:\s*"[^"]*:(\d{4,5})"')
            foreach ($m in $envVarPorts) {
                $configuredPort = $m.Groups[1].Value
                if ($configuredPort -ne "$activeProxyPort") {
                    Write-Status "ERROR" "VS Code 配置端口 $configuredPort 与活跃端口 $activeProxyPort 不匹配"
                    Write-Status "INFO" "  请更新 VS Code claudeCode.environmentVariables 中的端口"
                }
            }
        }

        # Check user env vars
        foreach ($pv in @('HTTP_PROXY', 'HTTPS_PROXY')) {
            $val = [System.Environment]::GetEnvironmentVariable($pv, 'User')
            if ($val -and $val -match ':(\d{4,5})') {
                $envPort = $Matches[1]
                if ($envPort -ne "$activeProxyPort") {
                    Write-Status "ERROR" "ENV $pv 端口 $envPort 与活跃端口 $activeProxyPort 不匹配"
                }
            }
        }
    } else {
        Write-Status "INFO" "未检测到活跃代理端口 (已扫描: $($KNOWN_PROXY_PORTS -join ', '))"
    }

    # ── 7. MCP Auth Cache ────────────────────────────────────
    Write-Section "MCP 认证缓存" "[7/7]"

    if (Test-Path $MCP_AUTH_CACHE) {
        $mcpContent = Get-Content $MCP_AUTH_CACHE -Raw
        Write-Status "INFO" "MCP 认证缓存内容: $mcpContent"
        if (Confirm-Action "重置 MCP 认证缓存?" -DefaultYes $false) {
            if (-not (Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
            Copy-Item $MCP_AUTH_CACHE (Join-Path $backupRoot "mcp-needs-auth-cache.json") -Force
            "{}" | Set-Content $MCP_AUTH_CACHE -Encoding UTF8
            Write-Status "OK" "MCP 认证缓存已重置"
        } else {
            Write-Status "SKIP" "保留 MCP 认证缓存"
        }
    } else {
        Write-Status "OK" "无 MCP 认证缓存文件"
    }

    # ── Summary ──────────────────────────────────────────────
    Write-Host ""
    if (Test-Path $backupRoot) {
        $backupSize = Get-DirSize $backupRoot
        Write-Host "  备份已保存: $backupRoot ($($backupSize.Display))" -ForegroundColor Green
        Write-Host "  如需回退，将备份文件复制回原位置即可。" -ForegroundColor DarkGray
    } else {
        Write-Host "  无修改，未创建备份。" -ForegroundColor DarkGray
    }
}
