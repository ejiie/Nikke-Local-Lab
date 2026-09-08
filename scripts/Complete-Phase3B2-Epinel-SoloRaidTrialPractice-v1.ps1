#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet(
        'startup_only', 'server_selection', 'catalogue_path', 'lobby',
        'solo_raid_menu', 'season26_challenge_squad',
        'season26_challenge_battle', 'season26_practice_squad',
        'season26_practice_battle', 'battle_result'
    )]
    [string]$ObservedStageCode = 'startup_only',
    [ValidateSet('success', 'system_error', 'operator_abort', 'client_exit')]
    [string]$OutcomeCode = 'client_exit'
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process Bypass -Force
& 'C:\NLL\Tools\complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' `
    -ObservedStageCode $ObservedStageCode `
    -OutcomeCode $OutcomeCode
