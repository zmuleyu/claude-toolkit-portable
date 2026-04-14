# Changelog

## v7.3 Portable (2026-04-14) — GitHub 自分发 + 跨机诊断 + 账号查看

**核心改进：工具从单机脚本升级为可自助分发的诊断平台，支持远程机器一键安装和 A↔B 通信诊断。**

### New: scripts/bootstrap-remote.ps1
- 远程机器一键安装脚本（iwr + iex one-liner）
- 自动检测 git，克隆或更新仓库
- 打印下一步操作指引（查看账号 / 菜单 / 认证恢复）

### New: scripts/update-from-github.ps1
- 日常从 GitHub 更新到最新 master
- 支持 `-Tag vX.Y.Z` 固定到特定版本
- 显示更新前后版本对比

### New: modules/mode-peer-check.ps1 (Mode 8)
- A↔B 跨机通信诊断（Ping + TCP 端口扫描）
- 使用 .NET TcpClient 异步 2s 超时（兼容 Windows 10，避开 Test-NetConnection NUL 坑）
- 检测本机 Clash TUN 是否拦截 LAN 流量
- 检测 Windows 防火墙出站策略
- 根因猜测（全端口关闭时区分：对端服务未启 / 防火墙拦截 / TUN 干扰 / 子网不同）
- 配置文件：`config/peers.json`（从 `peers.example.json` 复制）

### New: Show-CurrentAccount (Mode 2 -ShowCurrentAccount)
- 只读读取 `~/.claude/.credentials.json`
- 输出：Email / Account UUID / Org UUID / Org Name / Token 过期时间 / Scopes
- Token 过期颜色提示（绿=健康 / 黄=即将过期 / 红=已过期）
- 不写入、不清理、不触发 OAuth
- 菜单快捷键：`[A]`；命令行：`-ShowCurrentAccount`

### Updated: Claude-Toolkit.ps1
- 版本 v7.2 → v7.3
- 新增 `-ShowCurrentAccount` 参数（param 层拦截，直接读账号后退出）
- 菜单新增 Mode 8（跨机诊断）+ `[A]`（查看账号）快捷键
- 输入提示从 `[0-7/R/Q]` → `[0-8/A/R/Q]`
- Mode dispatcher 加入 `peer-check`

### New: .gitignore
- 排除 `backups/` / `auth-baselines/` / `support-bundles/`（含凭据快照，不入库）
- 排除 `config/peers.json`（机器本地 IP，仅 example.json 入库）

### New: config/peers.example.json
- 跨机配置模板：Machine B 192.168.3.11 + 7 个端口定义

### GitHub 发布
- 仓库：https://github.com/zmuleyu/claude-toolkit-portable（公开）
- 一键安装：`iwr https://raw.githubusercontent.com/zmuleyu/claude-toolkit-portable/master/scripts/bootstrap-remote.ps1 -UseBasicParsing | iex`

---

## v7.2 Portable (2026-04-09) — stale-patch detection

**根因修复：dns_config.yaml 修补后 Clash Verge 未重启导致条目未生效。**

### Root cause context
TCT v7.1 将 OpenAI 端点加入 fake-ip-filter，但 verge-mihomo 进程在文件修补前已启动
（mihomo 2026-04-08 00:53 vs 修补 2026-04-09 22:28），导致 Codex SSE 连接仍触发 fake-IP 截断。
Mode 4 / Verify-DnsFilter.ps1 / Mode 1 只检查文件内容，对此"文件正确但未加载"的状态报告 PASS，
产生误报，掩盖了真正需要重启的问题。

### New: modules/clash-fake-ip-fix.ps1
- 新增 `Test-MihomoLoadedCurrentConfig` 函数
  - 用 WMI 读取 verge-mihomo.exe 启动时间（PS 5.1 兼容）
  - 返回 `Loaded=$false` 当 dns_config.yaml 修改时间晚于 mihomo 启动时间（stale patch）
  - 返回结果含 `FileMtime`、`MihomoStart`、`Reason` 字段

### Enhanced: modules/mode-network.ps1 (Mode 4)
- Section [2/11]：`filterCheck.Pass` 后追加 stale-patch 子检查
  - stale 时报 WARN，显示 mihomo 启动时间 vs dns 修改时间
- ACTION：新增 stale 分支（与 missing-entry 分支互斥）
  - stale 时直接提示重启，不再尝试 patch（文件本身正确）
  - 支持 `$script:AutoFixEnabled` 自动重启

