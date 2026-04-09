# Claude-Toolkit-v5.0-Portable — Claude Code 便携工具箱

便携式 PowerShell 工具集，提供 Claude Code 的健康检查、认证重置、缓存清理、网络诊断等维护功能。当前版本重点修复重启后 `claude login` 15s timeout，并为双账号场景加入基于 `accountUuid` 的登录后强校验。无需安装，直接运行。

## 技术栈

- **语言**: PowerShell 5.1
- **入口**: `Claude-Toolkit.ps1`（主菜单）/ `run.bat`（快速启动）
- **模块**: `modules/`（各功能模块）
- **无 git 仓库**

## 结构

```
├── Claude-Toolkit.ps1    # 主入口（交互菜单）
├── run.bat               # CMD 快速启动
├── setup.ps1             # 初始化/安装
├── create-shortcut.ps1   # 创建桌面快捷方式
├── fix-claude-cli-auth.sh # CLI 认证修复（Git Bash）
└── modules/              # 功能模块（按需 dot-source）
```

## 使用方式

- 启动: `run.bat` 或 `powershell -File Claude-Toolkit.ps1`
- 严格账号校验: `powershell -File Claude-Toolkit.ps1 -Mode auth -ExpectedAccountUuid <uuid> -ExpectedEmail <email>`
- 创建桌面快捷方式: `powershell -File create-shortcut.ps1`

## 注意事项

- 此工具箱与 `C:\tools\claude-toolkit\` 不同（那个是正式版，这个是便携版）
- 内部路径有硬编码，重命名或移动目录前需检查
- 不要将此目录下的脚本用于自动化任务（用正式版替代）
- 清除 `HTTP_PROXY` / `HTTPS_PROXY` 不等于真直连；Windows 系统代理和 Clash TUN fake-IP 仍可能接管 `claude.ai`
- 双账号校验以 `oauthAccount.accountUuid` 为准，邮箱只作辅助展示；不要仅凭浏览器里看到的邮箱判断是否登录正确
- 本工具不会自动填写网页账号密码，也不会修改 `~/.claude` 目录外的多账号脚本/浏览器资产
