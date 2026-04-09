# Clash Verge — Claude Code 登录断连根因总结

> 最后更新：2026-04-08
> 版本：v2（v1 方向错误，已全面修正）

---

## 症状

`claude login` 每次约 15 秒超时，反复重试无效。  
Toolkit 诊断显示 `Auth readiness: dns_fake_ip_active`。

---

## 根本原因

**Mihomo TUN + fake-IP 模式**把 `claude.ai` / `api.anthropic.com` 等域名解析成 `198.18.x.x`（虚假 IP），导致 OAuth 握手无法完成。

**真正应该修改的文件：**

```
%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\dns_config.yaml
```

这是 Clash Verge GUI "DNS 设置" 面板的持久化存储。  
当 `verge.yaml` 中 `enable_dns_settings: true` 时，该文件**全局覆盖所有 profile 的 dns 段**。

---

## ⚠️ 错误的修复方向（v1 误记录，勿参考）

- ~~修改 iKuuu_V2.yaml 的 dns/rules 段~~
- ~~修改任何 profile 或 merge 文件~~

profile 层 + merge 层的 `dns:` 段在 `enable_dns_settings: true` 时完全无效。  
在 merge 文件写 `MATCH,DIRECT` 还会破坏代理路由（所有流量走直连）。

---

## 正确修复步骤

### 一、备份并编辑 dns_config.yaml

```powershell
$cfg = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\dns_config.yaml"
Copy-Item $cfg "$cfg.bak.$(Get-Date -Format yyyyMMddHHmmss)"
```

在 `fake-ip-filter:` 列表末尾追加（在 `fake-ip-filter-mode:` 之前）：

```yaml
  - claude.ai
  - +.claude.ai
  - api.anthropic.com
  - +.anthropic.com
```

> `+.anthropic.com` 覆盖所有子域，无需逐个列出。

### 二、重启 Clash Verge

托盘菜单 → 退出 → 重新启动。  
（仅 reload profile 不够——dns_config.yaml 需进程重启才重新读取。）

### 三、验证

```powershell
nslookup claude.ai          # 应返回真实 IP，不是 198.18.x.x
nslookup api.anthropic.com  # 同上

# 或用 Toolkit 全面诊断
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "D:\tools\Claude-Toolkit-v5.0-Portable\Claude-Toolkit.ps1" -Mode network
# 期望：[OK] dns_config.yaml fake-ip-filter contains all anthropic entries
# 期望：Auth readiness: ready

claude login  # 应一次成功
```

---

## 防止重启复发

已部署 Task Scheduler 任务 `ClaudeCron\ClashDnsFilterCheck`：

| 触发条件 | 操作 |
|---|---|
| Windows 用户登录 | 自动检查 dns_config.yaml |
| 每天 09:07 | 自动检查 dns_config.yaml |

若 fake-ip-filter 缺少 Anthropic 条目，脚本自动追加并弹出 Toast 提醒重启 Clash Verge。

验证脚本：`D:\tools\Claude-Toolkit-v5.0-Portable\Verify-DnsFilter.ps1`  
重新注册任务：`D:\tools\Claude-Toolkit-v5.0-Portable\Register-DnsFilterCheck.ps1`

---

## Profile 层现状（无需修改）

| Profile | Merge 文件 | 状态 |
|---|---|---|
| Flower_SS.yaml (当前活动) | mtrPaL4iDWRC.yaml | 干净空模板，无需修改 |
| iKuuu_V2.yaml | m8MfMV1yU9og.yaml | 2026-04-08 已清理（移除破坏性 dns/rules/MATCH,DIRECT） |

路由层（prepend-rules）已正确把 anthropic/openai 流量导向 "AI Services" 代理组，无需额外配置。

---

## Toolkit 相关文件

| 文件 | 用途 |
|---|---|
| `modules/clash-fake-ip-fix.ps1` | fake-ip 检测/幂等修复/重启函数 |
| `modules/clash-helpers.ps1` | Clash 进程/模式检测 |
| `Verify-DnsFilter.ps1` | 开机守护脚本（Task Scheduler 调用） |
| `Register-DnsFilterCheck.ps1` | 一次性任务注册（需管理员） |
| `Run-Auth-Recovery.ps1` | 综合认证修复流程（包含 fake-ip 自动修补） |
