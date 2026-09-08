[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",

    [string]$AssessmentUid = "8c2281d7-c3da-4e74-bb54-09758695fc99"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"
Assert-True ($AssessmentUid -cmatch
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') `
    "phase3b2_operator_env_assessment_uid_invalid"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$outputPath = Join-Path $repositoryRoot ".env"
$temporaryPath = $outputPath + ".tmp." + [Guid]::NewGuid().ToString("N")
Assert-True (-not (Test-Path -LiteralPath $outputPath)) `
    "phase3b2_operator_env_already_exists"
Assert-True (@(git -C $repositoryRoot ls-files -- .env).Count -eq 0) `
    "phase3b2_operator_env_tracked"
git -C $repositoryRoot check-ignore -q -- .env
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_operator_env_not_ignored"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_operator_env_vm_state_invalid"

$synthetic = Invoke-Command -VMName $VMName -Credential $GuestCredential `
    -ScriptBlock {
        $ErrorActionPreference = "Stop"
        $trustedRoot = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted"
        $contextPath = Join-Path $trustedRoot "identity\synthetic-context.json"
        $dbPath = "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json"
        if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
            throw "phase3b2_operator_env_guest_source_missing"
        }
        $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $username = [string]$context.username
        $password = [string]$context.password
        $md5 = [Security.Cryptography.MD5]::Create()
        try {
            $expectedHash = (($md5.ComputeHash(
                            [Text.Encoding]::ASCII.GetBytes($password)) |
                        ForEach-Object { $_.ToString("x2") }) -join "")
        }
        finally { $md5.Dispose() }
        if ($context.contractId -cne "nll/phase3b2-synthetic-runtime-context/v1" -or
            $username -cnotmatch '^synthetic-[0-9a-f]{32}@invalid\.local$' -or
            $password -cnotmatch '^[0-9a-f]{20}$' -or
            @($db.Users).Count -ne 1 -or
            [string]$db.Users[0].Username -cne $username -or
            [string]$db.Users[0].Password -cne $expectedHash) {
            throw "phase3b2_operator_env_guest_credential_invalid"
        }
        [pscustomobject]@{
            Username = $username
            Password = $password
        }
    }

Assert-True (@($synthetic).Count -eq 1 -and
    [string]$synthetic.Username -cmatch '^synthetic-[0-9a-f]{32}@invalid\.local$' -and
    [string]$synthetic.Password -cmatch '^[0-9a-f]{20}$') `
    "phase3b2_operator_env_direct_result_invalid"

$text = @(
    "NLL_PHASE3B2_ASSESSMENT_UID=$AssessmentUid"
    "NLL_PHASE3B2_SYNTHETIC_USERNAME=$([string]$synthetic.Username)"
    "NLL_PHASE3B2_SYNTHETIC_PASSWORD=$([string]$synthetic.Password)"
) -join "`n"

try {
    [IO.File]::WriteAllText($temporaryPath, $text + "`n",
        [Text.UTF8Encoding]::new($false))

    $acl = Get-Acl -LiteralPath $temporaryPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) {
        $acl.RemoveAccessRuleSpecific($existingRule)
    }
    $fullControl = [Security.AccessControl.FileSystemRights]::FullControl
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    foreach ($sid in @(
            $identity.User,
            [Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
            [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544"))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, $fullControl, $allow))
    }
    Set-Acl -LiteralPath $temporaryPath -AclObject $acl
    [IO.File]::Move($temporaryPath, $outputPath)

    $outputAcl = Get-Acl -LiteralPath $outputPath
    Assert-True ($outputAcl.AreAccessRulesProtected -and
        (Get-Content -LiteralPath $outputPath -Encoding UTF8).Count -eq 3) `
        "phase3b2_operator_env_postcondition_failed"

    [ordered]@{
        contractId = "nll/phase3b2-synthetic-operator-env-export/v1"
        exportedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $AssessmentUid
        outputRoleCode = "ignored_repository_root_operator_env"
        outputTracked = $false
        outputIgnored = $true
        aclInheritanceDisabled = $true
        byteLength = (Get-Item -LiteralPath $outputPath).Length
        sha256 = Get-Sha256Hex $outputPath
        syntheticUsernamePersisted = $true
        syntheticPasswordPersisted = $true
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        networkTransportUsed = $false
        rawCredentialEmitted = $false
        serverExecutionStateChanged = $false
        launcherExecutionStateChanged = $false
        clientExecutionStateChanged = $false
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    Remove-Variable synthetic, text -ErrorAction SilentlyContinue
}
