
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = Join-Path $ProjectPath "exports\rulesets.json"
$ReportPath = Join-Path $ProjectPath "reports\Ruleset-Migration-Report.json"
$PayloadFolder = Join-Path $ProjectPath "exports\ruleset-payloads"

New-Item -ItemType Directory -Force -Path (Split-Path $ExportPath) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null
New-Item -ItemType Directory -Force -Path $PayloadFolder | Out-Null

$Results = @()
$Report = [ordered]@{
    SourceRepository = "$SourceOwner/$Repo"
    DestinationRepository = "$DestinationOwner/$Repo"
    ExportStatus = "Pending"
    DestinationStatus = "Pending"
    MigrationStatus = "Pending"
    TotalRulesets = 0
    Migrated = 0
    AlreadyPresent = 0
    Failed = 0
    EnforcementPreserved = "Disabled"
    Results = @()
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " GitHub Ruleset Migration" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Verify source account
Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) { throw "Source account switch failed." }

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser.Trim() -ne $SourceOwner) {
    throw "Source account verification failed."
}

# STEP 2: Export source rulesets
Write-Host "`nSTEP 2: Exporting source rulesets..." -ForegroundColor Yellow

$SourceOutput = gh api "repos/$SourceOwner/$Repo/rulesets" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Source ruleset export failed: $($SourceOutput -join ' ')"
}

$SourceRulesets = @($SourceOutput | ConvertFrom-Json)

$SourceRulesets |
    ConvertTo-Json -Depth 30 |
    Set-Content -Path $ExportPath -Encoding utf8

$Report.ExportStatus = "Success"
$Report.TotalRulesets = $SourceRulesets.Count

Write-Host "Source rulesets exported: $($SourceRulesets.Count)" -ForegroundColor Green

# STEP 3: Verify destination account
Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) { throw "Destination account switch failed." }

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser.Trim() -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

# STEP 4: Verify destination repository
Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

gh api "repos/$DestinationOwner/$Repo" --silent
if ($LASTEXITCODE -ne 0) {
    throw "Destination repository is inaccessible."
}

$Report.DestinationStatus = "Repository access verified"

# STEP 5: Get existing destination rulesets
Write-Host "`nSTEP 5: Checking existing destination rulesets..." -ForegroundColor Yellow

$DestinationOutput = gh api "repos/$DestinationOwner/$Repo/rulesets" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not retrieve destination rulesets."
}

$DestinationRulesets = @($DestinationOutput | ConvertFrom-Json)

# STEP 6: Migrate each ruleset
Write-Host "`nSTEP 6: Migrating rulesets..." -ForegroundColor Yellow

