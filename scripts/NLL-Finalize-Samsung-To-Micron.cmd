@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\Users\zih44\Documents\Github\Nikke-Local-Lab\scripts\invoke-finalize-samsung-to-micron-elevated.ps1"
if errorlevel 1 pause
endlocal

