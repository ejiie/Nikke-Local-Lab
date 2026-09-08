param(
    [ValidateSet(
        'startup_only', 'server_selection', 'catalogue_path', 'lobby',
        'solo_raid_menu', 'season26_challenge_battle', 'battle_result'
    )]
    [string]$ObservedStageCode = 'startup_only',
    [ValidateSet('success', 'system_error', 'operator_abort', 'client_exit')]
    [string]$OutcomeCode = 'client_exit'
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\NLL\Tools\complete-phase3b2-epinel-user-progression-v2-in-micron.ps1' `
    -ObservedStageCode $ObservedStageCode `
    -OutcomeCode $OutcomeCode
