# Create desktop shortcut for Claude Toolkit
$ToolkitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\Claude Toolkit.lnk")
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ToolkitRoot\Claude-Toolkit.ps1`""
$Shortcut.WorkingDirectory = $ToolkitRoot
$Shortcut.Description = "Claude Code Diagnostic & Repair Toolkit v6.0 Portable"
$Shortcut.IconLocation = "powershell.exe,0"
$Shortcut.Save()
Write-Host "Desktop shortcut created: $env:USERPROFILE\Desktop\Claude Toolkit.lnk" -ForegroundColor Green
Write-Host "Toolkit location: $ToolkitRoot" -ForegroundColor DarkGray
