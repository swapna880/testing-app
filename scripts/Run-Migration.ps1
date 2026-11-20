
[CmdletBinding()]
param(
    [string]$SourceOwner = "swapna880",
    [string]$SourceRepo = "testing-app",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$DestinationRepo = "migration-automation-test",
    [switch]$ApproveMetadataChanges
)

$ErrorActionPreference = 'Stop'

$ProjectPath = Split-Path -Parent $PSScriptRoot
$ScriptsPath = $PSScriptRoot
$ExportPath = Join-Path $ProjectPath 'exports'
$ReportPath = Join-Path $ProjectPath 'reports'
$LogPath = Join-Path $ProjectPath 'logs'
$BackupRoot = Join-Path $ProjectPath 'backups'

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogPath "Migration-Run-$Timestamp.log"
$SummaryFile = Join-Path $ReportPath "Migration-Run-Summary-$Timestamp.json"

$AllowedBranches = @('main', 'develop', 'feature/login')

foreach ($dir in @($ExportPath, $ReportPath, $LogPath, $BackupRoot)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$StepResults = [System.Collections.Generic.List[object]]::new()

$SourceToken = $null
$DestinationToken = $null
$SourcePlain = $null
$DestinationPlain = $null

$OverallStatus = 'Failed'
$Timer = [Diagnostics.Stopwatch]::StartNew()

function Write-RunLog {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Convert-SecureToPlain {
    param([Security.SecureString]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        throw 'A required token is empty.'
    }

    $ptr = [IntPtr]::Zero

    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Get-GitHeader {
    param([string]$Token)

    $raw = [Text.Encoding]::UTF8.GetBytes("x-access-token:$Token")

    return 'AUTHORIZATION: basic ' + [Convert]::ToBase64String($raw)
}

function Get-RemoteRefMap {
    param(
        [string]$Url,
        [string]$Token
    )

    $header = Get-GitHeader $Token

    $output = @(
        & git -c "http.extraheader=$header" ls-remote --refs $Url
    )

    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for $Url"
    }

    $map = @{}

    foreach ($line in $output) {
        if ($line -match '^([0-9a-fA-F]+)\s+(.+)$') {
            $map[$Matches[2]] = $Matches[1].ToLowerInvariant()
        }
    }

    return ,$map
}

function Get-ExpectedSourceRefs {
    param([hashtable]$SourceRefs)

    $expected = @{}

    foreach ($branch in $AllowedBranches) {
        $refName = "refs/heads/$branch"

        if (-not $SourceRefs.ContainsKey($refName)) {
            throw "Required source branch is missing: $branch"
        }

        $expected[$refName] = $SourceRefs[$refName]
    }

    foreach ($refName in $SourceRefs.Keys) {
        if ($refName -like 'refs/tags/*') {
            $expected[$refName] = $SourceRefs[$refName]
        }
    }

    return $expected
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()

    Write-RunLog "START: $Name"

    try {
        & $Action

        $sw.Stop()

        $StepResults.Add([PSCustomObject]@{
            Step = $Name
            Status = 'Completed'
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        })

        Write-RunLog "DONE: $Name"
    }
    catch {
        $sw.Stop()

        $StepResults.Add([PSCustomObject]@{
            Step = $Name
            Status = 'Failed'
            DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Error = $_.Exception.Message
        })

        Write-RunLog "FAILED: $Name - $($_.Exception.Message)"

        throw
    }
}

function Invoke-Child {
    param(
        [string]$Name,
        [hashtable]$Parameters
    )

    $path = Join-Path $ScriptsPath $Name

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required module missing: $path"
    }

    & $path @Parameters
}

function Invoke-CollaboratorMigration {
    Write-Host "`nCOLLABORATOR MIGRATION" -ForegroundColor Cyan
    $sourceCollaborators = @(
        Invoke-RestMethod -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo/collaborators?affiliation=direct&per_page=100" -Headers $sourceHeaders -Method Get
    )
    $destinationCollaborators = @(
        Invoke-RestMethod -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/collaborators?affiliation=direct&per_page=100" -Headers $destHeaders -Method Get
    )
    $existing = @{}
    foreach ($person in $destinationCollaborators) { $existing[$person.login] = $person }
    $results = [System.Collections.Generic.List[object]]::new()
    $toInvite = @($sourceCollaborators | Where-Object { $_.login -ne $SourceOwner -and -not $existing.ContainsKey($_.login) })
    foreach ($person in $sourceCollaborators) {
        $status = if ($person.login -eq $SourceOwner) { 'Source owner - not transferable' }
                  elseif ($existing.ContainsKey($person.login)) { 'Already has destination access' }
                  else { 'Pending approval' }
        $results.Add([PSCustomObject]@{ Username=$person.login; SourceRole=$person.role_name; Status=$status; DestinationPermission=$null })
    }
    if ($toInvite.Count -gt 0) {
        Write-Host "The following users need destination invitations:" -ForegroundColor Yellow
        $toInvite | ForEach-Object { Write-Host (" - {0} ({1})" -f $_.login, $_.role_name) }
        $inviteApproval = if ($ApproveMetadataChanges) { 'YES' } else { Read-Host 'Type INVITE to send collaborator invitations and apply source roles' }
        if ($inviteApproval -ceq 'INVITE') {
            foreach ($person in $toInvite) {
                $permission = switch -Regex ($person.role_name) {
                    '^read$|^pull$' { 'pull'; break }
                    '^triage$' { 'triage'; break }
                    '^write$|^push$' { 'push'; break }
                    '^maintain$' { 'maintain'; break }
                    '^admin$' { 'admin'; break }
                    default { 'push' }
                }
                try {
                    $body = @{ permission = $permission } | ConvertTo-Json
                    $uri = "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/collaborators/$($person.login)"
                    $null = Invoke-RestMethod -Uri $uri -Headers $destHeaders -Method Put -Body $body -ContentType 'application/json' -ErrorAction Stop
                    $row = $results | Where-Object Username -eq $person.login | Select-Object -First 1
                    $row.Status = 'Invitation requested (acceptance may be pending)'
                    $row.DestinationPermission = $permission
                }
                catch {
                    $row = $results | Where-Object Username -eq $person.login | Select-Object -First 1
                    $row.Status = "Failed: $($_.Exception.Message)"
                }
            }
        }
        else { Write-RunLog 'Collaborator invitations were not approved; no invitations sent.' }
    }
    $collabReport = [ordered]@{
        SourceRepository = "$SourceOwner/$SourceRepo"; DestinationRepository = "$DestinationOwner/$DestinationRepo"
        SourceCollaborators = $sourceCollaborators.Count
        AlreadyPresent = @($results | Where-Object Status -eq 'Already has destination access').Count
        InvitationRequested = @($results | Where-Object Status -like 'Invitation requested*').Count
        PendingApproval = @($results | Where-Object Status -eq 'Pending approval').Count
        Failed = @($results | Where-Object Status -like 'Failed:*').Count
        Results = @($results); Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Note = 'Invitations can remain pending until accepted. Username matching assumes the same GitHub login on both accounts.'
    }
    $collabReport | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ReportPath 'Collaborator-Migration-Report.json') -Encoding UTF8
}

