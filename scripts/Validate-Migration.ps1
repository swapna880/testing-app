
param(
    [string]$SourceOwner = "swapna880",
    [string]$SourceRepo = "testing-app",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$DestinationRepo = "migration-automation-test",
    [string]$ProjectPath = "C:\GitHub-Migration-POC",
    [SecureString]$SourceToken,
    [SecureString]$DestinationToken
)

$ErrorActionPreference = "Stop"

$ReportPath = Join-Path $ProjectPath "reports\Migration-Validation-Report.json"

$SourcePlainToken = $null
$DestinationPlainToken = $null

$OwnSourceToken = $false
$OwnDestinationToken = $false

$Results = [System.Collections.Generic.List[object]]::new()

function Convert-SecureToken {
    param([SecureString]$SecureValue)

    if ($null -eq $SecureValue) {
        throw "A required GitHub token was not supplied."
    }

    $Bstr = [IntPtr]::Zero

    try {
        $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    }
    finally {
        if ($Bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }
    }
}

function Get-GitHubHeaders {
    param([string]$Token)

    return @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Invoke-GitHubGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    return Invoke-RestMethod `
        -Uri $Uri `
        -Headers $Headers `
        -Method GET `
        -ErrorAction Stop
}

function Add-ValidationResult {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Details
    )

    $Results.Add([PSCustomObject]@{
        Check = $Check
        Status = $Status
        Details = $Details
    })

    $Color = if ($Status -eq "Passed") { "Green" } else { "Red" }

    Write-Host "$Check : $Status - $Details" -ForegroundColor $Color
}

function Get-GitAuthorizationHeader {
    param([string]$Token)

    $Bytes = [Text.Encoding]::UTF8.GetBytes("x-access-token:$Token")
    $Encoded = [Convert]::ToBase64String($Bytes)

    return "AUTHORIZATION: basic $Encoded"
}

function Get-GitRefs {
    param(
        [string]$Url,
        [string]$Token,
        [ValidateSet("heads", "tags")]
        [string]$RefType
    )

    $Header = Get-GitAuthorizationHeader -Token $Token

    if ($RefType -eq "heads") {
        $Output = & git -c "http.extraheader=$Header" ls-remote --heads $Url
    }
    else {
        $Output = & git -c "http.extraheader=$Header" ls-remote --tags --refs $Url
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve $RefType from $Url"
    }

    $RefMap = @{}

    foreach ($Line in $Output) {
        if ($Line -match '^([0-9a-fA-F]+)\s+(.+)$') {
            $RefMap[$Matches[2]] = $Matches[1].ToLowerInvariant()
        }
    }

    return $RefMap
}

