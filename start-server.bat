@echo off
setlocal
start "Emerald Co-Op server" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0scripts\start-server.ps1"
endlocal
