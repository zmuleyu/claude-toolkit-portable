# constants.ps1 — Centralized path constants and configuration
# Part of Claude Code Diagnostic & Repair Toolkit v4.0

$SCRIPT_VERSION = "7.5"
$SCRIPT_EDITION = "Portable"

# ── Core Claude paths ──
$CLAUDE_HOME       = "$env:USERPROFILE\.claude"
$CREDENTIALS_FILE  = "$CLAUDE_HOME\.credentials.json"
$SETTINGS_FILE     = "$CLAUDE_HOME\settings.json"
$SETTINGS_LOCAL    = "$CLAUDE_HOME\settings.local.json"
$MCP_AUTH_CACHE    = "$CLAUDE_HOME\mcp-needs-auth-cache.json"
$MCP_REGISTRY      = "$CLAUDE_HOME\mcp-registry.json"
$IDE_LOCK_DIR      = "$CLAUDE_HOME\ide"
$DEBUG_DIR         = "$CLAUDE_HOME\debug"
$FILE_HISTORY_DIR  = "$CLAUDE_HOME\file-history"
$SHELL_SNAP_DIR    = "$CLAUDE_HOME\shell-snapshots"
$TELEMETRY_DIR     = "$CLAUDE_HOME\telemetry"
$PROJECTS_DIR      = "$CLAUDE_HOME\projects"
$SESSION_ENV_DIR   = "$CLAUDE_HOME\session-env"
$CACHE_DIR         = "$CLAUDE_HOME\cache"
$BACKUP_DIR        = "$CLAUDE_HOME\backups"
$PLUGINS_DIR       = "$CLAUDE_HOME\plugins"
$DATA_DIR          = "$CLAUDE_HOME\data"
$WORKTREE_DIR      = "$CLAUDE_HOME\worktrees"

# ── Claude Code Desktop paths ──
$CLAUDE_DESKTOP_PATHS = @(
    "$env:LOCALAPPDATA\Programs\claude-desktop",
    "$env:APPDATA\Claude",
    "$env:LOCALAPPDATA\AnthropicClaude"
)

# ── VS Code paths ──
$VSCODE_USER_DIR    = "$env:APPDATA\Code\User"
$VSCODE_SETTINGS   = "$env:APPDATA\Code\User\settings.json"
$VSCODE_EXT_DIR    = "$env:USERPROFILE\.vscode\extensions"
$VSCODE_LOGS_DIR   = "$env:APPDATA\Code\logs"
$VSCODE_GLOBAL_STORAGE_DIR = "$VSCODE_USER_DIR\globalStorage"
$VSCODE_WORKSPACE_STORAGE_DIR = "$VSCODE_USER_DIR\workspaceStorage"
$VSCODE_STATE_DB   = "$VSCODE_GLOBAL_STORAGE_DIR\state.vscdb"
$VSCODE_STATE_DB_BACKUP = "$VSCODE_GLOBAL_STORAGE_DIR\state.vscdb.backup"
$VSCODE_STORAGE_JSON = "$VSCODE_GLOBAL_STORAGE_DIR\storage.json"
$VSCODE_CLAUDE_USER_DIR = "$VSCODE_USER_DIR\Claude"

# ── Temp / Cache ──
$CLAUDE_TEMP_DIR   = "$env:LOCALAPPDATA\Temp\claude"
$NPM_CACHE_DIR     = "$env:LOCALAPPDATA\npm-cache"
$AUTH_BASELINE_DIR = "$BACKUP_DIR\auth-baselines"
$SUPPORT_BUNDLE_DIR = "$BACKUP_DIR\support-bundles"

# ── Test endpoints ──
$TEST_ENDPOINTS = @(
    @{ Name = "claude.ai";              Host = "claude.ai";              URL = "https://claude.ai" },
    @{ Name = "api.anthropic.com";      Host = "api.anthropic.com";      URL = "https://api.anthropic.com" },
    @{ Name = "statsig.anthropic.com";  Host = "statsig.anthropic.com";  URL = "https://statsig.anthropic.com" },
    @{ Name = "console.anthropic.com";  Host = "console.anthropic.com";  URL = "https://console.anthropic.com" },
    @{ Name = "api.openai.com";         Host = "api.openai.com";         URL = "https://api.openai.com" }
)

$AUTH_REQUIRED_ENDPOINTS = @(
    @{ Name = "claude.ai";         Host = "claude.ai";         URL = "https://claude.ai" },
    @{ Name = "api.anthropic.com"; Host = "api.anthropic.com"; URL = "https://api.anthropic.com" }
)

# ── Environment variable names to clear during auth reset ──
$BAD_ENV_KEYS = @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
)

# ── Proxy environment variable names ──
$PROXY_ENV_VARS = @(
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy'
)

# ── Proxy / VPN software process names ──
$PROXY_PROC_NAMES = @(
    "clash-verge", "clash-verge-rev", "ClashVerge", "clash-verge-service",
    "mihomo", "mihomo-party", "clash", "clash-meta", "clash.meta",
    "v2ray", "v2rayN", "xray", "sing-box",
    "naiveproxy", "trojan-go", "hysteria",
    "warp-svc", "openvpn", "wireguard", "nordvpn",
    "expressvpn", "surfshark", "lantern", "outline"
)

# ── Claude Code Desktop process names ──
$CLAUDE_CODE_DESKTOP_PROC = @("Claude Code", "claude-desktop", "Claude")

# ── LAN / Cross-device constants ──
$KNOWN_PROXY_PORTS = @(7890, 7897, 7898, 1080, 10809)
$TUN_IP_PREFIX = "198.18."
$FAKE_IP_REGEX = '^198\.18\.'
$VIRTUAL_ADAPTER_PREFIXES = @("192.168.137.", "192.168.56.")
$LAN_TOOLKIT_PORTS = @(8789, 18850, 18851, 18852, 18853, 18854, 18855, 18856, 18857, 18858, 18859)

