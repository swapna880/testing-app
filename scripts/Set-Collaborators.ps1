
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = Join-Path $ProjectPath "exports\collaborators.json"
$ReportPath = Join-Path $ProjectPath "reports\Collaborator-Migration-Report.json"

New-Item -ItemType Directory -Path (Split-Path $ExportPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$Report = @()

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Collaborator Migration Assessment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Verify source account
gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Source authentication failed."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $SourceOwner) {
    throw "Source account verification failed."
}

# STEP 2: Export source collaborators
Write-Host "`nExporting source collaborators..." -ForegroundColor Yellow

$CollaboratorJson = gh api "repos/$SourceOwner/$Repo/collaborators?affiliation=direct"
if ($LASTEXITCODE -ne 0) {
    throw "Collaborator export failed."
}

$Collaborators = @($CollaboratorJson | ConvertFrom-Json)

$Collaborators |
    Select-Object login, role_name, permissions |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $ExportPath -Encoding utf8

Write-Host "Exported $($Collaborators.Count) collaborator records." -ForegroundColor Green

# STEP 3: Verify destination account
gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Destination authentication failed."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

# STEP 4: Classify owners and external collaborators
foreach ($Collaborator in $Collaborators) {

    $Username = $Collaborator.login

    if ($Username -eq $SourceOwner) {
        $Status = "Skipped - Source repository owner"
    }
    elseif ($Username -eq $DestinationOwner) {
        $Status = "Skipped - Destination repository owner"
    }
    else {
        $Status = "Not migrated - External collaborator requires mapping and testing"
    }

    $Report += [PSCustomObject]@{
        Username = $Username
        Role = $Collaborator.role_name
        Status = $Status
    }

    Write-Host "$Username : $Status"
}

# STEP 5: Generate report
$Report | ConvertTo-Json -Depth 5 |
    Set-Content -Path $ReportPath -Encoding utf8

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "Collaborator assessment completed." -ForegroundColor Green
Write-Host "Export: $ExportPath"
Write-Host "Report: $ReportPath"
Write-Host "==========================================" -ForegroundColor Green

if (@($Report | Where-Object {
    $_.Status -like "Not migrated*"
}).Count -eq 0) {
    Write-Host "No external collaborators available for migration testing."
}
