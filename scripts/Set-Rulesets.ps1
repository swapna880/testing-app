
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = Join-Path $ProjectPath "exports\rulesets.json"
$ReportPath = Join-Path $ProjectPath "reports\Ruleset-Migration-Report.json"

New-Item -ItemType Directory -Path (Split-Path $ExportPath) -Force |
    Out-Null
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force |
    Out-Null

$Report = [ordered]@{
    SourceRepository = "$SourceOwner/$Repo"
    DestinationRepository = "$DestinationOwner/$Repo"
    ExportStatus = ""
    DestinationStatus = ""
    MigrationStatus = ""
    Details = ""
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " GitHub Ruleset Migration Assessment" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Verify source account
Write-Host "`nSTEP 1: Checking source account..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to source account."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $SourceOwner) {
    throw "Source account verification failed."
}

# STEP 2: Attempt to export source rulesets
Write-Host "`nSTEP 2: Exporting source rulesets..." -ForegroundColor Yellow

$RulesetOutput = gh api "repos/$SourceOwner/$Repo/rulesets" 2>&1
$RulesetExitCode = $LASTEXITCODE

if ($RulesetExitCode -eq 0) {

    try {
        $Rulesets = @($RulesetOutput | ConvertFrom-Json)

        $Rulesets |
            ConvertTo-Json -Depth 20 |
            Set-Content -Path $ExportPath -Encoding utf8

        $Report.ExportStatus = "Success"
        Write-Host "Rulesets exported: $($Rulesets.Count)" -ForegroundColor Green
    }
    catch {
        $Report.ExportStatus = "Failed"
        $Report.Details = "Ruleset response could not be parsed: $($_.Exception.Message)"
    }
}
else {
    $ErrorText = $RulesetOutput -join " "

    if ($ErrorText -match "403|Upgrade to GitHub Pro|not enabled") {
        $Report.ExportStatus = "Restricted"
        $Report.Details = "GitHub plan or repository visibility restriction prevents ruleset export."
        Write-Warning $Report.Details
    }
    else {
        $Report.ExportStatus = "Failed"
        $Report.Details = "Ruleset export failed. Review the GitHub API error."
        Write-Warning $Report.Details
    }

    if (Test-Path $ExportPath) {
        Remove-Item $ExportPath -Force
    }
}

# STEP 3: Verify destination account
Write-Host "`nSTEP 3: Checking destination account..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to destination account."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

# STEP 4: Verify destination repository
gh api "repos/$DestinationOwner/$Repo" --silent

if ($LASTEXITCODE -ne 0) {
    throw "Destination repository does not exist or is inaccessible."
}

$Report.DestinationStatus = "Repository access verified"

# STEP 5: Set migration status
if ($Report.ExportStatus -eq "Success") {
    $Report.MigrationStatus = "Export available - destination compatibility review required"
    $Report.Details = "Rulesets exported. No rulesets were automatically applied."
}
elseif ($Report.ExportStatus -eq "Restricted") {
    $Report.MigrationStatus = "Not migrated - GitHub plan restriction"
}
else {
    $Report.MigrationStatus = "Not migrated - export failed"
}

# STEP 6: Generate report
$Report |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $ReportPath -Encoding utf8

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "Ruleset assessment completed." -ForegroundColor Green
Write-Host "Export status: $($Report.ExportStatus)"
Write-Host "Destination: $($Report.DestinationStatus)"
Write-Host "Migration status: $($Report.MigrationStatus)"
Write-Host "Report: $ReportPath"
Write-Host "==========================================" -ForegroundColor Green
