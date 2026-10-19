@echo off
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\HenuAutoLogin\Monitor.ps1" -SkipPrompt -StartMinimized -OpenPanel
