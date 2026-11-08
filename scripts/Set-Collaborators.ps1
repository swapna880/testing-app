

param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = Join-Path $ProjectPath "exports\collaborators.json"
$ReportPath = Join-Path $ProjectPath "reports\Collaborator-Migration-Report.json"

New-Item -ItemType Directory -Force -Path (Split-Path $ExportPath) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null

$Results = @()

$Report = [ordered]@{
    SourceRepository = "$SourceOwner/$Repo"
    DestinationRepository = "$DestinationOwner/$Repo"
    SourceExportStatus = "Pending"
    DestinationAccessStatus = "Pending"
    TotalSourceCollaborators = 0
    SourceOwnerCount = 0
    DestinationOwnerCount = 0
    ExternalCollaborators = 0
    ExternalMigrationStatus = "Not tested - Third account unavailable"
    Results = @()
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Collaborator Migration Assessment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Verify source account
Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Source authentication failed."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser.Trim() -ne $SourceOwner) {
    throw "Source account verification failed."
}

# STEP 2: Export source collaborators
Write-Host "`nSTEP 2: Exporting source collaborators..." -ForegroundColor Yellow

$CollaboratorOutput = gh api "repos/$SourceOwner/$Repo/collaborators?affiliation=direct" 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Collaborator export failed: $($CollaboratorOutput -join ' ')"
}

$Collaborators = @($CollaboratorOutput | ConvertFrom-Json)

$Export = @(
    foreach ($Collaborator in $Collaborators) {
        [PSCustomObject]@{
            SourceUsername = $Collaborator.login
            SourceRole = $Collaborator.role_name
            Permissions = $Collaborator.permissions
        }
    }
)

$Export | ConvertTo-Json -Depth 15 |
    Set-Content -Path $ExportPath -Encoding utf8

$Report.SourceExportStatus = "Success"
$Report.TotalSourceCollaborators = $Collaborators.Count

Write-Host "Exported $($Collaborators.Count) collaborator records." -ForegroundColor Green

# STEP 3: Verify destination account
Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Destination authentication failed."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser.Trim() -ne $DestinationOwner) {
    throw "Destination authentication verification failed."
}

# STEP 4: Verify destination repository access
Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

$DestinationRepo = gh api "repos/$DestinationOwner/$Repo" 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Destination repository access failed."
}

$Report.DestinationAccessStatus = "Verified"

# STEP 5: Check destination collaborator access
Write-Host "`nSTEP 5: Checking destination collaborator access..." -ForegroundColor Yellow

$DestinationOutput = gh api "repos/$DestinationOwner/$Repo/collaborators?affiliation=direct" 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Could not retrieve destination collaborator list."
}

$DestinationCollaborators = @($DestinationOutput | ConvertFrom-Json)

foreach ($Collaborator in $Collaborators) {

    $Username = $Collaborator.login
    $DestinationUser = $DestinationCollaborators |
        Where-Object { $_.login -eq $Username } |
        Select-Object -First 1

    if ($Username -eq $SourceOwner) {

        $Status = "Source owner - Not transferable as collaborator"

        $Report.SourceOwnerCount++
    }
    elseif ($Username -eq $DestinationOwner) {

        $Status = "Destination owner - Repository ownership verified"

        $Report.DestinationOwnerCount++
    }
    elseif ($DestinationUser) {

        $Status = "Already has destination access"

    }
    else {

        $Status = "Not migrated - External account mapping and testing required"

        $Report.ExternalCollaborators++
    }

    $Results += [PSCustomObject]@{
        SourceUsername = $Username
        SourceRole = $Collaborator.role_name
        DestinationAccessFound = [bool]$DestinationUser
        DestinationRole = if ($DestinationUser) {
            $DestinationUser.role_name
        } else {
            "Not verified"
        }
        Status = $Status
    }

    Write-Host "$Username : $Status"
}

# STEP 6: Generate report
$Report.Results = $Results
$Report.Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$Report |
    ConvertTo-Json -Depth 15 |
    Set-Content -Path $ReportPath -Encoding utf8

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " COLLABORATOR ASSESSMENT SUMMARY" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Source collaborators: $($Report.TotalSourceCollaborators)"
Write-Host "Source owner: $($Report.SourceOwnerCount)"
Write-Host "Destination owner: $($Report.DestinationOwnerCount)"
Write-Host "External collaborators: $($Report.ExternalCollaborators)"
Write-Host "External migration: $($Report.ExternalMigrationStatus)"
Write-Host "Report: $ReportPath"
Write-Host "==========================================" -ForegroundColor Cyan
