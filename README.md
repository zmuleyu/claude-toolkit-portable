# Claude Toolkit v6.0 Portable

Claude Code 诊断与修复工具集 — Windows 平台一站式 Claude Code 运维脚本。

## Portable 使用

将整个文件夹复制到任意位置即可使用，无需安装。支持 USB/网络共享/任意目录。

**首次使用**：运行 `setup.ps1` 检测环境并创建桌面快捷方式。

## 功能概览

| 模式 | 名称 | 类型 | 说明 |
|------|------|------|------|
| 1 | 健康检查 | 只读 | 12 项诊断：OAuth/CLI/扩展/网络/MCP/磁盘/锁文件/环境变量/VS Code/LAN/代理端口/Desktop |
| 2 | 认证重置 | 修改 | 清除 OAuth 令牌 → 清理设置 → 验证真直连条件 → 启动干净登录窗口（含 Clash Verge 自动切换与账号校验） |
| 3 | 缓存清理 | 修改 | 逐类确认清理 debug/file-history/shell-snapshots/telemetry/日志/临时文件/worktree |
| 4 | 网络诊断 | 只读 | DNS/TCP/TLS/HTTP 分层诊断 + fake-IP 检测 + 代理端口一致性 + Auth Readiness |
| 5 | 设置重置 | 修改 | 备份 → 修复 VS Code → 清理全局/本地/项目级 → Desktop 审计 → 代理端口交叉验证 |
| 6 | LAN 诊断 | 修复 | 7 步跨设备连接排查：IP/TUN/网络类型/防火墙/目标探测/ARP 发现/代理干扰 |
| 0 | 完整诊断 | 只读 | 按顺序运行 Mode 1 + Mode 4 |

## 快速使用

**方式 1**：右键 `Claude-Toolkit.ps1` → "使用 PowerShell 运行"

**方式 2**：双击 `run.bat`

**方式 3**：命令行直接指定模式
```powershell
powershell -ExecutionPolicy Bypass -File "<toolkit-dir>\Claude-Toolkit.ps1" -Mode health
powershell -ExecutionPolicy Bypass -File "<toolkit-dir>\Claude-Toolkit.ps1" -Mode auth -ExpectedAccountUuid "<uuid>" -ExpectedEmail "<email>"
```

**可用 Mode 参数**：`menu` | `health` | `auth` | `cache` | `network` | `settings` | `lan` | `full`

## 项目结构

```
claude-toolkit/
├── Claude-Toolkit.ps1           主入口 + 交互菜单
├── run.bat                      批处理启动器
├── setup.ps1                    首次运行向导（环境检测 + 快捷方式）
├── create-shortcut.ps1          桌面快捷方式创建
├── modules/
│   ├── constants.ps1            路径常量 + 配置项
│   ├── utils.ps1                共享工具函数 (Write-Status, Backup-File, JSON 读写等)
│   ├── clash-helpers.ps1        Clash Verge / Mihomo API 辅助函数
│   ├── mode-health.ps1          Mode 1: 健康检查
│   ├── mode-auth.ps1            Mode 2: 认证重置
│   ├── mode-cache.ps1           Mode 3: 缓存清理
│   ├── mode-network.ps1         Mode 4: 网络诊断
│   ├── mode-settings.ps1        Mode 5: 设置重置
│   └── mode-lan.ps1             Mode 6: LAN 跨设备诊断
├── docs/
│   └── Fix-ClaudeAuth-v3.1.ps1  原版 v3.1 单文件脚本（归档）
├── README.md
└── CHANGELOG.md
```

## 系统要求

- Windows 10/11
- PowerShell 5.1+（系统自带）
- Python 3.x（可选，提升 JSON 处理可靠性；无 Python 时自动降级）
- 无需管理员权限

## 各模式详细说明

### Mode 1: 健康检查

12 项子检查，全部只读不修改任何文件：

