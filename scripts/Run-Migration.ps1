
# GitHub Account A to Account B - Migration Orchestrator
# Initial version: Safe Assessment Mode
# No Git push or destination configuration changes.

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ScriptsPath = Join-Path $ProjectPath "scripts"
$LogPath = Join-Path $ProjectPath "logs"
$ReportPath = Join-Path $ProjectPath "reports"

$SourceRepo = "testing-app"
$DestinationRepo = "migration-automation-test"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogPath "Migration-Run-$Timestamp.log"
$ReportFile = Join-Path $ReportPath "Migration-Run-Summary-$Timestamp.json"

$SourceToken = $null
$DestinationToken = $null
$SourcePlainToken = $null
$DestinationPlainToken = $null

$Results = @()
$OverallTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($Folder in @($LogPath, $ReportPath)) {
    New-Item -ItemType Directory -Path $Folder -Force |
        Out-Null
}

function Write-RunLog {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"

    Add-Content -Path $LogFile -Value $Line
    Write-Host $Line
}

function Convert-SecureToken {
    param([SecureString]$SecureValue)

    $BSTR = [IntPtr]::Zero

    try {
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        if ($BSTR -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
    }
}

function Test-GitHubAccount {
    param(
        [string]$Token,
        [string]$ExpectedOwner,
        [string]$AccountLabel
    )

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $User = Invoke-RestMethod `
        -Uri "https://api.github.com/user" `
        -Headers $Headers `
        -Method Get `
        -ErrorAction Stop

    if ($User.login -ne $ExpectedOwner) {
        throw "$AccountLabel token belongs to '$($User.login)', not '$ExpectedOwner'."
    }

    Write-RunLog "$AccountLabel account authenticated: $($User.login)"
}

function Invoke-MigrationStep {
    param(
        [string]$ScriptName,
        [hashtable]$Parameters
    )

    $ScriptPath = Join-Path $ScriptsPath $ScriptName
    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

    Write-RunLog "Starting step: $ScriptName"

    if (-not (Test-Path $ScriptPath)) {
        throw "Required script not found: $ScriptPath"
    }

    try {
        # Execute in the current PowerShell process.
        # SecureString tokens are passed directly, not as command-line text.
        & $ScriptPath @Parameters

        $Timer.Stop()

        $script:Results += [PSCustomObject]@{
            Script = $ScriptName
            Status = "Completed"
            DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
        }

        Write-RunLog "Completed step: $ScriptName"
    }
    catch {
        $Timer.Stop()

        $script:Results += [PSCustomObject]@{
            Script = $ScriptName
            Status = "Failed"
            DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
            Error = $_.Exception.Message
        }

        Write-RunLog "FAILED: $ScriptName - $($_.Exception.Message)"
        throw
    }
}

$OverallStatus = "Not started"

try {
    Write-RunLog "=========================================="
    Write-RunLog "GITHUB REPOSITORY MIGRATION POC"
    Write-RunLog "MODE: SAFE ASSESSMENT"
    Write-RunLog "=========================================="

    # STEP 1: Collect four runtime inputs.

    Write-Host "`nSTEP 1: Enter GitHub account details" -ForegroundColor Cyan

    $SourceOwner = Read-Host "Enter SOURCE GitHub Account ID"
    $SourceToken = Read-Host "Enter SOURCE GitHub Token" -AsSecureString

    $DestinationOwner = Read-Host "Enter DESTINATION GitHub Account ID"
    $DestinationToken = Read-Host "Enter DESTINATION GitHub Token" -AsSecureString

    if ([string]::IsNullOrWhiteSpace($SourceOwner) -or
        [string]::IsNullOrWhiteSpace($DestinationOwner) -or
        $SourceToken.Length -eq 0 -or
        $DestinationToken.Length -eq 0) {
        throw "Account IDs and tokens are required."
    }

    Write-RunLog "Source repository: $SourceOwner/$SourceRepo"
    Write-RunLog "Destination repository: $DestinationOwner/$DestinationRepo"

    # STEP 2: Authenticate both accounts independently.

    Write-Host "`nSTEP 2: Authenticating GitHub accounts" -ForegroundColor Cyan

    $SourcePlainToken = Convert-SecureToken $SourceToken
    $DestinationPlainToken = Convert-SecureToken $DestinationToken

    Test-GitHubAccount `
        -Token $SourcePlainToken `
        -ExpectedOwner $SourceOwner `
        -AccountLabel "Source"

    Test-GitHubAccount `
        -Token $DestinationPlainToken `
        -ExpectedOwner $DestinationOwner `
        -AccountLabel "Destination"

    # STEP 3: Execute safe assessment modules.

    Write-Host "`nSTEP 3: Starting safe assessment modules" -ForegroundColor Cyan

    Invoke-MigrationStep `
        -ScriptName "Export-Repository.ps1" `
        -Parameters @{
            Owner = $SourceOwner
            Repo = $SourceRepo
            SourceToken = $SourceToken
        }

    Invoke-MigrationStep `
        -ScriptName "Set-Collaborators.ps1" `
        -Parameters @{
            SourceOwner = $SourceOwner
            SourceRepo = $SourceRepo
            DestinationOwner = $DestinationOwner
            DestinationRepo = $DestinationRepo
            ProjectPath = $ProjectPath
            SourceToken = $SourceToken
            DestinationToken = $DestinationToken
        }

    Invoke-MigrationStep `
        -ScriptName "Validate-Migration.ps1" `
        -Parameters @{
            SourceOwner = $SourceOwner
            SourceRepo = $SourceRepo
            DestinationOwner = $DestinationOwner
            DestinationRepo = $DestinationRepo
            ProjectPath = $ProjectPath
            SourceToken = $SourceToken
            DestinationToken = $DestinationToken
        }

    $OverallStatus = "Safe assessment completed"

    Write-RunLog "All safe assessment modules completed."
}
catch {
    $OverallStatus = "Failed"
    Write-RunLog "PROCESS FAILED: $($_.Exception.Message)"
}
finally {
    # Clear temporary token strings and dispose of secure inputs.
    $SourcePlainToken = $null
    $DestinationPlainToken = $null

    if ($SourceToken) {
        $SourceToken.Dispose()
    }

    if ($DestinationToken) {
        $DestinationToken.Dispose()
    }

    $OverallTimer.Stop()

    $Summary = [PSCustomObject]@{
        SourceRepository = if ($SourceOwner) {
            "$SourceOwner/$SourceRepo"
        } else {
            $null
        }
        DestinationRepository = if ($DestinationOwner) {
            "$DestinationOwner/$DestinationRepo"
        } else {
            $null
        }
        ExecutionMode = "Safe Assessment"
        OverallStatus = $OverallStatus
        TotalDurationSeconds = [math]::Round($OverallTimer.Elapsed.TotalSeconds, 2)
        ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ScriptResults = @($Results)
        Notes = @(
            "No Git mirror push was performed.",
            "No destination repository settings were changed.",
            "No destination rulesets were created or modified.",
            "External collaborator invitations were not performed.",
            "Review Migration-Validation-Report.json for validation results."
        )
    }

    $Summary |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $ReportFile -Encoding utf8

    Write-RunLog "=========================================="
    Write-RunLog "MIGRATION POC SUMMARY"
    Write-RunLog "Overall status: $OverallStatus"
    Write-RunLog "Report: $ReportFile"
    Write-RunLog "Log: $LogFile"
    Write-RunLog "=========================================="

    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}
