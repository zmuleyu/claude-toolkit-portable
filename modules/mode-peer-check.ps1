# mode-peer-check.ps1 — thin wrapper (v7.5)
# A<->B peer scan logic consolidated into mode-lan.ps1 in v7.5.
# Kept for backward compatibility with -Mode peer-check CLI flag.
# Invoke-LanDiagnostics (in mode-lan.ps1) now handles peer scanning.

function Invoke-PeerCheck {
    # Delegate to LAN diagnostics which includes peers.json scanning
    Invoke-LanDiagnostics
}