| # | 检查项 | 数据源 | 判断 |
|---|--------|--------|------|
| 1 | OAuth 令牌 | `~/.claude/.credentials.json` | 过期时间 >2h 绿 / <2h 黄 / 过期 红 |
| 2 | Claude CLI | `claude --version` | 可用 / 不可用 |
| 3 | VS Code 扩展 | `~/.vscode/extensions/anthropic.claude-code-*` | 版本号 / 未安装 |
| 4 | 网络连接 | DNS 解析 4 端点 | 全通 / 部分 / 全失败 |
| 5 | MCP 状态 | `mcp-needs-auth-cache.json` | 正常 / 需认证 |
| 6 | 磁盘使用 | `~/.claude/` 各子目录 | 汇总表 + 总大小 |
| 7 | IDE 锁文件 | `~/.claude/ide/*.lock` | PID 存活检查 |
| 8 | 环境变量 | ANTHROPIC_*/CLAUDE_* | 干净 / 异常 |
| 9 | VS Code 设置 | `settings.json` | [1m] 后缀 / disableLoginPrompt / 端口一致性 |
| 10 | LAN 连接 | `ipconfig` | 主 LAN IP / TUN 模式警告 / 虚拟适配器过滤 |
| 11 | 代理端口 | 环境变量/VS Code/系统代理/Clash API | 一致 / 不一致 |
| 12 | Claude Desktop | 安装路径 + 进程状态 | 已安装 / 未安装 |

输出包含汇总看板 + 修复建议。

### Mode 2: 认证重置

继承自 Fix-ClaudeAuth v3.1 的完整认证重置流程（7 步）：

0. 检测 Clash Verge 并自动切换至 Direct 模式
1. 终止 Claude / VSCode 进程
2. 清除认证文件（.credentials.json 等）
3. 清理全局设置文件（移除第三方 API 配置）
3.5. 检查修复 VS Code settings.json（[1m] 后缀、disableLoginPrompt）
4. 检查项目级设置
5. 清除用户级环境变量
6. 验证清理结果
7. 仅在 Auth Readiness 通过时启动干净登录窗口（自动恢复 Clash 模式）

新增行为：
- 登录前检查系统代理、环境变量代理、Clash API、DNS fake-IP（`198.18.0.0/15`）
- 若仍是 fake-IP / 系统代理 / 代理残留，直接阻止 `claude login`，避免再次触发 `15000ms timeout`
- 登录完成后自动读取 `oauthAccount.accountUuid` / `emailAddress` / `organizationUuid`
- 可选严格校验：`-ExpectedAccountUuid` / `-ExpectedEmail` / `-ExpectedOrgUuid`
- `accountUuid` 视为账号真相，邮箱仅作辅助展示

### Mode 3: 缓存清理

安全清理 `~/.claude/` 下的可删除数据，每类单独确认：

| 目录 | 说明 | 安全性 |
|------|------|--------|
| `debug/` | 调试转储文件 | 安全删除 |
| `file-history/` | 文件编辑历史 | 安全删除 |
| `shell-snapshots/` | Shell 状态快照 | 安全删除 |
| `telemetry/` | 遥测数据 | 安全删除 |
| `session-env/` | 会话环境 | 安全删除 |
| `cache/` | 缓存文件 | 安全删除 |
| IDE lock (过期) | PID 已死的锁文件 | 安全删除 |
| VS Code 旧日志 | >3 天的日志 | 安全删除 |
| `%TEMP%/claude/` | 临时文件 | 安全删除 |

`projects/`（会话记录）仅显示大小，不自动清理。

### Mode 4: 网络诊断

10+ 项网络检查：

1. **VPN/代理进程 & TUN 接口检测**
2. **系统代理配置**
3. **DNS 解析 + 泄漏检测**
4. **公网 IP 检查**
5. **TCP 连接测试**
6. **HTTPS 直连**（显式绕过系统代理，不再把系统代理下的请求误称为直连）
7. **HTTPS 代理**（通过检测到的代理 URL 测试）
8. **代理端口一致性审计**（VS Code / 环境变量 / Clash 配置端口比对）
9. **TLS 证书验证**（检测企业代理 MITM 拦截）
10. **LAN 跨设备 & TUN 模式检查**（v6.0 新增：TUN exclude-route 验证 + HTTP_PROXY LAN 干扰 + ARP 邻居发现）
11. **Fake-IP DNS 检测**（命中 `198.18.*` 时标记 `TUN intercepted`）
12. **Auth Readiness**（供 `Mode auth` 判断是否允许进入 OAuth 登录）