function Compare-ReferenceMaps {
    param(
        [string]$Label,
        [hashtable]$SourceMap,
        [hashtable]$DestinationMap
    )

    $Missing = @(
        $SourceMap.Keys |
            Where-Object { -not $DestinationMap.ContainsKey($_) }
    )

    $Extra = @(
        $DestinationMap.Keys |
            Where-Object { -not $SourceMap.ContainsKey($_) }
    )

    if ($Missing.Count -eq 0 -and $Extra.Count -eq 0) {
        Add-ValidationResult "$Label names" "Passed" "All names match."
    }
    else {
        Add-ValidationResult "$Label names" "Failed" `
            "Missing: $($Missing -join ', '); Extra: $($Extra -join ', ')"
    }

    foreach ($Ref in $SourceMap.Keys) {
        if ($DestinationMap.ContainsKey($Ref) -and
            $SourceMap[$Ref] -eq $DestinationMap[$Ref]) {

            Add-ValidationResult "$Label SHA: $Ref" "Passed" "SHA matches."
        }
        else {
            Add-ValidationResult "$Label SHA: $Ref" "Failed" `
                "SHA differs or destination reference is missing."
        }
    }
}

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " GitHub Repository Migration Validation" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }

    New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force |
        Out-Null

    if (-not $SourceToken) {
        $SourceToken = Read-Host "Enter SOURCE GitHub token" -AsSecureString
        $OwnSourceToken = $true
    }

    if (-not $DestinationToken) {
        $DestinationToken = Read-Host "Enter DESTINATION GitHub token" -AsSecureString
        $OwnDestinationToken = $true
    }

    $SourcePlainToken = Convert-SecureToken $SourceToken
    $DestinationPlainToken = Convert-SecureToken $DestinationToken

    $SourceHeaders = Get-GitHubHeaders $SourcePlainToken
    $DestinationHeaders = Get-GitHubHeaders $DestinationPlainToken

    Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

    $SourceUser = Invoke-GitHubGet `
        -Uri "https://api.github.com/user" `
        -Headers $SourceHeaders

    if ($SourceUser.login -ne $SourceOwner) {
        throw "Source token belongs to '$($SourceUser.login)', not '$SourceOwner'."
    }

    Write-Host "Source account verified: $($SourceUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 2: Retrieving source repository..." -ForegroundColor Yellow

    $SourceRepository = Invoke-GitHubGet `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo" `
        -Headers $SourceHeaders

    Write-Host "Source repository verified: $($SourceRepository.full_name)" -ForegroundColor Green

    Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

    $DestinationUser = Invoke-GitHubGet `
        -Uri "https://api.github.com/user" `
        -Headers $DestinationHeaders

    if ($DestinationUser.login -ne $DestinationOwner) {
        throw "Destination token belongs to '$($DestinationUser.login)', not '$DestinationOwner'."
    }

    Write-Host "Destination account verified: $($DestinationUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Retrieving destination repository..." -ForegroundColor Yellow

    $DestinationRepository = Invoke-GitHubGet `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $DestinationHeaders

    Write-Host "Destination repository verified: $($DestinationRepository.full_name)" -ForegroundColor Green

    Add-ValidationResult "Repository existence" "Passed" `
        "Both repositories are accessible."

    Write-Host "`nSTEP 5: Comparing repository visibility..." -ForegroundColor Yellow

    if ($SourceRepository.private -eq $DestinationRepository.private) {
        Add-ValidationResult "Repository visibility" "Passed" "Visibility matches."
    }
    else {
        Add-ValidationResult "Repository visibility" "Failed" `
            "Source and destination visibility differ."
    }

    Write-Host "`nSTEP 6: Comparing default branch..." -ForegroundColor Yellow

    if ($SourceRepository.default_branch -eq $DestinationRepository.default_branch) {
        Add-ValidationResult "Default branch" "Passed" $SourceRepository.default_branch
    }
    else {
        Add-ValidationResult "Default branch" "Failed" `
            "Source: $($SourceRepository.default_branch); Destination: $($DestinationRepository.default_branch)"
    }

    Write-Host "`nSTEP 7: Comparing repository settings..." -ForegroundColor Yellow

    $SettingNames = @(
        "description",
        "homepage",
        "has_issues",
        "has_projects",
        "has_wiki",
        "allow_squash_merge",
        "allow_merge_commit",
        "allow_rebase_merge",
        "allow_auto_merge",
        "delete_branch_on_merge"
    )

    foreach ($Setting in $SettingNames) {

        $SourceValue = $SourceRepository.$Setting
        $DestinationValue = $DestinationRepository.$Setting

        if ([string]$SourceValue -ceq [string]$DestinationValue) {
            Add-ValidationResult "Setting: $Setting" "Passed" "Values match."
        }
        else {
            Add-ValidationResult "Setting: $Setting" "Failed" `
                "Source: '$SourceValue'; Destination: '$DestinationValue'"
        }
    }

    Write-Host "`nSTEP 8: Comparing Git branches..." -ForegroundColor Yellow

    $SourceUrl = "https://github.com/$SourceOwner/$SourceRepo.git"
    $DestinationUrl = "https://github.com/$DestinationOwner/$DestinationRepo.git"

    $SourceBranchRefs = Get-GitRefs `
        -Url $SourceUrl `
        -Token $SourcePlainToken `
        -RefType heads

    $DestinationBranchRefs = Get-GitRefs `
        -Url $DestinationUrl `
        -Token $DestinationPlainToken `
        -RefType heads

    Compare-ReferenceMaps `
        -Label "Branch" `
        -SourceMap $SourceBranchRefs `
        -DestinationMap $DestinationBranchRefs

    Write-Host "`nSTEP 9: Comparing Git tags..." -ForegroundColor Yellow

    $SourceTagRefs = Get-GitRefs `
        -Url $SourceUrl `
        -Token $SourcePlainToken `
        -RefType tags

    $DestinationTagRefs = Get-GitRefs `
        -Url $DestinationUrl `
        -Token $DestinationPlainToken `
        -RefType tags

    Compare-ReferenceMaps `
        -Label "Tag" `
        -SourceMap $SourceTagRefs `
        -DestinationMap $DestinationTagRefs

    Write-Host "`nSTEP 10: Comparing branch commit IDs..." -ForegroundColor Yellow

    foreach ($Branch in $SourceBranchRefs.Keys) {

        if ($DestinationBranchRefs.ContainsKey($Branch) -and
            $SourceBranchRefs[$Branch] -eq $DestinationBranchRefs[$Branch]) {

            Add-ValidationResult "Commit: $Branch" "Passed" "Commit IDs match."
        }
        else {
            Add-ValidationResult "Commit: $Branch" "Failed" `
                "Commit IDs differ or destination branch is missing."
        }
    }

    Write-Host "`nSTEP 11: Generating validation report..." -ForegroundColor Yellow

    $Passed = @($Results | Where-Object { $_.Status -eq "Passed" }).Count
    $Failed = @($Results | Where-Object { $_.Status -eq "Failed" }).Count

    $FinalReport = [PSCustomObject]@{
        SourceRepository = "$SourceOwner/$SourceRepo"
        DestinationRepository = "$DestinationOwner/$DestinationRepo"
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TotalChecks = $Results.Count
        Passed = $Passed
        Failed = $Failed
        OverallStatus = if ($Failed -eq 0) { "Passed" } else { "Failed" }
        Results = @($Results)
    }

    $FinalReport |
        ConvertTo-Json -Depth 15 |
        Set-Content -Path $ReportPath -Encoding utf8

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " VALIDATION SUMMARY" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Passed: $Passed"
    Write-Host "Failed: $Failed"
    Write-Host "Overall: $($FinalReport.OverallStatus)"
    Write-Host "Report: $ReportPath"
    Write-Host "==========================================" -ForegroundColor Cyan

    if ($Failed -gt 0) {
        throw "Migration validation failed. Review the JSON report."
    }

    Write-Host "All migration validation checks passed." -ForegroundColor Green
}
catch {
    Write-Host "`nVALIDATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $SourcePlainToken = $null
    $DestinationPlainToken = $null

    # Dispose only tokens prompted for by this script.
    # Tokens passed in by an orchestrator remain available to that caller.
    if ($OwnSourceToken -and $SourceToken) {
        $SourceToken.Dispose()
    }

    if ($OwnDestinationToken -and $DestinationToken) {
        $DestinationToken.Dispose()
    }

    [GC]::Collect()
    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}