foreach ($SourceItem in $SourceRulesets) {

    $Name = $SourceItem.name
    Write-Host "`nProcessing: $Name" -ForegroundColor Cyan

    $Result = [ordered]@{
        Name = $Name
        Status = "Pending"
        DestinationId = $null
        Verification = "Pending"
        Details = ""
    }

    try {
        # Retrieve complete source configuration
        gh auth switch --user $SourceOwner | Out-Null
        $DetailOutput = gh api "repos/$SourceOwner/$Repo/rulesets/$($SourceItem.id)" 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Could not retrieve source ruleset details."
        }

        $SourceDetail = $DetailOutput | ConvertFrom-Json

        # Build a clean destination payload.
        # Source IDs, node IDs, timestamps and links are excluded.
        $Payload = [ordered]@{
            name = $SourceDetail.name
            target = $SourceDetail.target
            enforcement = $SourceDetail.enforcement
            conditions = $SourceDetail.conditions
            rules = $SourceDetail.rules
            bypass_actors = @($SourceDetail.bypass_actors)
        }

        $PayloadPath = Join-Path $PayloadFolder "$Name.json"

        $Payload |
            ConvertTo-Json -Depth 30 |
            Set-Content -Path $PayloadPath -Encoding utf8

        # Switch to destination
        gh auth switch --user $DestinationOwner | Out-Null

        # Check for an existing ruleset with the same name
        $Existing = @($DestinationRulesets | Where-Object {
            $_.name -eq $Name
        })

        if ($Existing.Count -gt 0) {
            $DestinationId = $Existing[0].id
            Write-Host "Already exists. Verifying existing ruleset..." -ForegroundColor Yellow
            $Result.Status = "Already present"
            $Report.AlreadyPresent++
        }
        else {
            $CreateOutput = gh api "repos/$DestinationOwner/$Repo/rulesets" `
                --method POST --input $PayloadPath 2>&1

            if ($LASTEXITCODE -ne 0) {
                throw "Ruleset creation failed: $($CreateOutput -join ' ')"
            }

            $Created = $CreateOutput | ConvertFrom-Json
            $DestinationId = $Created.id

            $Result.Status = "Migrated"
            $Report.Migrated++
            Write-Host "Created successfully. ID: $DestinationId" -ForegroundColor Green
        }

        # Verify destination ruleset details
        $VerifyOutput = gh api "repos/$DestinationOwner/$Repo/rulesets/$DestinationId" 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Destination ruleset verification failed."
        }

        $Verified = $VerifyOutput | ConvertFrom-Json

        $Expected = [ordered]@{
            name = $Payload.name
            target = $Payload.target
            enforcement = $Payload.enforcement
            conditions = $Payload.conditions
            rules = $Payload.rules
            bypass_actors = $Payload.bypass_actors
        }

        $Actual = [ordered]@{
            name = $Verified.name
            target = $Verified.target
            enforcement = $Verified.enforcement
            conditions = $Verified.conditions
            rules = $Verified.rules
            bypass_actors = @($Verified.bypass_actors)
        }

        $ExpectedJson = ConvertTo-Json -InputObject $Expected -Depth 30 -Compress
        $ActualJson = ConvertTo-Json -InputObject $Actual -Depth 30 -Compress

        if ($ExpectedJson -ne $ActualJson) {
            throw "Destination configuration does not match source."
        }

        $Result.DestinationId = $DestinationId
        $Result.Verification = "Passed"
        $Result.Details = "Configuration matches source. Enforcement preserved."

        Write-Host "Verification passed." -ForegroundColor Green
    }
    catch {
        $Result.Status = "Failed"
        $Result.Verification = "Failed"
        $Result.Details = $_.Exception.Message
        $Report.Failed++

        Write-Warning "$Name failed: $($_.Exception.Message)"
    }

    $Results += [PSCustomObject]$Result

    # Refresh destination list for subsequent rulesets
    gh auth switch --user $DestinationOwner | Out-Null
    $RefreshOutput = gh api "repos/$DestinationOwner/$Repo/rulesets" 2>&1

    if ($LASTEXITCODE -eq 0) {
        $DestinationRulesets = @($RefreshOutput | ConvertFrom-Json)
    }
}

# STEP 7: Generate final report
$Report.Results = $Results
$Report.Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

if ($Report.Failed -eq 0 -and
    ($Report.Migrated + $Report.AlreadyPresent) -eq $Report.TotalRulesets) {
    $Report.MigrationStatus = "Success"
}
else {
    $Report.MigrationStatus = "Partially completed or failed"
}

$Report |
    ConvertTo-Json -Depth 30 |
    Set-Content -Path $ReportPath -Encoding utf8

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " RULESET MIGRATION SUMMARY" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Total rulesets: $($Report.TotalRulesets)"
Write-Host "Migrated: $($Report.Migrated)"
Write-Host "Already present: $($Report.AlreadyPresent)"
Write-Host "Failed: $($Report.Failed)"
Write-Host "Overall: $($Report.MigrationStatus)"
Write-Host "Report: $ReportPath"
Write-Host "==========================================" -ForegroundColor Cyan

if ($Report.Failed -gt 0) {
    exit 1
}
