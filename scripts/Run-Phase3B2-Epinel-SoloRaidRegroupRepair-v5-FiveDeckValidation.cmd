@echo off
setlocal EnableExtensions

title NLL Season 26 Solo Raid v5 - Five Deck Validation

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "NLL_START=C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1"
set "NLL_COMPLETE=C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1"

if not exist "%NLL_START%" goto missing
if not exist "%NLL_COMPLETE%" goto missing

echo.
echo [1/3] Starting the sealed Season 26 Challenge v5 lane...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%NLL_START%" -ValidationKind Challenge
if errorlevel 1 goto start_failed

echo.
echo [2/3] Keep this window open and use the game window.
echo Complete all five Challenge squads in sequence.
echo Verify squad transitions, the final result, My Records, and the three-entry daily state.
echo When finished, CLOSE THE NIKKE CLIENT before returning here.
echo.

:ask_result
set "NLL_RESULT="
set /p "NLL_RESULT=Type COMPLETE after a full five-squad result, or ABORT to preserve an incomplete run: "
if /i "%NLL_RESULT%"=="COMPLETE" goto complete_success
if /i "%NLL_RESULT%"=="ABORT" goto complete_abort
echo Please type COMPLETE or ABORT.
goto ask_result

:complete_success
echo.
echo [3/3] Completing the run as a successful battle result...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%NLL_COMPLETE%" -ObservedStageCode battle_result -OutcomeCode success
if errorlevel 1 goto completion_failed
goto done

:complete_abort
echo.
echo [3/3] Completing the run as an operator abort...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%NLL_COMPLETE%" -ObservedStageCode season26_challenge_squad -OutcomeCode operator_abort
if errorlevel 1 goto completion_failed
goto done

:missing
echo ERROR: The sealed v5 start or completion tool is missing.
goto failed

:start_failed
echo ERROR: The v5 start failed. Do not launch the game manually.
goto failed

:completion_failed
echo ERROR: Completion failed. Preserve this window and the error output.
goto failed

:done
echo.
echo Validation run completed and runtime cleanup succeeded.
pause
exit /b 0

:failed
echo.
pause
exit /b 1
