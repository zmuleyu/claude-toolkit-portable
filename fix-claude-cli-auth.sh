#!/usr/bin/env bash
# fix-claude-cli-auth.sh
# Target: WSL2 Ubuntu + Clash Verge (port 7890) + Claude CLI OAuth 403
set -euo pipefail

PROXY="http://127.0.0.1:7890"
AUTH_FILE="$HOME/.claude/auth.json"
CONFIG_FILE="$HOME/.claude.json"

echo "=== Claude CLI 403 Auth Fix ==="

# ── Step 1: Detect environment ──────────────────────────────────────────────
IS_WSL=false
[[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] && IS_WSL=true
echo "[1] WSL2 detected: $IS_WSL"

if $IS_WSL; then
  WIN_HOST=$(grep nameserver /etc/resolv.conf | awk '{print $2}')
  if curl -s --max-time 3 --proxy "http://${WIN_HOST}:7890" https://api.anthropic.com > /dev/null 2>&1; then
    PROXY="http://${WIN_HOST}:7890"
    echo "[1] Using Windows host proxy: $PROXY"
  else
    echo "[1] Fallback to localhost proxy: $PROXY"
  fi
fi

# ── Step 2: Verify proxy is alive ────────────────────────────────────────────
echo "[2] Testing proxy connectivity..."
HTTP_CODE=$(curl -s --max-time 5 --proxy "$PROXY" -o /dev/null -w "%{http_code}" https://api.anthropic.com || true)
if echo "$HTTP_CODE" | grep -qE "^(200|301|302|403|404)"; then
  echo "[2] Proxy OK (HTTP $HTTP_CODE) → $PROXY can reach api.anthropic.com"
else
  echo "[2] ERROR: Proxy unreachable (HTTP $HTTP_CODE)."
  echo "    → Clash Verge: Rule 模式 + Allow LAN ON + api.anthropic.com 走 US 节点"
  exit 1
fi

# ── Step 3: Clear corrupted auth cache ───────────────────────────────────────
echo "[3] Clearing auth cache..."
if [[ -f "$AUTH_FILE" ]]; then
  cp "$AUTH_FILE" "${AUTH_FILE}.bak.$(date +%s)"
  rm -f "$AUTH_FILE"
  echo "[3] Removed $AUTH_FILE (backup kept)"
else
  echo "[3] No auth cache found, skipping"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  python3 - <<PYEOF
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
for key in ['oauthToken', 'sessionToken', 'accessToken']:
    cfg.pop(key, None)
with open('$CONFIG_FILE', 'w') as f:
    json.dump(cfg, f, indent=2)
print('[3] Cleaned token fields from $CONFIG_FILE')
PYEOF
else
  echo "[3] No ~/.claude.json found, skipping"
fi

# ── Step 4: Inject proxy env vars ────────────────────────────────────────────
echo "[4] Setting proxy environment variables..."
export HTTP_PROXY="$PROXY"
export HTTPS_PROXY="$PROXY"
export http_proxy="$PROXY"
export https_proxy="$PROXY"
export ANTHROPIC_PROXY="$PROXY"
export NODE_TLS_REJECT_UNAUTHORIZED="0"
echo "[4] Proxy vars injected: $PROXY"

# ── Step 5: WSL2 browser fix ─────────────────────────────────────────────────
if $IS_WSL; then
  echo "[5] WSL2: configuring browser for OAuth callback..."
  if command -v wslview &>/dev/null; then
    export BROWSER="wslview"
    echo "[5] Using wslview"
  elif [[ -f "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" ]]; then
    export BROWSER="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
    echo "[5] Using Windows Chrome"
  elif [[ -f "/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" ]]; then
    export BROWSER="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
    echo "[5] Using Windows Edge"
  else
    echo "[5] WARNING: No Windows browser detected; OAuth may fail silently"
  fi
else
  echo "[5] Not WSL2, skipping browser config"
fi

# ── Step 6: Persist proxy to ~/.claude/settings.json ─────────────────────────
echo "[6] Writing proxy to ~/.claude/settings.json..."
mkdir -p ~/.claude
SETTINGS_FILE="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  python3 - <<PYEOF
import json
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
s['proxy'] = '$PROXY'
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
print('[6] Updated existing settings.json')
PYEOF
else
  printf '{"proxy": "%s"}\n' "$PROXY" > "$SETTINGS_FILE"
  echo "[6] Created ~/.claude/settings.json"
fi

# ── Step 7: Re-authenticate ───────────────────────────────────────────────────
echo ""
echo "=== Starting OAuth login (browser will open) ==="
echo "    完成浏览器中的登录后脚本自动继续"
echo ""
claude auth login

# ── Step 8: Verify ───────────────────────────────────────────────────────────
echo ""
echo "[8] Verifying..."
if HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" claude --version > /dev/null 2>&1; then
  echo ""
  echo "✅ Claude CLI working:"
  claude --version
else
  echo ""
  echo "❌ Still failing. Manual fallback:"
  echo "   HTTP_PROXY=$PROXY HTTPS_PROXY=$PROXY claude auth login"
  echo ""
  echo "Checklist:"
  echo "  [ ] Clash Verge → Rule 模式（非 Global）"
  echo "  [ ] Allow LAN: ON"
  echo "  [ ] api.anthropic.com 规则命中 US 节点（不走 DIRECT）"
  echo "  [ ] Max 订阅账号与 CLI 登录账号一致"
  exit 1
fi
