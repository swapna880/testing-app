
# GitHub Account A to Account B - Migration Orchestrator
# Source: swapna880/testing-app
# Destination: swapnakuntala/testing-app

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ScriptsPath = Join-Path $ProjectPath "scripts"
$LogPath = Join-Path $ProjectPath "logs"
$ReportPath = Join-Path $ProjectPath "reports"

$SourceOwner = "swapna880"
$DestinationOwner = "swapnakuntala"
$Repo = "testing-app"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogPath "Migration-Run-$Timestamp.log"
$ReportFile = Join-Path $ReportPath "Migration-Run-Summary-$Timestamp.json"

foreach ($Folder in @($LogPath, $ReportPath)) {
    if (-not (Test-Path $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
}

$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source

$MigrationScripts = @(
    "Export-Repository.ps1",
    "Create-Repository.ps1",
    "Migrate-Repository.ps1",
    "Set-RepositoryConfiguration.ps1",
    "Set-Collaborators.ps1",
    "Set-Rulesets.ps1",
    "Validate-Migration.ps1"
)

$Results = @()
$PreflightPassed = $false
$GitMigrationStatus = "Not started"

function Write-RunLog {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Add-Content -Path $LogFile -Value $Line
    Write-Host $Line
}

function Invoke-Preflight {
    Write-RunLog "Starting preflight checks."

    foreach ($ScriptName in $MigrationScripts) {
        $Path = Join-Path $ScriptsPath $ScriptName

        if (-not (Test-Path $Path)) {
            throw "Required script is missing: $ScriptName"
        }
    }

    gh auth switch --user $SourceOwner | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not switch to source account."
    }

    $SourceUser = gh api user --jq .login
    if ($LASTEXITCODE -ne 0 -or $SourceUser -ne $SourceOwner) {
        throw "Source account authentication failed."
    }

    gh auth switch --user $DestinationOwner | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not switch to destination account."
    }

    $DestinationUser = gh api user --jq .login
    if ($LASTEXITCODE -ne 0 -or $DestinationUser -ne $DestinationOwner) {
        throw "Destination account authentication failed."
    }

    gh api "repos/$DestinationOwner/$Repo" --silent
    if ($LASTEXITCODE -ne 0) {
        throw "Destination repository is unavailable."
    }

    gh auth setup-git

    $DestinationRefs = @(git ls-remote "https://github.com/$DestinationOwner/$Repo.git" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect destination Git references."
    }

    if ($DestinationRefs.Count -gt 0) {
        throw "Destination contains Git references. Migration stopped."
    }

    $MirrorPath = Join-Path $ProjectPath "$Repo-mirror.git"
    if (Test-Path $MirrorPath) {
        throw "Mirror directory already exists. Inspect it before proceeding."
    }

    Write-RunLog "Preflight checks passed."
}

$OverallTimer = [System.Diagnostics.Stopwatch]::StartNew()

Write-RunLog "============================================"
Write-RunLog "GitHub Repository Migration POC"
Write-RunLog "Source: $SourceOwner/$Repo"
Write-RunLog "Destination: $DestinationOwner/$Repo"
Write-RunLog "============================================"

try {
    Invoke-Preflight
    $PreflightPassed = $true
}
catch {
    Write-RunLog "PREFLIGHT FAILED: $($_.Exception.Message)"
}

if ($PreflightPassed) {

    foreach ($ScriptName in $MigrationScripts) {

        $ScriptFile = Join-Path $ScriptsPath $ScriptName
        $Timer = [System.Diagnostics.Stopwatch]::StartNew()

        Write-RunLog "Starting $ScriptName"

        try {
            # Run each script in a separate PowerShell process.
            # Capture output and exit code independently.
            $Output = & $Pwsh -NoProfile -File $ScriptFile 2>&1
            $ExitCode = $LASTEXITCODE

            $Timer.Stop()
            $OutputText = $Output | Out-String

            Add-Content -Path $LogFile -Value $OutputText

            if ($ExitCode -ne 0) {
                throw "Child script returned exit code $ExitCode."
            }

            $Status = "Executed successfully"

            if ($ScriptName -eq "Migrate-Repository.ps1") {
                $GitMigrationStatus = "Push command completed; pending validation"
            }

            if ($ScriptName -eq "Set-Collaborators.ps1") {
                $Status = "Assessment executed; check report for unmigrated collaborators"
            }

            if ($ScriptName -eq "Set-Rulesets.ps1") {
                $Status = "Assessment executed; check report for plan restrictions"
            }

            if ($ScriptName -eq "Validate-Migration.ps1") {
                $Status = "Validation script executed; inspect validation report"
            }

            $Results += [PSCustomObject]@{
                Script = $ScriptName
                Status = $Status
                DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
            }

            Write-RunLog "$ScriptName completed."
        }
        catch {
            $Timer.Stop()

            $Results += [PSCustomObject]@{
                Script = $ScriptName
                Status = "Failed: $($_.Exception.Message)"
                DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
            }

            Write-RunLog "FAILED: $ScriptName - $($_.Exception.Message)"
            Write-RunLog "Stopping further execution."
            break
        }
    }
}

$OverallTimer.Stop()

$FailureCount = @(
    $Results | Where-Object { $_.Status -like "Failed:*" }
).Count

$ValidationExecuted = @(
    $Results | Where-Object { $_.Script -eq "Validate-Migration.ps1" }
).Count -gt 0

if (-not $PreflightPassed) {
    $OverallStatus = "Stopped - Preflight failed"
}
elseif ($FailureCount -gt 0) {
    $OverallStatus = "Incomplete - One or more scripts failed"
}
elseif ($ValidationExecuted) {
    $OverallStatus = "Execution completed - Review validation and configuration reports"
}
else {
    $OverallStatus = "Incomplete - Review skipped steps"
}

$Summary = [PSCustomObject]@{
    SourceRepository = "$SourceOwner/$Repo"
    DestinationRepository = "$DestinationOwner/$Repo"
    OverallStatus = $OverallStatus
    PreflightStatus = if ($PreflightPassed) { "Passed" } else { "Failed" }
    GitMigrationStatus = $GitMigrationStatus
    TotalDurationSeconds = [math]::Round($OverallTimer.Elapsed.TotalSeconds, 2)
    TotalDurationMinutes = [math]::Round($OverallTimer.Elapsed.TotalMinutes, 2)
    ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ScriptResults = $Results
    Notes = @(
        "Review Migration-Validation-Report.json for branch and commit validation.",
        "Review Collaborator-Migration-Report.json for access mapping.",
        "Review Ruleset-Migration-Report.json for ruleset restrictions.",
        "Git mirror migration does not migrate issues, pull requests, or discussions.",
        "GitHub secrets must be recreated securely at the destination."
    )
}

$Summary | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportFile

Write-RunLog "============================================"
Write-RunLog "Migration execution summary"
Write-RunLog "Overall status: $OverallStatus"
Write-RunLog "Total duration: $($Summary.TotalDurationMinutes) minutes"
Write-RunLog "Report: $ReportFile"
Write-RunLog "Log: $LogFile"

$Results | Format-Table Script, Status, DurationSeconds -AutoSize

Write-Host "`nReview the generated reports before declaring migration successful."
