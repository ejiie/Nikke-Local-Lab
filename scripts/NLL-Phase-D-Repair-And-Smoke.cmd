@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\invoke-nll-phase-d-repair-and-smoke.ps1"
echo.
if errorlevel 1 (
  echo Phase D repair or smoke failed. Keep this window open and report the error.
) else (
  echo Phase D repair and smoke passed.
)
pause
