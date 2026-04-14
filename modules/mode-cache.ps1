# mode-cache.ps1 — Mode 3: Cache & Storage Cleanup (C盘瘦身 extended)
# Part of Claude Code Diagnostic & Repair Toolkit v4.1

function Invoke-CacheCleanup {

    # ── Helper: clean a directory and return freed bytes ──
    function Clean-DirItem {
        param([string]$Path, [string]$Label)
        $size = Get-DirSize $Path
        if ($size.Bytes -eq 0) { return 0 }
        if (Confirm-Action "清理 $Label ($($size.Display))?") {
            try {
                Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "OK" "已清理: $Label ($($size.Display))"
                return $size.Bytes
            } catch {
                Write-Status "WARN" "部分文件无法删除 ($Label): $_"
                return 0
            }
        } else {
            Write-Status "SKIP" "跳过: $Label"
            return 0
        }
    }

    Write-Host ""
    Write-Host "  缓存清理将逐类显示可清理内容，每项需确认后才会删除。" -ForegroundColor DarkGray
    Write-Host ""

    # ══════════════════════════════════════════════════════════
    # Scan phase: show all sizes in a table
    # ══════════════════════════════════════════════════════════
    Write-Section "存储使用扫描" "[分析]"
    Write-Host ""
    Write-Host ("      {0,-34} {1,12} {2,10}" -f "类别", "大小", "文件数") -ForegroundColor DarkGray
    Write-Host ("      {0,-34} {1,12} {2,10}" -f ("─" * 34), ("─" * 12), ("─" * 10)) -ForegroundColor DarkGray

    $totalReclaimable = 0

    $categories = @(
        @{ Name = "Claude Code 缓存";   Dirs = $CLEANABLE_DIRS },
        @{ Name = "Claude 应用缓存";    Dirs = $CLAUDE_ELECTRON_CACHE_DIRS },
        @{ Name = "Codex CLI 缓存";     Dirs = $CODEX_CACHE_DIRS },
        @{ Name = "VS Code 缓存";       Dirs = $VSCODE_CACHE_DIRS },
        @{ Name = "开发工具缓存";        Dirs = $DEV_CACHE_DIRS },
        @{ Name = "浏览器缓存";          Dirs = $BROWSER_CACHE_DIRS },
        @{ Name = "系统临时文件";        Dirs = $TEMP_DIRS }
    )

    foreach ($cat in $categories) {
        $catBytes = 0
        $catFiles = 0
        foreach ($d in $cat.Dirs) {
            $s = Get-DirSize $d.Path
            $catBytes += $s.Bytes
            $catFiles += $s.FileCount
        }
        if ($catBytes -gt 0) {
            $display = if ($catBytes -ge 1GB) { "{0:N2} GB" -f ($catBytes / 1GB) }
                       elseif ($catBytes -ge 1MB) { "{0:N1} MB" -f ($catBytes / 1MB) }
                       elseif ($catBytes -ge 1KB) { "{0:N0} KB" -f ($catBytes / 1KB) }
                       else { "$catBytes B" }
            $color = if ($catBytes -ge 500MB) { "Red" }
                     elseif ($catBytes -ge 100MB) { "Yellow" }
                     else { "White" }
            Write-Host ("      {0,-34} {1,12} {2,10}" -f $cat.Name, $display, $catFiles) -ForegroundColor $color
            $totalReclaimable += $catBytes
        }
    }

    # Additional items: IDE locks, VS Code old logs, Claude temp
    $claudeTempSize = Get-DirSize $CLAUDE_TEMP_DIR
    if ($claudeTempSize.Bytes -gt 0) {
        $totalReclaimable += $claudeTempSize.Bytes
        Write-Host ("      {0,-34} {1,12} {2,10}" -f "Claude 临时文件", $claudeTempSize.Display, $claudeTempSize.FileCount) -ForegroundColor White
    }

    # Projects (info only)
    $projSize = Get-DirSize $PROJECTS_DIR
    if ($projSize.Bytes -gt 0) {
        Write-Host ("      {0,-34} {1,12} {2,10}" -f "会话记录 (仅显示)", $projSize.Display, $projSize.FileCount) -ForegroundColor DarkGray
    }

    Write-Host ""
    $totalDisplay = if ($totalReclaimable -ge 1GB) { "{0:N2} GB" -f ($totalReclaimable / 1GB) }
                    elseif ($totalReclaimable -ge 1MB) { "{0:N1} MB" -f ($totalReclaimable / 1MB) }
                    else { "{0:N0} KB" -f ($totalReclaimable / 1KB) }
    Write-Host "      可释放总计: $totalDisplay" -ForegroundColor Cyan
    Write-Host ""

    if ($totalReclaimable -eq 0) {
        Write-Status "OK" "无需清理，所有缓存已为空"
        return
    }

    # ══════════════════════════════════════════════════════════
    # Cleanup phase
    # ══════════════════════════════════════════════════════════
    $freedBytes = 0

    # ── [1/8] Claude Code caches ──────────────────────────────
    Write-Section "Claude Code 缓存" "[1/8]"
    foreach ($dir in $CLEANABLE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # Stale IDE lock files
    $staleLocks = @()
    if (Test-Path $IDE_LOCK_DIR) {
        $lockFiles = Get-ChildItem $IDE_LOCK_DIR -Filter "*.lock" -ErrorAction SilentlyContinue
        foreach ($lf in $lockFiles) {
            try {
                $lockContent = Get-Content $lf.FullName -Raw | ConvertFrom-Json
                if ($lockContent.pid -and -not (Test-ProcessRunning $lockContent.pid)) {
                    $staleLocks += $lf
                }
            } catch {
                $staleLocks += $lf
            }
        }
        if ($staleLocks.Count -gt 0) {
            if (Confirm-Action "清理 $($staleLocks.Count) 个过期 IDE 锁文件?") {
                foreach ($lf in $staleLocks) {
                    Remove-Item $lf.FullName -Force -ErrorAction SilentlyContinue
                }
                Write-Status "OK" "已清理 $($staleLocks.Count) 个过期锁文件"
            } else {
                Write-Status "SKIP" "跳过: 过期锁文件"
            }
        }
    }

    # Claude temp
    if ($claudeTempSize.Bytes -gt 0) {
        $freedBytes += (Clean-DirItem $CLAUDE_TEMP_DIR "Claude 临时文件")
    }

    # Orphaned git worktrees
    if (Test-Path $WORKTREE_DIR) {
        $wtDirs = Get-ChildItem $WORKTREE_DIR -Directory -ErrorAction SilentlyContinue
        $orphanedWt = @()
        $orphanedWtBytes = 0
        foreach ($wt in $wtDirs) {
            $gitDir = Join-Path $wt.FullName ".git"
            $isOrphan = $false
            $skipOrphanCheck = $false
            if (-not (Test-Path $gitDir)) {
                $isOrphan = $true
            } else {
                # Check if parent repo still references this worktree
                $gitContent = Get-Content $gitDir -Raw -ErrorAction SilentlyContinue
                if ($gitContent -match "gitdir:\s*(.+)") {
                    $refPath = $Matches[1].Trim()
                    if (-not [System.IO.Path]::IsPathRooted($refPath)) {
                        $refPath = [System.IO.Path]::GetFullPath((Join-Path $wt.FullName $refPath))
                    }
                    if (-not (Test-Path $refPath)) { $isOrphan = $true }
                } elseif ($gitContent) {
                    Write-Status "WARN" "无法解析 worktree 引用，已跳过: $($wt.FullName)"
                    $skipOrphanCheck = $true
                } else {
                    Write-Status "WARN" "无法读取 worktree 引用，已跳过: $($wt.FullName)"
                    $skipOrphanCheck = $true
                }
            }
            if ($skipOrphanCheck) {
                continue
            }
            if ($isOrphan) {
                $orphanedWt += $wt
                $wtSize = Get-DirSize $wt.FullName
                $orphanedWtBytes += $wtSize.Bytes
            }
        }
        if ($orphanedWt.Count -gt 0) {
            $wtDisplay = if ($orphanedWtBytes -ge 1MB) { "{0:N1} MB" -f ($orphanedWtBytes / 1MB) }
                         elseif ($orphanedWtBytes -ge 1KB) { "{0:N0} KB" -f ($orphanedWtBytes / 1KB) }
                         else { "$orphanedWtBytes B" }
            if (Confirm-Action "清理 $($orphanedWt.Count) 个孤立 git worktree ($wtDisplay)?") {
                foreach ($wt in $orphanedWt) {
                    Remove-Item $wt.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                $freedBytes += $orphanedWtBytes
                Write-Status "OK" "已清理 $($orphanedWt.Count) 个孤立 worktree ($wtDisplay)"
            } else {
                Write-Status "SKIP" "跳过: 孤立 worktree"
            }
        }
    }

    # ── [2/8] Claude Electron app caches ─────────────────────
    Write-Section "Claude 应用缓存 (Electron)" "[2/8]"
    Write-Host "      NOTE: 仅清理缓存，不影响登录状态和配置" -ForegroundColor DarkGray
    foreach ($dir in $CLAUDE_ELECTRON_CACHE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # ── [3/8] Codex CLI caches ────────────────────────────────
    Write-Section "Codex CLI 缓存" "[3/8]"
    Write-Host "      NOTE: auth.json 和 config.toml 不会被清理" -ForegroundColor DarkGray
    foreach ($dir in $CODEX_CACHE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # ── [4/8] VS Code caches ─────────────────────────────────
    Write-Section "VS Code 缓存" "[4/8]"
    foreach ($dir in $VSCODE_CACHE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # VS Code old logs (>3 days)
    $oldLogDirs = @()
    $oldLogSize = 0
    if (Test-Path $VSCODE_LOGS_DIR) {
        $cutoff = (Get-Date).AddDays(-3)
        $oldLogDirs = Get-ChildItem $VSCODE_LOGS_DIR -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
        foreach ($ld in $oldLogDirs) {
            $ldSize = Get-DirSize $ld.FullName
            $oldLogSize += $ldSize.Bytes
        }
        if ($oldLogDirs.Count -gt 0) {
            $oldLogDisplay = if ($oldLogSize -ge 1MB) { "{0:N1} MB" -f ($oldLogSize / 1MB) }
                             elseif ($oldLogSize -ge 1KB) { "{0:N0} KB" -f ($oldLogSize / 1KB) }
                             else { "$oldLogSize B" }
            $oldestLog = ($oldLogDirs | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime.ToString("yyyy-MM-dd")
            Write-Status "INFO" "最旧日志: $oldestLog"
            if (Confirm-Action "清理 $($oldLogDirs.Count) 个 VS Code 旧日志目录 ($oldLogDisplay)?") {
                foreach ($ld in $oldLogDirs) {
                    Remove-Item $ld.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                $freedBytes += $oldLogSize
                Write-Status "OK" "已清理 VS Code 旧日志 ($oldLogDisplay)"
            } else {
                Write-Status "SKIP" "跳过: VS Code 旧日志"
            }
        }
    }

    # ── [5/8] Dev tool caches ─────────────────────────────────
    Write-Section "开发工具缓存" "[5/8]"
    foreach ($dir in $DEV_CACHE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # CLI cleanup commands
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        if (Confirm-Action "运行 npm cache clean --force?") {
            try {
                npm cache clean --force 2>&1 | Out-Null
                Write-Status "OK" "npm cache clean 完成"
            } catch {
                Write-Status "WARN" "npm cache clean 失败: $_"
            }
        }
    }
    if (Get-Command pip -ErrorAction SilentlyContinue) {
        if (Confirm-Action "运行 pip cache purge?") {
            try {
                pip cache purge 2>&1 | Out-Null
                Write-Status "OK" "pip cache purge 完成"
            } catch {
                Write-Status "WARN" "pip cache purge 失败: $_"
            }
        }
    }

    # ── [6/8] Browser caches ─────────────────────────────────
    Write-Section "浏览器缓存" "[6/8]"
    Write-Status "INFO" "建议先关闭 Chrome/Edge 再清理浏览器缓存"
    foreach ($dir in $BROWSER_CACHE_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # ── [7/8] System TEMP ─────────────────────────────────────
    Write-Section "系统临时文件" "[7/8]"
    foreach ($dir in $TEMP_DIRS) {
        $freedBytes += (Clean-DirItem $dir.Path $dir.Label)
    }

    # ── [8/8] System deep clean (admin only) ──────────────────
    Write-Section "系统深度清理 (需管理员)" "[8/8]"

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if (-not $isAdmin) {
        Write-Status "INFO" "非管理员，跳过系统深度清理"
    } else {
        # DISM component cleanup
        if (Confirm-Action "运行 DISM 组件清理 (StartComponentCleanup /ResetBase)?") {
            try {
                Write-Status "INFO" "正在执行 DISM 清理，可能需要几分钟..."
                $dismResult = Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
                Write-Status "OK" "DISM 组件清理完成"
            } catch {
                Write-Status "WARN" "DISM 清理失败: $_"
            }
        }

        # Hibernation file
        $hiberFile = "C:\hiberfil.sys"
        if (Test-Path $hiberFile) {
            $hiberSize = (Get-Item $hiberFile -Force).Length
            $hiberDisplay = if ($hiberSize -ge 1GB) { "{0:N2} GB" -f ($hiberSize / 1GB) }
                            else { "{0:N0} MB" -f ($hiberSize / 1MB) }
            if (Confirm-Action "关闭休眠以释放 $hiberDisplay (powercfg /hibernate off)?") {
                try {
                    powercfg /hibernate off
                    $freedBytes += $hiberSize
                    Write-Status "OK" "已关闭休眠，释放 $hiberDisplay"
                } catch {
                    Write-Status "WARN" "关闭休眠失败: $_"
                }
            }
        }
    }

    # ── Projects info (no delete) ─────────────────────────────
    if ($projSize.Bytes -gt 500MB) {
        Write-Host ""
        Write-Status "INFO" "会话记录占用 $($projSize.Display) ($($projSize.FileCount) 文件)"
        Write-Status "INFO" "如需清理旧会话，可手动删除: $PROJECTS_DIR"
        Write-Status "INFO" "注意: 这会丢失所有历史对话记录"
    }

    # ── Summary ───────────────────────────────────────────────
    Write-Host ""
    $freedDisplay = if ($freedBytes -ge 1GB) { "{0:N2} GB" -f ($freedBytes / 1GB) }
                    elseif ($freedBytes -ge 1MB) { "{0:N1} MB" -f ($freedBytes / 1MB) }
                    elseif ($freedBytes -ge 1KB) { "{0:N0} KB" -f ($freedBytes / 1KB) }
                    else { "$freedBytes B" }
    Write-Host "  总计释放: $freedDisplay" -ForegroundColor Green
}