认证超时排查顺序：
1. Clash API 是否可达且已确认切到 Direct
2. 系统代理是否仍启用
3. `claude.ai` / `api.anthropic.com` 是否仍解析到 `198.18.*`
4. 再检查真直连 HTTP/TLS
5. 只有全部通过后才运行 `claude login`

### Mode 5: 设置重置

带备份的安全配置修复（7 项）：

1. VS Code 设置：移除 `[1m]` 后缀、修复 `disableLoginPrompt`、可选清除代理、Codex WSL 检测
2. 全局 `settings.json`：清理 `ANTHROPIC_*` 键（保留 hooks/permissions/plugins）
3. `settings.local.json`：清理异常键
4. 项目级设置扫描并清理
5. Claude Desktop 设置审计（v6.0 新增）
6. 代理端口交叉验证：扫描活跃代理端口，与 VS Code/环境变量配置对比（v6.0 新增）
7. MCP 认证缓存可选重置

### Mode 6: LAN 诊断

7 步跨设备连接排查流水线（对标 lan-toolkit MCP `lan_diagnose`）：

| # | 检查项 | 说明 | 修复 |
|---|--------|------|------|
| 1 | 本机 IP 检测 | 过滤虚拟适配器（VirtualBox/ICS），识别主 LAN IP | — |
| 2 | TUN 模式检测 | 198.18.x 检测 + Clash exclude-route 验证 | 手动指引 |
| 3 | 网络配置文件 | Public 网络阻止设备发现和文件共享 | 自动改 Private（需管理员） |
| 4 | 防火墙审计 | 检测 Node.js Block 规则 | 自动创建 Allow 规则（需管理员） |
| 5 | 目标设备测试 | Ping + TCP 端口探测（8789/18850/19000 等） | — |
| 6 | ARP 设备发现 | 子网 ARP 表扫描 + LAN toolkit 端口探测 | — |
| 7 | 代理 LAN 干扰 | HTTP_PROXY 设置但 NO_PROXY 缺 LAN 段 | 自动设 NO_PROXY |

部分修复需要管理员权限，非管理员时显示手动命令。

## 扩展开发

### 添加新模式

1. 在 `modules/` 下创建 `mode-xxx.ps1`，定义 `Invoke-XxxFunction`
2. 工具集主入口会自动检测可用模块（无需修改 `Claude-Toolkit.ps1`）
3. 在 `Claude-Toolkit.ps1` 的 `$optionalModules` 数组和 `Show-MainMenu` 中注册新模块

### 共享工具函数（utils.ps1）

| 函数 | 用途 |
|------|------|
| `Write-Status $Level $Message` | 统一色彩输出（OK/WARN/ERROR/INFO/SKIP/ACTION） |
| `Write-Section $Title $StepLabel` | 段落标题 |
| `Get-DirSize $Path` | 目录大小（返回 Bytes/Display/FileCount） |
| `Backup-File $FilePath` | 时间戳备份到 `~/.claude/backups/` |
| `Read-JsonSafe $FilePath` | JSON 读取（Python 优先 → PS 降级） |
| `Write-JsonSafe $FilePath $Json` | JSON 写入（先备份） |
| `Confirm-Action $Message` | 中文确认提示（默认 Yes） |
| `Clean-SettingsFile $Path $Label` | 三级降级 JSON 清理（Python/Regex/Reset） |
| `Get-ClaudeVersion` | Claude CLI 版本检测 |
| `Get-VscodeExtVersion` | VS Code 扩展版本检测 |
| `Test-ProcessRunning $ProcessId` | PID 存活检查 |
| `Find-PythonCmd` | Python 路径缓存 |

## 已知问题

- 终端中文显示依赖 PowerShell 窗口编码；通过 bash 管道捕获时中文会乱码（不影响功能）
- `projects/` 目录（会话记录）可能非常大（>3GB），Mode 3 仅提示不自动清理
- 本工具不会自动化网页登录，也不会管理浏览器密码；双账号场景默认采用手动 OAuth + 登录后强校验
- 本工具不修改 `~/.claude` 之外的外部多账号资产，仅消费 `accountUuid` 等本地状态做校验

## 版本历史

见 [CHANGELOG.md](CHANGELOG.md)。