# ── Public IP check URLs ──
$IP_CHECK_URLS = @(
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com"
)

# ── Suspect ISP DNS prefixes (China mainland) ──
$ISP_DNS_PREFIXES = @(
    "^114\.", "^223\.", "^180\.76", "^119\.29",
    "^182\.254", "^211\.", "^210\.", "^61\.", "^58\.", "^60\."
)

# ── Auth files to delete during reset ──
$AUTH_FILES = @(
    "$env:USERPROFILE\.claude\.credentials.json",
    "$env:USERPROFILE\.claude\auth.json",
    "$env:USERPROFILE\.claude\.auth.json",
    "$env:USERPROFILE\.claude\profiles\.active",
    "$env:APPDATA\Claude\auth.json",
    "$env:APPDATA\Claude\.credentials.json",
    "$env:LOCALAPPDATA\Claude\auth.json",
    "$env:LOCALAPPDATA\Claude\.credentials.json"
)

# ── VS Code Claude state keys to remove during reset ──
$VSCODE_CLAUDE_STATE_KEYS = @(
    "Anthropic.claude-code",
    "workbench.view.extension.claude-sessions-sidebar.state.hidden",
    "workbench.view.extension.claude-sidebar-secondary.state.hidden"
)

$VSCODE_CLAUDE_WORKSPACE_KEYS = @(
    "workbench.view.extension.claude-sessions-sidebar.state",
    "workbench.view.extension.claude-sidebar-secondary.state",
    "workbench.view.extension.claude-sidebar-secondary.numberOfVisibleViews",
    "memento/webviewView.claudeVSCodeSidebarSecondary"
)

# ── Cleanable directories (safe to delete contents) ──
$CLEANABLE_DIRS = @(
    @{ Path = $DEBUG_DIR;        Label = "调试转储 (debug)";            SafeToDelete = $true  },
    @{ Path = $FILE_HISTORY_DIR; Label = "文件历史 (file-history)";     SafeToDelete = $true  },
    @{ Path = $SHELL_SNAP_DIR;   Label = "Shell 快照 (shell-snapshots)";SafeToDelete = $true  },
    @{ Path = $TELEMETRY_DIR;    Label = "遥测数据 (telemetry)";        SafeToDelete = $true  },
    @{ Path = $SESSION_ENV_DIR;  Label = "会话环境 (session-env)";      SafeToDelete = $true  },
    @{ Path = $CACHE_DIR;        Label = "缓存 (cache)";               SafeToDelete = $true  }
)

# ── Extended cleanup targets (C盘瘦身) ──
$DEV_CACHE_DIRS = @(
    @{ Path = "$env:LOCALAPPDATA\npm-cache";    Label = "npm cache" },
    @{ Path = "$env:LOCALAPPDATA\pip\cache";    Label = "pip cache" },
    @{ Path = "$env:LOCALAPPDATA\pnpm\store";   Label = "pnpm store" },
    @{ Path = "$env:LOCALAPPDATA\yarn\Cache";   Label = "yarn cache" }
)

$VSCODE_CACHE_DIRS = @(
    @{ Path = "$env:APPDATA\Code\CachedData";            Label = "VS Code CachedData" },
    @{ Path = "$env:APPDATA\Code\CachedExtensions";      Label = "VS Code CachedExtensions" },
    @{ Path = "$env:APPDATA\Code\User\workspaceStorage"; Label = "VS Code workspaceStorage" }
)

$BROWSER_CACHE_DIRS = @(
    @{ Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache";          Label = "Chrome Cache" },
    @{ Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache";     Label = "Chrome CodeCache" },
    @{ Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Service Worker"; Label = "Chrome SW" },
    @{ Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache";         Label = "Edge Cache" }
)

$CODEX_CACHE_DIRS = @(
    @{ Path = "$env:USERPROFILE\.codex\cache";  Label = "Codex CLI cache" },
    @{ Path = "$env:USERPROFILE\.codex\log";    Label = "Codex CLI logs" },
    @{ Path = "$env:USERPROFILE\.codex\.tmp";   Label = "Codex CLI tmp" }
)

# ── Claude Electron app caches (Code desktop + Claude desktop) ──
$CLAUDE_ELECTRON_CACHE_DIRS = @(
    @{ Path = "$env:APPDATA\Claude\logs";                       Label = "Claude Code logs (app)" },
    @{ Path = "$env:APPDATA\Claude\Cache";                      Label = "Claude Code cache (app)" },
    @{ Path = "$env:LOCALAPPDATA\Claude\Cache";                 Label = "Claude Desktop cache" },
    @{ Path = "$env:LOCALAPPDATA\Claude\GPUCache";              Label = "Claude Desktop GPU cache" },
    @{ Path = "$env:LOCALAPPDATA\AnthropicClaude\Cache";        Label = "Claude Desktop cache (new)" },
    @{ Path = "$env:LOCALAPPDATA\AnthropicClaude\GPUCache";     Label = "Claude Desktop GPU (new)" },
    @{ Path = "$env:LOCALAPPDATA\Programs\claude-desktop\cache"; Label = "Claude Desktop program cache" }
)

$TEMP_DIRS = @(
    @{ Path = $env:TEMP;           Label = "User TEMP" },
    @{ Path = "C:\Windows\Temp";   Label = "System TEMP" }
)

# ── Settings keys that indicate OpenRouter / third-party config ──
$BAD_SETTINGS_KEYS = @(
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
    'apiBaseUrl',
    'authToken'
)