### Enhanced: Verify-DnsFilter.ps1
- Pass 分支末追加 stale-patch 检测
- stale 时：写 warn 日志 + 发送 Toast "Restart Required" + exit 0
- pass + current：日志改为 "all 7 entries active in running mihomo"

### Enhanced: modules/mode-health.ps1 (Mode 1)
- [11/12] Fake-IP Filter 子检查：Pass 后追加 stale 检测
- stale 时报 WARN，提示运行 `-Mode network` 进行引导修复

### Updated: constants.ps1 + Claude-Toolkit.ps1
- `$SCRIPT_VERSION` 7.1 → 7.2

---

## v7.1 Portable (2026-04-09) — unified management update

**扩展 AI provider fake-IP 检测覆盖范围：Anthropic → Anthropic + OpenAI。**

### Root cause context
Codex CLI（使用 `api.openai.com`）在 Clash Verge fake-ip 模式下出现
`stream disconnected before completion: Transport error: network error: error decoding response body`。
根因与 Anthropic 端点相同：SSE 长连接被 fake-ip 截断。

### Enhanced: modules/clash-fake-ip-fix.ps1
- `Get-AnthropicFakeIpFilterRequired` 从 4 条目扩展到 7 条目
- 新增：`openai.com` / `+.openai.com` / `api.openai.com`
- 注释更新：说明 OpenAI 与 Anthropic 同为 SSE 流式连接，均受 fake-ip 影响

### Enhanced: Verify-DnsFilter.ps1
- pass 日志更新，列出全部 7 个受保护域名

### Enhanced: mode-network.ps1 (Mode 4)
- `api.openai.com` 从 `$devEndpoints` 移至 `$generalEndpoints`，纳入 DNS fake-IP 实时检测
- Section [2/11]：check 名称从 "Anthropic Fake-IP Filter" 更新为 "AI Provider Fake-IP Filter"
- Section [11/11] ACTION：描述文本更新为 "Anthropic + OpenAI domains"

### Enhanced: mode-health.ps1 (Mode 1)
- [11/12] fake-IP filter 子检查：注释和输出文本更新，反映 7 条目

### Updated: constants.ps1
- `$SCRIPT_VERSION` 7.0 → 7.1
- `$TEST_ENDPOINTS` 新增 `api.openai.com` 条目

### Unified management integration
- `clash-fake-ip-fix.ps1`：新增 `Test-DnsFilterGuardRegistered` 函数（检测 ClashDnsFilterCheck 任务是否注册）
- `mode-network.ps1` ACTION：patch 成功后，自动检测守护任务是否存在，未注册时提示安装
- `setup.ps1`：新增第 5 步 — 检测 Clash Verge 存在 → 验证 dns_config.yaml 7 条目 → 检测并注册 ClashDnsFilterCheck 任务
- `mode-recovery.ps1` Step 3：标题和日志更新为 "AI provider fake-ip filter"
- `Claude-Toolkit.ps1`：主文件 header 版本号更新
- `Register-DnsFilterCheck.ps1`：任务描述文本加入 OpenAI

---

## v7.0 Portable (2026-04-08)

**整合版：散落脚本归入模块体系，建立版本号更新规范。**

### New: Mode 7 — 认证恢复 (mode-recovery.ps1)
- 统一入口：系统代理禁用 → fake-ip-filter patch → Clash Direct → OAuth 重置，5 步有序流程
- 支持 `-Mode recovery` CLI 调用和菜单 `[7]` / `[R]` 快捷键
- `Invoke-AuthRecovery` 直接调用 `Invoke-AuthReset`，无需额外弹出新窗口

### Consolidated: Run-Auth-Recovery.ps1 → thin wrapper
- 原独立脚本重写为向后兼容包装器，dot-source 模块后调用 `Invoke-AuthRecovery`
- 保留所有参数签名（ExpectedAccountUuid / ExpectedEmail 等），现有快捷方式和文档链接不受影响

### New: docs/ 目录
- 将 `clash-login-issue-summary.md` 移入 `docs/`，根目录保持整洁

### Versioning convention (v7.0+)
- 每次功能更新递增 MINOR（7.x）
- 每次 bug fix 或小改动递增 PATCH（7.0.x）
- 每次重大架构变更递增 MAJOR（8.0）
- 版本号同步更新：`modules/constants.ps1` `$SCRIPT_VERSION` + `CHANGELOG.md` 头部

---

## v6.1 Portable (2026-04-08)

**Clash fake-IP 根因修复 + mode-network / mode-health 深度集成。**

