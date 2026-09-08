@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0invoke-materialize-samsung-state-on-micron-elevated.ps1"
if errorlevel 1 pause
endlocal

