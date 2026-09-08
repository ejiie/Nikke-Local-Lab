@echo off
set "NLL_PHASE_D_INSTALL=C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\deploy-nll-phase-d-control-center-offline.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File ""%NLL_PHASE_D_INSTALL%""'"