### New: modules/clash-fake-ip-fix.ps1
- 6 个函数：`Get-DnsConfigPath` / `Test-AnthropicFakeIpFilter` / `Add-AnthropicFakeIpFilter`（幂等 patch + 时间戳备份）/ `Save-LastGoodDnsConfig` / `Restore-LastGoodDnsConfig` / `Restart-ClashVerge`
- 真正的根因文件：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\dns_config.yaml`（覆盖所有 profile dns 段）

### New: Verify-DnsFilter.ps1 + Register-DnsFilterCheck.ps1
- 开机守护脚本 + Task Scheduler 任务（at-logon + 09:07 每日检查）
- 缺失条目时静默 patch + Windows Toast 提醒重启 Clash Verge

### Enhanced: mode-network.ps1 (Mode 4)
- Section [2/11]：`$script:FakeIpFilterCheck` 持久化，WARN 消息明确列出 missing 条目
- Endpoint Summary：fake-IP 活跃时表格下方显示黄色警告
- Section [11/11] ACTION：新增 Anthropic fake-IP filter auto-fix 入口（AutoFix 自动 patch / Confirm-Action 交互 / 独立重启确认），与 NO_PROXY auto-fix 模式一致

### Enhanced: mode-health.ps1 (Mode 1)
- [11/12] 代理端口一致性段落增加 fake-IP filter 子检查
- WARN 时提示 `-Mode network` 直接修复路径

### New: Run-Auth-Recovery.ps1
- 综合认证修复脚本：系统代理检测 → fake-ip-filter 检测/patch → Clash Direct 切换 → 认证模式启动
- 可独立运行，也可从 mode-network ACTION 段跳转

### New: clash-login-issue-summary.md
- Clash Verge + fake-IP 根因总结文档（v2，修正 v1 错误方向）

---

## v6.0 Portable (2026-04-01)

**LAN 跨设备诊断 + 基于实战经验的全面增强。**

### New: Mode 6 — LAN 诊断 (mode-lan.ps1)
- 7 步跨设备连接排查流水线（对标 lan-toolkit MCP `lan_diagnose`，纯 PowerShell 实现）
- 本机 IP 检测（过滤虚拟适配器：VirtualBox 192.168.56.x、ICS 192.168.137.x）
- Clash TUN 模式检测（198.18.x）+ exclude-route 配置验证
- 网络配置文件类型审计（Public → Private 自动修复，需管理员）
- Windows 防火墙入站规则审计（检测 Node.js Block 规则 + 自动创建 Allow 规则）
- 目标设备 Ping + TCP 端口探测（8789/18850/19000/3000/5173/8080）
- ARP 表扫描 + LAN toolkit 服务发现
- HTTP_PROXY LAN 干扰检测（NO_PROXY 缺失警告 + 自动修复）

### Enhanced: Mode 1 — 健康检查 (mode-health.ps1)
- 从 9 项增至 12 项检查
- [10/12] LAN 连接快速检查：本机 IP 显示、TUN 模式警告、虚拟适配器过滤
- [11/12] 代理端口一致性：环境变量 / VS Code / 系统代理 / Clash API 四源比对
- [12/12] Claude Code 桌面应用状态：安装检测、进程状态

### Enhanced: Mode 4 — 网络诊断 (mode-network.ps1)
- 代理端口自动扫描：不再硬编码 7890，扫描 5 个常见端口（7890/7897/7898/1080/10809）
- [10/10] LAN 跨设备 & TUN 模式检查：TUN exclude-route 验证、HTTP_PROXY LAN 干扰检测、ARP 邻居发现 + LAN toolkit 端口探测

### Enhanced: Mode 3 — 缓存清理 (mode-cache.ps1)
- 新增 Claude Code Desktop 缓存目录（AnthropicClaude/、claude-desktop/）
- 孤立 git worktree 检测与清理（~/.claude/worktrees/）
- VS Code 旧日志显示最旧日期

### Enhanced: Mode 5 — 设置重置 (mode-settings.ps1)
- 从 5 项增至 7 项
- [5/7] Claude Desktop 设置审计
- [6/7] 代理端口交叉验证：扫描活跃端口，对比 VS Code / 环境变量配置

### Constants & Infrastructure
- 版本号 → 6.0
- 新增常量：`$KNOWN_PROXY_PORTS`、`$TUN_IP_PREFIX`、`$VIRTUAL_ADAPTER_PREFIXES`、`$LAN_TOOLKIT_PORTS`、`$CLAUDE_DESKTOP_PATHS`、`$CLAUDE_CODE_DESKTOP_PROC`、`$WORKTREE_DIR`
- `$PROXY_PROC_NAMES` 新增 `clash-verge-service`、`mihomo-party`
- `$CLAUDE_ELECTRON_CACHE_DIRS` 新增 3 个 Desktop 缓存路径
- `setup.ps1` 新增 Claude Code Desktop 检测
- `run.bat` / `create-shortcut.ps1` 版本号更新

---

## v5.0 Portable (2026-03-28)

**完全便携版 — 可在任意 Windows 机器上即插即用。**

### Portable
- 修复 `create-shortcut.ps1` 硬编码路径，改用 `$MyInvocation` 动态解析
- 新增 `setup.ps1` 首次运行向导（环境检测 + 快捷方式创建）
- Banner 显示 "Portable" 版本标识
- README 更新为与路径无关的说明

### Version Management
- 版本号升级至 5.0
- 新增 `$SCRIPT_EDITION` 常量支持版本标签
- Git 仓库初始化，tag `v5.0-portable`

---

## v4.0 (2026-03-26)

**从单文件认证重置脚本升级为多模块诊断与修复工具集。**

### Architecture
- 重构为多文件模块架构（9 个 .ps1 文件，总计 2059 行）
- 主入口 `Claude-Toolkit.ps1` + `modules/` 目录，支持增量扩展
- 支持命令行参数 `-Mode health|auth|cache|network|settings|full`
- 支持交互式中文菜单

### New: Mode 1 — 健康检查 (mode-health.ps1)
- 9 项只读诊断：OAuth 令牌过期检查、CLI/扩展版本、DNS 连通性、MCP 认证状态、磁盘使用统计、IDE 锁文件、环境变量审计、VS Code 设置审计
- 汇总看板 + 修复建议

### New: Mode 3 — 缓存清理 (mode-cache.ps1)
- 逐类确认清理：debug/file-history/shell-snapshots/telemetry/session-env/cache
- 过期 IDE 锁文件清理（PID 存活检查）
- VS Code 旧日志（>3 天）清理
- %TEMP%/claude/ 清理
- Before/After 大小对比

### New: Mode 4 — 网络诊断 (mode-network.ps1)
- DNS 解析测试（4 端点）
- HTTPS 直连/代理双通道测试
- 代理软件检测（Clash Verge/v2ray/sing-box 等）
- 代理端口一致性审计（5 来源比对）
- TLS 证书链验证（检测 MITM 拦截）
- 汇总表格输出

### New: Mode 5 — 设置重置 (mode-settings.ps1)
- 时间戳备份到 `~/.claude/backups/`
- VS Code 设置修复（[1m] 后缀、disableLoginPrompt、可选清代理）
- 全局 settings.json 清理（保留 hooks/permissions/plugins）
- settings.local.json 清理
- 项目级设置扫描
- MCP 认证缓存可选重置

### Refactored: Mode 2 — 认证重置 (mode-auth.ps1)
- 从 Fix-ClaudeAuth v3.1 完整重构，逻辑不变
- 拆分为 `Invoke-ClashDirectMode` / `Invoke-AuthCleanup` / `Invoke-CleanLogin` 三个函数
- 路径统一使用 constants.ps1 常量
- 输出统一使用 Write-Status

### Infrastructure
- `constants.ps1`：25+ 路径常量 + 端点/环境变量/进程名配置
- `utils.ps1`：12 个共享工具函数
- `clash-helpers.ps1`：Clash Verge API 辅助函数（从 v3.1 提取）
- UTF-8 BOM 编码（解决 PowerShell 5.1 中文显示）
- PowerShell 5.1 兼容性修复（switch 语法、$Pid 保留变量、regex 引号）

---

## v3.1 (2026-03-26)

**Fix-ClaudeAuth.ps1 单文件版（607 行，已归档至 docs/）。**

- [NEW] Step 3.5: VS Code settings.json 自动检查与修复
  - 检测 `claudeCode.selectedModel` 的 `[1m]` 后缀（导致 429 长上下文错误）
  - 检测 `claudeCode.disableLoginPrompt: true`（阻止 token 过期后重新登录）
  - 代理端口一致性检查

## v3.0

- Clash Verge 自动检测与 Direct 模式切换
- JSON-aware 设置文件清理（Python/Regex/Reset 三级降级）
- 干净登录窗口（清除所有代理和 Anthropic 环境变量）
- 登录完成后自动恢复 Clash Verge 模式