try {
    Write-RunLog '=== GITHUB END-TO-END MIGRATION ==='
    Write-RunLog "Source: $SourceOwner/$SourceRepo"
    Write-RunLog "Destination: $DestinationOwner/$DestinationRepo"

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or not in PATH.'
    }

    Write-Host "`nEnter source and destination credentials." -ForegroundColor Cyan

    $SourceToken = Read-Host 'SOURCE GitHub token' -AsSecureString
    $DestinationToken = Read-Host 'DESTINATION GitHub token' -AsSecureString

    $SourcePlain = Convert-SecureToPlain $SourceToken
    $DestinationPlain = Convert-SecureToPlain $DestinationToken

    $sourceHeaders = @{
        Authorization = "Bearer $SourcePlain"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $destHeaders = @{
        Authorization = "Bearer $DestinationPlain"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $sourceUser = Invoke-RestMethod `
        -Uri 'https://api.github.com/user' `
        -Headers $sourceHeaders `
        -Method Get

    $destUser = Invoke-RestMethod `
        -Uri 'https://api.github.com/user' `
        -Headers $destHeaders `
        -Method Get

    if ($sourceUser.login -ne $SourceOwner) {
        throw "Source token identity mismatch: $($sourceUser.login)"
    }

    if ($destUser.login -ne $DestinationOwner) {
        throw "Destination token identity mismatch: $($destUser.login)"
    }

    Write-RunLog 'Both GitHub account identities verified.'

    $childCommon = @{
        SourceOwner = $SourceOwner
        SourceRepo = $SourceRepo
        DestinationOwner = $DestinationOwner
        DestinationRepo = $DestinationRepo
        ProjectPath = $ProjectPath
        SourceToken = $SourceToken
        DestinationToken = $DestinationToken
    }

    Invoke-Step 'Check or create destination repository' {
        Invoke-Child 'Create-Repository.ps1' @{
            DestinationOwner = $DestinationOwner
            Repo = $DestinationRepo
            Description = 'Migrated repository - GitHub Migration POC'
            DestinationToken = $DestinationToken
        }
    }

    $sourceRepoData = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo" `
        -Headers $sourceHeaders `
        -Method Get

    $destRepoData = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $destHeaders `
        -Method Get

    if ($destRepoData.private -ne $true) {
        throw 'Safety check failed: destination repository is not private.'
    }

    Invoke-Step 'Back up current destination metadata' {
        $destRepoData |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath (
                Join-Path $BackupRoot "destination-repository-$Timestamp.json"
            ) -Encoding UTF8

        try {
            $existingRulesets = @(
                Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/rulesets?per_page=100" `
                    -Headers $destHeaders `
                    -Method Get
            )

            $existingRulesets |
                ConvertTo-Json -Depth 30 |
                Set-Content -LiteralPath (
                    Join-Path $BackupRoot "destination-rulesets-$Timestamp.json"
                ) -Encoding UTF8
        }
        catch {
            $code = 0

            try {
                $code = [int]$_.Exception.Response.StatusCode
            }
            catch {}

            if ($code -eq 403) {
                @{
                    Status = 'Restricted'
                    Details = 'GitHub denied destination ruleset access (HTTP 403); ruleset backup unavailable.'
                } |
                    ConvertTo-Json |
                    Set-Content -LiteralPath (
                        Join-Path $BackupRoot "destination-rulesets-$Timestamp.json"
                    ) -Encoding UTF8

                Write-RunLog 'Destination ruleset API restricted (HTTP 403).'
            }
            else {
                throw
            }
        }

        $existingCollaborators = @(
            Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/collaborators?affiliation=direct&per_page=100" `
                -Headers $destHeaders `
                -Method Get
        )

        $existingCollaborators |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath (
                Join-Path $BackupRoot "destination-collaborators-$Timestamp.json"
            ) -Encoding UTF8

        Write-RunLog 'Destination metadata backup completed.'
    }

    $sourceUrl = "https://github.com/$SourceOwner/$SourceRepo.git"
    $destUrl = "https://github.com/$DestinationOwner/$DestinationRepo.git"

    $destRefsBefore = Get-RemoteRefMap -Url $destUrl -Token $DestinationPlain

    if ($destRefsBefore.Count -gt 0) {
        Invoke-Step 'Back up existing destination Git references' {
            $backupPath = Join-Path $BackupRoot "${DestinationRepo}-before-migration-$Timestamp.git"

            if (Test-Path $backupPath) {
                throw "Backup path already exists: $backupPath"
            }

            $header = Get-GitHeader $DestinationPlain

            & git -c "http.extraheader=$header" clone --mirror $destUrl $backupPath

            if ($LASTEXITCODE -ne 0) {
                throw 'Destination mirror backup failed.'
            }

            Write-RunLog "Destination mirror backup created: $backupPath"
        }
    }
    else {
        Write-RunLog 'Destination has no Git refs; no Git backup was needed.'
    }

    Invoke-Step 'Export source repository metadata and rulesets' {
        Invoke-Child 'Export-Repository.ps1' @{
            Owner = $SourceOwner
            Repo = $SourceRepo
            ProjectPath = $ProjectPath
            SourceToken = $SourceToken
        }
    }

    Invoke-Step 'Compare and migrate Git references' {
        $srcRefs = Get-RemoteRefMap -Url $sourceUrl -Token $SourcePlain
        $dstRefs = Get-RemoteRefMap -Url $destUrl -Token $DestinationPlain

        $expectedRefs = Get-ExpectedSourceRefs -SourceRefs $srcRefs

        # The automation publisher maintains a separate migration-automation branch.
        # Compare every intended application branch/tag without treating that branch as drift.
        $same = $true
        foreach ($key in $expectedRefs.Keys) {
            if (-not $dstRefs.ContainsKey($key) -or $expectedRefs[$key] -ne $dstRefs[$key]) {
                $same = $false
                break
            }
        }
        $unexpectedRefs = @($dstRefs.Keys | Where-Object {
            -not $expectedRefs.ContainsKey($_) -and $_ -ne 'refs/heads/migration-automation'
        })
        if ($unexpectedRefs.Count -gt 0) { $same = $false }

        if ($same) {
            Write-RunLog "Git migration skipped: all $($expectedRefs.Count) intended references already match."
        }
        else {
            Write-Host ''
            Write-Host 'DESTINATION REFERENCE REPLACEMENT' -ForegroundColor Yellow
            Write-Host 'A destination backup has been created.'
            Write-Host 'The migration will update the three intended branches and source tags.'
            Write-Host 'The source repository will not be modified.'
            Write-Host ''

            $approval = Read-Host 'Type REPLACE to approve destination Git reference updates'

            if ($approval -cne 'REPLACE') {
                throw 'Destination reference replacement was not approved. Migration stopped.'
            }

            $migrationParams = $childCommon.Clone()
            $migrationParams['ReplaceDestinationRefs'] = $true

            Invoke-Child 'Migrate-Repository.ps1' $migrationParams

            Write-RunLog 'Git migration script completed.'
        }
    }

    Invoke-Step 'Set destination default branch to main' {
        $mainRef = Get-RemoteRefMap -Url $destUrl -Token $DestinationPlain

        if (-not $mainRef.ContainsKey('refs/heads/main')) {
            throw 'Cannot set default branch: destination main branch is missing.'
        }

        $body = @{
            default_branch = 'main'
        } | ConvertTo-Json

        Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
            -Headers $destHeaders `
            -Method Patch `
            -Body $body `
            -ContentType 'application/json' | Out-Null

        Write-RunLog 'Destination default branch set to main.'
    }

    $applyMetadata = $ApproveMetadataChanges.IsPresent

    if (-not $applyMetadata) {
        $answer = Read-Host 'Apply source repository settings and create missing rulesets? Type YES to approve'
        $applyMetadata = ($answer -ceq 'YES')
    }

    if ($applyMetadata) {
        Invoke-Step 'Apply and verify repository settings' {
            Invoke-Child 'Set-RepositoryConfiguration.ps1' $childCommon
        }

        Invoke-Step 'Migrate collaborators and permissions' {
            Invoke-CollaboratorMigration
        }

        Invoke-Step 'Create missing rulesets and verify configurations' {
            Invoke-Child 'Set-Rulesets.ps1' $childCommon
        }
    }
    else {
        Write-RunLog 'Metadata writes were declined; collaborator assessment runs read-only.'

        Invoke-Step 'Assess collaborator access (read-only)' {
            Invoke-Child 'Set-Collaborators.ps1' $childCommon
        }

        $StepResults.Add([PSCustomObject]@{
            Step = 'Apply repository settings'
            Status = 'Skipped - not approved'
            DurationSeconds = 0
        })

        $StepResults.Add([PSCustomObject]@{
            Step = 'Ruleset creation'
            Status = 'Skipped - not approved'
            DurationSeconds = 0
        })
    }

    Invoke-Step 'Synchronize automation scripts to migration-automation branch' {
        Invoke-Child 'Sync-AutomationScripts.ps1' @{
            DestinationOwner = $DestinationOwner
            DestinationRepo = $DestinationRepo
            DestinationToken = $DestinationToken
            ScriptsPath = $ScriptsPath
            AutomationBranch = 'migration-automation'
        }
    }

    Invoke-Step 'Final migration validation' {
        $validationParams = $childCommon.Clone()
        $validationParams['AllowDestinationPrivate'] = $true

        Invoke-Child 'Validate-Migration.ps1' $validationParams
    }

    $OverallStatus = 'Completed - review validation report for warnings'

    Write-RunLog 'All orchestrated migration stages completed.'
}
catch {
    $OverallStatus = 'Failed'
    Write-RunLog "MIGRATION STOPPED: $($_.Exception.Message)"
}
finally {
    $Timer.Stop()

    $SourcePlain = $null
    $DestinationPlain = $null

    if ($SourceToken) {
        $SourceToken.Dispose()
    }

    if ($DestinationToken) {
        $DestinationToken.Dispose()
    }

    $summary = [PSCustomObject]@{
        SourceRepository = "$SourceOwner/$SourceRepo"
        DestinationRepository = "$DestinationOwner/$DestinationRepo"
        ExecutionMode = 'End-to-end migration with destination backup and explicit Git replacement approval'
        OverallStatus = $OverallStatus
        DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Steps = @($StepResults)
        LogFile = $LogFile
        ValidationReport = (Join-Path $ReportPath 'Migration-Validation-Report.json')
        Notes = @(
            'Source repository is not modified.',
            'Only main, develop and feature/login branches are intended migration targets.',
            'Source tags are migrated.',
            'Destination Git reference updates require explicit REPLACE approval.',
            'Destination Git references are backed up before replacement.',
            'Destination default branch is set to main after Git migration.',
            'Collaborators are invited through GitHub API after explicit INVITE approval; invitations may remain pending acceptance.',
            'Ruleset and repository settings application depends on GitHub token permissions and GitHub plan limitations.',
            'Automation scripts are synchronized to the separate migration-automation branch.'
        )
    }

    $summary |
        ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $SummaryFile -Encoding UTF8

    Write-RunLog "Final status: $OverallStatus"
    Write-RunLog "Summary: $SummaryFile"
    Write-RunLog 'Secure token variables cleared.'
}

if ($OverallStatus -eq 'Failed') {
    exit 1
}
