[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$RepositoryRoot = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab',
    [ValidateRange(1024, 65535)] [int]$DatabasePort = 55433,
    [ValidateRange(1024, 65535)] [int]$AdminPort = 17878,
    [switch]$OverloadSignOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Repair {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Unprotect-RepairSecret {
    param([string]$Path)
    $protected = [IO.File]::ReadAllBytes($Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        [Array]::Clear($entropy, 0, $entropy.Length)
    }
}

function Test-RepairPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        $task.Wait(800) -and $client.Connected
    }
    catch { $false }
    finally { $client.Dispose() }
}

function Invoke-RepairJson {
    param(
        [string]$Uri,
        [ValidateSet('Post','Put')] [string]$Method = 'Post',
        [Collections.IDictionary]$Body,
        [string]$IfMatch,
        [string]$BaseUri,
        [string]$CsrfToken,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession
    )
    try {
        Invoke-RestMethod `
            -Uri $Uri `
            -Method $Method `
            -ContentType 'application/json' `
            -Headers @{
                Origin = $BaseUri
                'X-NLL-CSRF' = $CsrfToken
                'If-Match' = ('"' + $IfMatch + '"')
            } `
            -Body ($Body | ConvertTo-Json -Depth 8 -Compress) `
            -WebSession $WebSession
    }
    catch {
        $responseCode = $null
        if ($null -ne $_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = [IO.StreamReader]::new($stream)
                try {
                    $payload = $reader.ReadToEnd() | ConvertFrom-Json
                    $responseCode = [string]$payload.code
                }
                finally {
                    $reader.Dispose()
                    $stream.Dispose()
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($responseCode)) {
            throw ('phase_d_profile_applicability_repair_api_rejected:' + $responseCode)
        }
        throw
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-Repair (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
    $env:USERNAME -ceq 'nlloperator' -and
    $env:SystemDrive -ceq 'C:') 'phase_d_profile_applicability_repair_boundary_invalid'
Assert-Repair (
    @(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_d_profile_applicability_repair_runtime_not_cold'
Assert-Repair (
    -not (Test-RepairPort $DatabasePort) -and
    -not (Test-RepairPort $AdminPort)) 'phase_d_profile_applicability_repair_port_in_use'

$pgCtl = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$psql = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\psql.exe'
$dataRoot = Join-Path $InstallRoot 'postgresql\data'
$postgresLog = Join-Path $InstallRoot 'logs\postgresql.log'
$bootstrapPath = Join-Path $InstallRoot 'session\applicability-repair-bootstrap.secret'
$adminStdout = Join-Path $InstallRoot 'logs\applicability-repair-admin.stdout.log'
$adminStderr = Join-Path $InstallRoot 'logs\applicability-repair-admin.stderr.log'
$databasePassword = Unprotect-RepairSecret (
    Join-Path $InstallRoot 'secrets\database-password.dpapi')
$identitySecret = Unprotect-RepairSecret (
    Join-Path $InstallRoot 'secrets\identity-secret.dpapi')
$postgresStarted = $false
$admin = $null
$accountReceipts = @()

try {
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=$DatabasePort;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_ID_SECRET = $identitySecret
    $env:NIKKE_LAB_HOME = Join-Path $InstallRoot 'runtime-home'
    $env:NIKKE_LAB_PROFILE_RAW = 'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json'
    $env:NLL_CONTROL_CENTER_BOOTSTRAP_PATH = $bootstrapPath
    $env:NLL_CONTROL_CENTER_PG_CTL = $pgCtl
    $env:NLL_CONTROL_CENTER_PG_DATA = $dataRoot
    $env:NLL_CONTROL_CENTER_PG_LOG = $postgresLog
    $env:NLL_PHASE_D_CONTROL_CENTER = '1'
    $env:PGPASSWORD = $databasePassword

    New-Item -ItemType Directory -Path (Split-Path -Parent $bootstrapPath) -Force | Out-Null
    & $pgCtl start -D $dataRoot -l $postgresLog -w -t 60
    Assert-Repair ($LASTEXITCODE -eq 0) 'phase_d_profile_applicability_repair_postgresql_start_failed'
    $postgresStarted = $true

    $draftRows = @(& $psql `
        -h 127.0.0.1 `
        -p $DatabasePort `
        -U nll_control_center `
        -d nll_control_center `
        -X `
        -A `
        -t `
        -F '|' `
        -v ON_ERROR_STOP=1 `
        -c @'
WITH ranked AS (
    SELECT
        account.local_account_uid,
        draft.sanitized_profile_draft_uid,
        encode(draft.canonical_payload_sha256, 'hex') AS draft_sha256,
        draft.canonical_payload_json::jsonb #>>
            '{builds,0,level,authority_policy_code}' AS level_authority_policy,
        row_number() OVER (
            PARTITION BY application.result_local_account_id
            ORDER BY application.applied_at_utc DESC,
                     application.profile_draft_application_id DESC
        ) AS rank
    FROM lab_local_game.profile_draft_application AS application
    JOIN lab_local_game.profile_draft_diff AS diff
      ON diff.profile_draft_diff_id = application.profile_draft_diff_id
    JOIN lab_local_game.sanitized_profile_draft AS draft
      ON draft.sanitized_profile_draft_id = diff.sanitized_profile_draft_id
    JOIN lab_profile.local_account AS account
      ON account.local_account_id = application.result_local_account_id
)
SELECT
    local_account_uid::text,
    sanitized_profile_draft_uid::text,
    draft_sha256,
    level_authority_policy
FROM ranked
WHERE rank = 1
ORDER BY local_account_uid;
'@)
    Assert-Repair ($LASTEXITCODE -eq 0) 'phase_d_profile_applicability_repair_draft_query_failed'
    $draftRows = @($draftRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-Repair ($draftRows.Count -gt 0) 'phase_d_profile_applicability_repair_draft_missing'

    $tier9ManufacturerRows = @(& $psql `
        -h 127.0.0.1 `
        -p $DatabasePort `
        -U nll_control_center `
        -d nll_control_center `
        -X `
        -A `
        -t `
        -F '|' `
        -v ON_ERROR_STOP=1 `
        -c @'
SELECT
    account.local_account_uid::text,
    character.character_uid::text,
    'equipment.' || equipment.slot_code || '.manufacturer_matched',
    CASE
        WHEN equipment_detail.manufacturer_status = 'not_applicable'
        THEN 'not_applicable'
        WHEN equipment_detail.manufacturer_code = character_version.manufacturer_code
        THEN 'true'
        ELSE 'false'
    END
FROM lab_profile.local_account AS account
JOIN lab_profile.profile_template_revision AS profile_revision
  ON profile_revision.profile_template_revision_id =
      account.current_profile_template_revision_id
JOIN lab_profile.profile_template_revision_build AS profile_build
  ON profile_build.profile_template_revision_id =
      profile_revision.profile_template_revision_id
JOIN lab_profile.character_build_revision AS build_revision
  ON build_revision.build_revision_id = profile_build.build_revision_id
JOIN lab_catalog.character_entity AS character
  ON character.character_entity_id = build_revision.character_entity_id
JOIN lab_catalog.character_definition_version AS character_version
  ON character_version.character_definition_version_id =
      build_revision.character_definition_version_id
JOIN lab_profile.build_equipment_state AS equipment
  ON equipment.build_revision_id = build_revision.build_revision_id
JOIN lab_combat_support.equipment_definition_detail AS equipment_detail
  ON equipment_detail.definition_version_id = equipment.definition_version_id
WHERE equipment.equipment_state = 'equipped'
  AND equipment.manufacturer_matched_status = 'unresolved'
  AND equipment.manufacturer_matched_unresolved_reason_code =
      'equipment_manufacturer_observation_missing'
  AND equipment_detail.tier_status = 'ready'
  AND equipment_detail.tier_value = 9
  AND (
      equipment_detail.manufacturer_status = 'not_applicable'
      OR (
          equipment_detail.manufacturer_status = 'ready'
          AND character_version.manufacturer_status = 'ready'
      )
  )
ORDER BY account.local_account_uid, character.character_uid, equipment.slot_code;
'@)
    Assert-Repair ($LASTEXITCODE -eq 0) `
        'phase_d_profile_applicability_repair_tier9_query_failed'
    $tier9ManufacturerRows = @($tier9ManufacturerRows |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $draftByAccount = @{}
    foreach ($row in $draftRows) {
        $parts = $row.Split('|')
        Assert-Repair ($parts.Count -eq 4) 'phase_d_profile_applicability_repair_draft_row_invalid'
        Assert-Repair (
            $parts[3] -in @('roster_observation/v1','detail_observation/v1')) `
            'phase_d_profile_applicability_repair_level_authority_invalid'
        $draftByAccount[$parts[0]] = [pscustomobject]@{
            draftUid = $parts[1]
            draftSha256 = $parts[2]
            levelAuthorityPolicy = $parts[3]
        }
    }
    $tier9ManufacturerByAccount = @{}
    foreach ($row in $tier9ManufacturerRows) {
        $parts = $row.Split('|')
        Assert-Repair (
            $parts.Count -eq 4 -and
            $parts[2] -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$' -and
            $parts[3] -in @('true','false','not_applicable')) `
            'phase_d_profile_applicability_repair_tier9_row_invalid'
        if (-not $tier9ManufacturerByAccount.ContainsKey($parts[0])) {
            $tier9ManufacturerByAccount[$parts[0]] = @()
        }
        $tier9ManufacturerByAccount[$parts[0]] += [pscustomobject]@{
            subjectUid = $parts[1]
            fieldCode = $parts[2]
            resolutionKind = $parts[3]
            booleanValue = if ($parts[3] -ceq 'not_applicable') {
                $null
            }
            else {
                $parts[3] -ceq 'true'
            }
        }
    }

    $admin = Start-Process -FilePath 'C:\Program Files\dotnet\dotnet.exe' `
        -ArgumentList @(
            (Join-Path $InstallRoot 'app\NikkeLocalLab.Admin.Api.dll'),
            '--config', (Join-Path $RepositoryRoot 'config\appsettings.example.json'),
            '--repository-root', $RepositoryRoot,
            '--phase-d-control-center', 'true') `
        -RedirectStandardOutput $adminStdout `
        -RedirectStandardError $adminStderr `
        -WindowStyle Hidden `
        -PassThru
    for ($index = 0; $index -lt 150 -and -not $admin.HasExited -and
        -not (Test-Path -LiteralPath $bootstrapPath); $index++) {
        Start-Sleep -Milliseconds 200
    }
    Assert-Repair (
        -not $admin.HasExited -and
        (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) `
        'phase_d_profile_applicability_repair_admin_start_failed'

    $bootstrapCode = (Get-Content -LiteralPath $bootstrapPath -Raw).Trim()
    Assert-Repair (-not [string]::IsNullOrWhiteSpace($bootstrapCode)) `
        'phase_d_profile_applicability_repair_bootstrap_missing'
    Remove-Item -LiteralPath $bootstrapPath -Force

    $baseUri = "http://127.0.0.1:$AdminPort"
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $bootstrapResponse = Invoke-WebRequest `
        -UseBasicParsing `
        -Uri ($baseUri + '/admin-auth/v1/bootstrap') `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Origin = $baseUri } `
        -Body (@{ code = $bootstrapCode } | ConvertTo-Json -Compress) `
        -WebSession $webSession
    Assert-Repair ($bootstrapResponse.StatusCode -eq 204) `
        'phase_d_profile_applicability_repair_bootstrap_exchange_failed'
    $sessionMatch = [regex]::Match(
        [string]$bootstrapResponse.Headers['Set-Cookie'],
        '(?:^|,\s*)nll_admin_session=([^;]+)')
    Assert-Repair $sessionMatch.Success `
        'phase_d_profile_applicability_repair_session_cookie_missing'
    $sessionCookie = New-Object Net.Cookie(
        'nll_admin_session',
        $sessionMatch.Groups[1].Value,
        '/admin-api',
        '127.0.0.1')
    $sessionCookie.HttpOnly = $true
    $webSession.Cookies.Add($sessionCookie)

    $csrfResponse = Invoke-RestMethod `
        -Uri ($baseUri + '/admin-api/v1/security/csrf') `
        -WebSession $webSession
    $csrfToken = [string]$csrfResponse.requestToken
    Assert-Repair (-not [string]::IsNullOrWhiteSpace($csrfToken)) `
        'phase_d_profile_applicability_repair_csrf_missing'

    $accountResponse = Invoke-RestMethod `
        -Uri ($baseUri + '/admin-api/v1/accounts') `
        -WebSession $webSession
    $accounts = @($accountResponse | ForEach-Object { $_ })
    Assert-Repair ($accounts.Count -gt 0) `
        'phase_d_profile_applicability_repair_account_missing'
    $uniqueDrafts = @($draftByAccount.Values |
        Group-Object draftUid |
        ForEach-Object { $_.Group[0] })

    foreach ($account in $accounts) {
        $accountUid = [string]$account.accountUid
        if ($draftByAccount.ContainsKey($accountUid)) {
            $draft = $draftByAccount[$accountUid]
        }
        else {
            # Save-as profiles can have no sanitized-draft application of their
            # own. Reuse the sole source draft only as a preview candidate; the
            # strict 321-change allowlist below still fails closed if this copy
            # has diverged in any other field.
            Assert-Repair ($uniqueDrafts.Count -eq 1) `
                'phase_d_profile_applicability_repair_account_draft_ambiguous'
            $draft = $uniqueDrafts[0]
        }
        $escapedAccountUid = [Uri]::EscapeDataString($accountUid)
        $escapedDraftUid = [Uri]::EscapeDataString([string]$draft.draftUid)
        $profile = Invoke-RestMethod `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile") `
            -WebSession $webSession
        $expectedRevisionUid = [string]$profile.profileRevision.revisionUid
        Assert-Repair (-not [string]::IsNullOrWhiteSpace($expectedRevisionUid)) `
            'phase_d_profile_applicability_repair_profile_revision_missing'

        if ($OverloadSignOnly) {
            $currentCandidate = Invoke-RestMethod `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/runtime-projection-candidate") `
                -WebSession $webSession
            $currentUnresolvedCount = @($currentCandidate.values | Where-Object {
                $_.status -ceq 'unresolved'
            }).Count
            $negativeOverloadValues = @($currentCandidate.values | Where-Object {
                $_.status -ceq 'ready' -and
                [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$' -and
                $null -ne $_.unscaledValue -and
                [long]$_.unscaledValue -lt 0
            })
            if ($negativeOverloadValues.Count -eq 0) {
                $accountReceipts += [pscustomobject]@{
                    accountUid = $accountUid
                    draftUid = [string]$draft.draftUid
                    previousProfileRevisionUid = $expectedRevisionUid
                    resultProfileRevisionUid = $expectedRevisionUid
                    resultProfileRevisionNumber = [int]$profile.profileRevision.revisionNumber
                    alreadyResolved = $true
                    convertedBondFactCount = 0
                    convertedEquipmentManufacturerFactCount = 0
                    resolvedTier9ManufacturerFactCount = 0
                    normalizedOverloadSignCount = 0
                    remainingNegativeOverloadApplicationValueCount = 0
                    remainingTargetUnresolvedCount = $currentUnresolvedCount
                    resultingTargetNotApplicableCount = 0
                }
                continue
            }

            Assert-Repair ($negativeOverloadValues.Count -le 512) `
                'phase_d_overload_sign_repair_operation_limit_exceeded'
            $signOperations = @($negativeOverloadValues | ForEach-Object {
                [ordered]@{
                    fieldCode = [string]$_.fieldCode
                    subjectUid = [string]$_.subjectUid
                    valueKind = 'exact_decimal'
                    unscaledValue = [Math]::Abs([long]$_.unscaledValue)
                    decimalScale = [int]$_.decimalScale
                }
            })
            $signPreview = Invoke-RepairJson `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile/preview") `
                -Body ([ordered]@{
                    operationUid = [guid]::NewGuid().ToString('D')
                    operations = $signOperations
                }) `
                -IfMatch $expectedRevisionUid `
                -BaseUri $baseUri `
                -CsrfToken $csrfToken `
                -WebSession $webSession
            $signChanges = @($signPreview.changes)
            $safeSignChanges = @($signChanges | Where-Object {
                [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$' -and
                [string]$_.before.status -ceq 'ready' -and
                [string]$_.after.status -ceq 'ready' -and
                [int]$_.before.decimalScale -eq [int]$_.after.decimalScale -and
                [long]$_.before.unscaledValue -lt 0 -and
                [long]$_.after.unscaledValue -eq [Math]::Abs([long]$_.before.unscaledValue)
            })
            Assert-Repair (
                $signChanges.Count -eq $negativeOverloadValues.Count -and
                $safeSignChanges.Count -eq $signChanges.Count -and
                @($signPreview.issues | Where-Object { $_.severity -ceq 'error' }).Count -eq 0) `
                'phase_d_overload_sign_repair_preview_scope_invalid'
            $signApply = Invoke-RepairJson `
                -Method Put `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile") `
                -Body ([ordered]@{
                    operationUid = [guid]::NewGuid().ToString('D')
                    candidateDraftUid = [string]$signPreview.candidateDraftUid
                    candidateSha256 = [string]$signPreview.candidateSha256
                    expectedDiffSha256 = [string]$signPreview.diffSha256
                }) `
                -IfMatch $expectedRevisionUid `
                -BaseUri $baseUri `
                -CsrfToken $csrfToken `
                -WebSession $webSession
            $resultCandidate = Invoke-RestMethod `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/runtime-projection-candidate") `
                -WebSession $webSession
            $remainingNegative = @($resultCandidate.values | Where-Object {
                $_.status -ceq 'ready' -and
                [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$' -and
                $null -ne $_.unscaledValue -and
                [long]$_.unscaledValue -lt 0
            })
            $resultUnresolvedCount = @($resultCandidate.values | Where-Object {
                $_.status -ceq 'unresolved'
            }).Count
            Assert-Repair (
                $remainingNegative.Count -eq 0 -and
                $resultUnresolvedCount -eq $currentUnresolvedCount) `
                'phase_d_overload_sign_repair_postcondition_failed'
            $accountReceipts += [pscustomobject]@{
                accountUid = $accountUid
                draftUid = [string]$draft.draftUid
                editorCandidateDraftUid = [string]$signPreview.candidateDraftUid
                previousProfileRevisionUid = $expectedRevisionUid
                resultProfileRevisionUid = [string]$signApply.profileRevision.revisionUid
                resultProfileRevisionNumber = [int]$signApply.profileRevision.revisionNumber
                alreadyResolved = $false
                convertedBondFactCount = 0
                convertedEquipmentManufacturerFactCount = 0
                resolvedTier9ManufacturerFactCount = 0
                normalizedOverloadSignCount = $safeSignChanges.Count
                remainingNegativeOverloadApplicationValueCount = $remainingNegative.Count
                remainingTargetUnresolvedCount = $resultUnresolvedCount
                resultingTargetNotApplicableCount = 0
            }
            continue
        }

        $preview = Invoke-RepairJson `
            -Uri ($baseUri + "/admin-api/v1/import-drafts/$escapedDraftUid/diff") `
            -Body ([ordered]@{
                operationUid = [guid]::NewGuid().ToString('D')
                expectedDraftSha256 = [string]$draft.draftSha256
                targetAccountUid = $accountUid
                levelAuthorityPolicy = [string]$draft.levelAuthorityPolicy
                scopes = @('full_profile')
            }) `
            -IfMatch $expectedRevisionUid `
            -BaseUri $baseUri `
            -CsrfToken $csrfToken `
            -WebSession $webSession

        $changes = @($preview.changes)
        $bondChanges = @($changes | Where-Object {
            [string]$_.fieldCode -ceq 'bond_level'
        })
        $manufacturerChanges = @($changes | Where-Object {
            [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$'
        })
        $safeApplicabilityChanges = @($changes | Where-Object {
            ([string]$_.fieldCode -ceq 'bond_level' -or
             [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$') -and
            [string]$_.before.status -ceq 'unresolved' -and
            [string]$_.after.status -ceq 'not_applicable' -and
            $null -eq $_.after.integerValue -and
            $null -eq $_.after.booleanValue -and
            $null -eq $_.after.reasonCode
        })
        $overloadValueChanges = @($changes | Where-Object {
            [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$'
        })
        $safeOverloadSignChanges = @($overloadValueChanges | Where-Object {
            $beforeValue = [long]$_.before.unscaledValue
            $afterValue = [long]$_.after.unscaledValue
            [string]$_.before.status -ceq 'ready' -and
            [string]$_.after.status -ceq 'ready' -and
            [int]$_.before.decimalScale -eq 4 -and
            [int]$_.after.decimalScale -eq 4 -and
            $beforeValue -ne 0 -and
            $beforeValue -eq (0 - $afterValue)
        })
        $overloadSameMagnitudeChanges = @($overloadValueChanges | Where-Object {
            $beforeValue = [long]$_.before.unscaledValue
            $afterValue = [long]$_.after.unscaledValue
            [Math]::Abs($beforeValue) -eq [Math]::Abs($afterValue)
        })
        $overloadScaleChanges = @($overloadValueChanges | Where-Object {
            [int]$_.before.decimalScale -ne [int]$_.after.decimalScale
        })
        $overloadMagnitudeChanges = @($overloadValueChanges | Where-Object {
            $beforeValue = [long]$_.before.unscaledValue
            $afterValue = [long]$_.after.unscaledValue
            [Math]::Abs($beforeValue) -ne [Math]::Abs($afterValue)
        })
        $otherChanges = @($changes | Where-Object {
            $_ -notin $safeApplicabilityChanges -and
            $_ -notin $overloadValueChanges
        })
        $otherFieldSummary = @($otherChanges |
            Group-Object -Property fieldCode |
            Sort-Object -Property Count -Descending |
            ForEach-Object { ([string]$_.Name + '=' + [string]$_.Count) }) -join ';'
        $overloadMagnitudeSummary = @($overloadMagnitudeChanges | ForEach-Object {
            [string]$_.fieldCode + ':' +
            [string]$_.before.unscaledValue + 'e-' + [string]$_.before.decimalScale + '->' +
            [string]$_.after.unscaledValue + 'e-' + [string]$_.after.decimalScale
        }) -join ';'
        $safeChanges = @($safeApplicabilityChanges) + @($safeOverloadSignChanges)
        Assert-Repair (@($preview.issues | Where-Object { $_.severity -ceq 'error' }).Count -eq 0) `
            'phase_d_profile_applicability_repair_preview_conflict'

        $currentCandidate = Invoke-RestMethod `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/runtime-projection-candidate") `
            -WebSession $webSession
        $currentTargetUnresolved = @($currentCandidate.values | Where-Object {
            $_.status -ceq 'unresolved' -and
            ([string]$_.fieldCode -ceq 'bond_level' -or
             [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$')
        })
        $currentNotApplicable = @($currentCandidate.values | Where-Object {
            $_.status -ceq 'not_applicable' -and
            ([string]$_.fieldCode -ceq 'bond_level' -or
             [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$')
        })
        $tier9ManufacturerChanges = @(if (
            $tier9ManufacturerByAccount.ContainsKey($accountUid)) {
            $tier9ManufacturerByAccount[$accountUid] | ForEach-Object { $_ }
        })
        $tier9NotApplicableChanges = @($tier9ManufacturerChanges | Where-Object {
            [string]$_.resolutionKind -ceq 'not_applicable'
        })
        $currentTargetKeys = @{}
        foreach ($value in $currentTargetUnresolved) {
            $currentTargetKeys[([string]$value.fieldCode + '|' +
                [string]$value.subjectUid)] = $true
        }
        $tier9MissingFromCandidate = @($tier9ManufacturerChanges | Where-Object {
            -not $currentTargetKeys.ContainsKey(
                ([string]$_.fieldCode + '|' + [string]$_.subjectUid))
        })
        $repairableTargetKeys = @{}
        foreach ($change in @($safeApplicabilityChanges) + @($tier9ManufacturerChanges)) {
            $repairableTargetKeys[([string]$change.fieldCode + '|' +
                [string]$change.subjectUid)] = $true
        }
        $candidateMissingFromRepair = @($currentTargetUnresolved | Where-Object {
            -not $repairableTargetKeys.ContainsKey(
                ([string]$_.fieldCode + '|' + [string]$_.subjectUid))
        })
        if ($tier9MissingFromCandidate.Count -ne 0 -or
            $currentTargetUnresolved.Count -ne (
                $safeApplicabilityChanges.Count + $tier9ManufacturerChanges.Count)) {
            $tier9MissingCoordinates = @($tier9MissingFromCandidate | ForEach-Object {
                [string]$_.fieldCode + '|' + [string]$_.subjectUid
            }) -join ','
            $candidateMissingCoordinates = @($candidateMissingFromRepair | ForEach-Object {
                [string]$_.fieldCode + '|' + [string]$_.subjectUid
            }) -join ','
            throw ('phase_d_profile_applicability_repair_tier9_scope_invalid' +
                ':account=' + $accountUid +
                ',current_target=' + $currentTargetUnresolved.Count +
                ',safe_applicability=' + $safeApplicabilityChanges.Count +
                ',tier9=' + $tier9ManufacturerChanges.Count +
                ',tier9_missing=' + $tier9MissingFromCandidate.Count +
                ',candidate_missing=' + $candidateMissingFromRepair.Count +
                ',tier9_missing_coordinates=' + $tier9MissingCoordinates +
                ',candidate_missing_coordinates=' + $candidateMissingCoordinates)
        }

        if (($safeChanges.Count + $tier9ManufacturerChanges.Count) -eq 0) {
            Assert-Repair (
                $currentTargetUnresolved.Count -eq 0 -and
                $currentNotApplicable.Count -gt 0) `
                'phase_d_profile_applicability_repair_zero_diff_postcondition_invalid'
            $accountReceipts += [pscustomobject]@{
                accountUid = $accountUid
                draftUid = [string]$draft.draftUid
                previousProfileRevisionUid = $expectedRevisionUid
                resultProfileRevisionUid = $expectedRevisionUid
                resultProfileRevisionNumber = [int]$profile.profileRevision.revisionNumber
                alreadyResolved = $true
                convertedBondFactCount = 0
                convertedEquipmentManufacturerFactCount = 0
                resolvedTier9ManufacturerFactCount = 0
                normalizedOverloadSignCount = 0
                remainingTargetUnresolvedCount = $currentTargetUnresolved.Count
                resultingTargetNotApplicableCount = $currentNotApplicable.Count
            }
            continue
        }

        if (($bondChanges.Count + $manufacturerChanges.Count) -ne
            $safeApplicabilityChanges.Count) {
            throw ('phase_d_profile_applicability_repair_target_scope_invalid' +
                ':bond=' + $bondChanges.Count +
                ',manufacturer=' + $manufacturerChanges.Count +
                ',safe_applicability=' + $safeApplicabilityChanges.Count)
        }

        if (($safeChanges.Count + $tier9ManufacturerChanges.Count) -le 0 -or
            $currentTargetUnresolved.Count -lt $safeApplicabilityChanges.Count) {
            throw ('phase_d_profile_applicability_repair_preview_scope_invalid' +
                ':total=' + $changes.Count +
                ',safe=' + $safeChanges.Count +
                ',bond=' + $bondChanges.Count +
                ',manufacturer=' + $manufacturerChanges.Count +
                ',overload_value=' + $overloadValueChanges.Count +
                ',overload_sign=' + $safeOverloadSignChanges.Count +
                ',overload_same_magnitude=' + $overloadSameMagnitudeChanges.Count +
                ',overload_magnitude_changed=' + $overloadMagnitudeChanges.Count +
                ',overload_scale_changed=' + $overloadScaleChanges.Count +
                ',tier9_manufacturer=' + $tier9ManufacturerChanges.Count +
                ',other=' + $otherChanges.Count +
                ',other_fields=' + $otherFieldSummary +
                ',overload_magnitude_examples=' + $overloadMagnitudeSummary +
                ',existing_not_applicable=' + $currentNotApplicable.Count +
                ',current_target_unresolved=' + $currentTargetUnresolved.Count)
        }

        $editOperations = @($safeChanges | ForEach-Object {
            if ([string]$_.fieldCode -ceq 'bond_level' -or
                [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$') {
                [ordered]@{
                    fieldCode = [string]$_.fieldCode
                    subjectUid = [string]$_.subjectUid
                    valueKind = 'controlled'
                    controlledValue = 'not_applicable'
                }
            }
            else {
                [ordered]@{
                    fieldCode = [string]$_.fieldCode
                    subjectUid = [string]$_.subjectUid
                    valueKind = 'exact_decimal'
                    unscaledValue = [long]$_.after.unscaledValue
                    decimalScale = [int]$_.after.decimalScale
                }
            }
        })
        $editOperations += @($tier9ManufacturerChanges | ForEach-Object {
            if ([string]$_.resolutionKind -ceq 'not_applicable') {
                [ordered]@{
                    fieldCode = [string]$_.fieldCode
                    subjectUid = [string]$_.subjectUid
                    valueKind = 'controlled'
                    controlledValue = 'not_applicable'
                }
            }
            else {
                [ordered]@{
                    fieldCode = [string]$_.fieldCode
                    subjectUid = [string]$_.subjectUid
                    valueKind = 'boolean'
                    booleanValue = [bool]$_.booleanValue
                }
            }
        })
        Assert-Repair (
            $editOperations.Count -le 512 -and
            @($editOperations | Where-Object {
                [string]::IsNullOrWhiteSpace([string]$_.subjectUid)
            }).Count -eq 0) `
            'phase_d_profile_applicability_repair_editor_operation_invalid'

        $editPreview = Invoke-RepairJson `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile/preview") `
            -Body ([ordered]@{
                operationUid = [guid]::NewGuid().ToString('D')
                operations = $editOperations
            }) `
            -IfMatch $expectedRevisionUid `
            -BaseUri $baseUri `
            -CsrfToken $csrfToken `
            -WebSession $webSession
        $editChanges = @($editPreview.changes)
        $safeEditorChanges = @($editChanges | Where-Object {
            (([string]$_.fieldCode -ceq 'bond_level' -or
              [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$') -and
             [string]$_.before.status -ceq 'unresolved' -and
             [string]$_.after.status -ceq 'not_applicable') -or
            ([string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$' -and
             [string]$_.before.status -ceq 'ready' -and
             [string]$_.after.status -ceq 'ready' -and
             [int]$_.before.decimalScale -eq 4 -and
             [int]$_.after.decimalScale -eq 4 -and
             [long]$_.before.unscaledValue -eq (0 - [long]$_.after.unscaledValue)) -or
            ([string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$' -and
             [string]$_.before.status -ceq 'unresolved' -and
             [string]$_.after.status -ceq 'ready' -and
             $null -ne $_.after.booleanValue)
        })
        Assert-Repair (
            $editChanges.Count -eq (
                $safeChanges.Count + $tier9ManufacturerChanges.Count) -and
            $safeEditorChanges.Count -eq $editChanges.Count -and
            @($editPreview.issues | Where-Object { $_.severity -ceq 'error' }).Count -eq 0) `
            'phase_d_profile_applicability_repair_editor_preview_scope_invalid'

        $apply = Invoke-RepairJson `
            -Method Put `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile") `
            -Body ([ordered]@{
                operationUid = [guid]::NewGuid().ToString('D')
                candidateDraftUid = [string]$editPreview.candidateDraftUid
                candidateSha256 = [string]$editPreview.candidateSha256
                expectedDiffSha256 = [string]$editPreview.diffSha256
            }) `
            -IfMatch $expectedRevisionUid `
            -BaseUri $baseUri `
            -CsrfToken $csrfToken `
            -WebSession $webSession

        $candidate = Invoke-RestMethod `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/runtime-projection-candidate") `
            -WebSession $webSession
        $targetUnresolved = @($candidate.values | Where-Object {
            $_.status -ceq 'unresolved' -and
            ([string]$_.fieldCode -ceq 'bond_level' -or
             [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$')
        })
        $notApplicable = @($candidate.values | Where-Object {
            $_.status -ceq 'not_applicable' -and
            ([string]$_.fieldCode -ceq 'bond_level' -or
             [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$')
        })
        Assert-Repair (
            $targetUnresolved.Count -eq (
                $currentTargetUnresolved.Count -
                $safeApplicabilityChanges.Count -
                $tier9ManufacturerChanges.Count) -and
            $notApplicable.Count -eq (
                $currentNotApplicable.Count +
                $safeApplicabilityChanges.Count +
                $tier9NotApplicableChanges.Count)) `
            'phase_d_profile_applicability_repair_postcondition_failed'

        $accountReceipts += [pscustomobject]@{
            accountUid = $accountUid
            draftUid = [string]$draft.draftUid
            editorCandidateDraftUid = [string]$editPreview.candidateDraftUid
            previousProfileRevisionUid = $expectedRevisionUid
            resultProfileRevisionUid = [string]$apply.profileRevision.revisionUid
            resultProfileRevisionNumber = [int]$apply.profileRevision.revisionNumber
            alreadyResolved = $false
            convertedBondFactCount = $bondChanges.Count
            convertedEquipmentManufacturerFactCount = $manufacturerChanges.Count
            resolvedTier9ManufacturerFactCount = $tier9ManufacturerChanges.Count
            normalizedOverloadSignCount = $safeOverloadSignChanges.Count
            remainingTargetUnresolvedCount = $targetUnresolved.Count
            resultingTargetNotApplicableCount = $notApplicable.Count
        }
    }
}
finally {
    if ($null -ne $admin -and -not $admin.HasExited) {
        Stop-Process -Id $admin.Id -Force -ErrorAction SilentlyContinue
        [void]$admin.WaitForExit(10000)
    }
    foreach ($logPath in @($adminStdout,$adminStderr)) {
        if (Test-Path -LiteralPath $logPath) {
            Remove-Item -LiteralPath $logPath -Force
        }
    }
    if (Test-Path -LiteralPath $bootstrapPath) {
        Remove-Item -LiteralPath $bootstrapPath -Force
    }
    if ($postgresStarted -or (Test-Path -LiteralPath (Join-Path $dataRoot 'postmaster.pid'))) {
        & $pgCtl stop -D $dataRoot -m fast -w -t 60 2>$null
    }
    foreach ($name in @(
        'NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET','NIKKE_LAB_HOME','NIKKE_LAB_PROFILE_RAW',
        'NLL_CONTROL_CENTER_BOOTSTRAP_PATH','NLL_CONTROL_CENTER_PG_CTL',
        'NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG','NLL_PHASE_D_CONTROL_CENTER',
        'PGPASSWORD')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $databasePassword = $null
    $identitySecret = $null
}

Assert-Repair (
    @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-RepairPort $DatabasePort) -and
    -not (Test-RepairPort $AdminPort)) 'phase_d_profile_applicability_repair_cleanup_failed'

$repairUid = [guid]::NewGuid().ToString('D')
$receiptRoot = Join-Path $InstallRoot ('source-free\profile-applicability-repairs\' + $repairUid)
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-profile-applicability-repair/v1'
    repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    repairUid = $repairUid
    accounts = $accountReceipts
    accountCount = $accountReceipts.Count
    convertedBondFactCount = @($accountReceipts | Measure-Object convertedBondFactCount -Sum).Sum
    convertedEquipmentManufacturerFactCount = @(
        $accountReceipts | Measure-Object convertedEquipmentManufacturerFactCount -Sum).Sum
    resolvedTier9ManufacturerFactCount = @(
        $accountReceipts | Measure-Object resolvedTier9ManufacturerFactCount -Sum).Sum
    normalizedOverloadSignCount = @(
        $accountReceipts | Measure-Object normalizedOverloadSignCount -Sum).Sum
    databaseModified = @($accountReceipts | Where-Object {
        $_.alreadyResolved -eq $false
    }).Count -gt 0
    existingRevisionOverwritten = $false
    gameRuntimeStarted = $false
    officialOutboundUsed = $false
    credentialPersisted = $false
    runtimeColdAfterRepair = $true
}
$receiptPath = Join-Path $receiptRoot 'repair.receipt.json'
[IO.File]::WriteAllText(
    $receiptPath,
    (($receipt | ConvertTo-Json -Depth 8) + "`n"),
    [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 9
