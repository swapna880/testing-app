
# GitHub Account A to Account B - Migration Orchestrator
# Source: swapna880
# Destination: swapnakuntala

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ScriptsPath = Join-Path $ProjectPath "scripts"
$LogPath = Join-Path $ProjectPath "logs"
$ReportPath = Join-Path $ProjectPath "reports"

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogPath "Migration-Run-$Timestamp.log"
$ReportFile = Join-Path $ReportPath "Migration-Run-Summary-$Timestamp.json"

# Ensure output folders exist
foreach ($Folder in @($LogPath, $ReportPath)) {
    if (-not (Test-Path $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
}

# Check PowerShell 7
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source

# Scripts must run in this order
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
$OverallTimer = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host "============================================"
Write-Host " GitHub Repository Migration POC"
Write-Host " Source      : swapna880/testing-app"
Write-Host " Destination : swapnakuntala/testing-app"
Write-Host "============================================"

foreach ($ScriptName in $MigrationScripts) {

    $ScriptFile = Join-Path $ScriptsPath $ScriptName

    if (-not (Test-Path $ScriptFile)) {
        $Results += [PSCustomObject]@{
            Script = $ScriptName
            Status = "Failed - Script not found"
            DurationSeconds = 0
        }

        Write-Host "Script not found: $ScriptFile" -ForegroundColor Red
        break
    }

    Write-Host "`nStarting: $ScriptName" -ForegroundColor Cyan

    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $Output = & $Pwsh -NoProfile -File $ScriptFile 2>&1
        $ExitCode = $LASTEXITCODE

        $Timer.Stop()

        $Output | Out-String | Add-Content -Path $LogFile

        if ($ExitCode -eq 0) {
            $Status = "Success"
            Write-Host "Completed: $ScriptName" -ForegroundColor Green
        }
        else {
            $Status = "Failed - Exit code $ExitCode"
            Write-Host "Failed: $ScriptName" -ForegroundColor Red
        }

        $Results += [PSCustomObject]@{
            Script = $ScriptName
            Status = $Status
            DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
        }

        if ($ExitCode -ne 0) {
            Write-Host "Stopping migration because a script failed." -ForegroundColor Red
            break
        }
    }
    catch {
        $Timer.Stop()

        $_ | Out-String | Add-Content -Path $LogFile

        $Results += [PSCustomObject]@{
            Script = $ScriptName
            Status = "Failed - $($_.Exception.Message)"
            DurationSeconds = [math]::Round($Timer.Elapsed.TotalSeconds, 2)
        }

        Write-Host "Error running $ScriptName : $($_.Exception.Message)" -ForegroundColor Red
        break
    }
}

$OverallTimer.Stop()

$FailedCount = @($Results | Where-Object { $_.Status -notlike "Success" }).Count

if ($Results.Count -eq $MigrationScripts.Count -and $FailedCount -eq 0) {
    $OverallStatus = "Completed"
}
else {
    $OverallStatus = "Incomplete - Review failed or skipped steps"
}

$Summary = [PSCustomObject]@{
    SourceRepository = "swapna880/testing-app"
    DestinationRepository = "swapnakuntala/testing-app"
    OverallStatus = $OverallStatus
    TotalDurationSeconds = [math]::Round($OverallTimer.Elapsed.TotalSeconds, 2)
    TotalDurationMinutes = [math]::Round($OverallTimer.Elapsed.TotalMinutes, 2)
    ExecutionDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ScriptResults = $Results
}

$Summary | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportFile

Write-Host "`n============================================"
Write-Host " Migration Orchestration Summary"
Write-Host "============================================"
$Results | Format-Table Script, Status, DurationSeconds -AutoSize
Write-Host "Overall Status: $OverallStatus"
Write-Host "Total Duration: $($Summary.TotalDurationMinutes) minutes"
Write-Host "Report: $ReportFile"
Write-Host "Log: $LogFile"
