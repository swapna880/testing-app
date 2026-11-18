
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

$SourcePlainToken = $null
$DestinationPlainToken = $null

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

function Invoke-GitHubRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "GET",
        [object]$Body
    )

    $Parameters = @{
        Uri = $Uri
        Headers = $Headers
        Method = $Method
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $Parameters.Body = ConvertTo-Json -InputObject $Body -Depth 15
        $Parameters.ContentType = "application/json"
    }

    return Invoke-RestMethod @Parameters
}

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Repository Configuration Migration" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not $SourceToken) {
        $SourceToken = Read-Host "Enter SOURCE GitHub token" -AsSecureString
    }

    if (-not $DestinationToken) {
        $DestinationToken = Read-Host "Enter DESTINATION GitHub token" -AsSecureString
    }

    $SourcePlainToken = Convert-SecureToken $SourceToken
    $DestinationPlainToken = Convert-SecureToken $DestinationToken

    $SourceHeaders = Get-GitHubHeaders $SourcePlainToken
    $DestinationHeaders = Get-GitHubHeaders $DestinationPlainToken

    Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

    $SourceUser = Invoke-GitHubRequest `
        -Uri "https://api.github.com/user" `
        -Headers $SourceHeaders

    if ($SourceUser.login -ne $SourceOwner) {
        throw "Source token belongs to '$($SourceUser.login)', not '$SourceOwner'."
    }

    Write-Host "Source account verified: $($SourceUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 2: Reading source repository settings..." -ForegroundColor Yellow

    $SourceSettings = Invoke-GitHubRequest `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo" `
        -Headers $SourceHeaders

    $Settings = [ordered]@{
        description = $SourceSettings.description
        homepage = $SourceSettings.homepage
        has_issues = $SourceSettings.has_issues
        has_projects = $SourceSettings.has_projects
        has_wiki = $SourceSettings.has_wiki
        allow_squash_merge = $SourceSettings.allow_squash_merge
        allow_merge_commit = $SourceSettings.allow_merge_commit
        allow_rebase_merge = $SourceSettings.allow_rebase_merge
        allow_auto_merge = $SourceSettings.allow_auto_merge
        delete_branch_on_merge = $SourceSettings.delete_branch_on_merge
    }

    $SettingsDirectory = Join-Path $ProjectPath "config"
    New-Item -ItemType Directory -Path $SettingsDirectory -Force | Out-Null

    $SettingsFile = Join-Path $SettingsDirectory "repository-settings.json"

    $Settings |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $SettingsFile -Encoding utf8

    Write-Host "Source settings exported to: $SettingsFile" -ForegroundColor Green

    Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

    $DestinationUser = Invoke-GitHubRequest `
        -Uri "https://api.github.com/user" `
        -Headers $DestinationHeaders

    if ($DestinationUser.login -ne $DestinationOwner) {
        throw "Destination token belongs to '$($DestinationUser.login)', not '$DestinationOwner'."
    }

    Write-Host "Destination account verified: $($DestinationUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

    $DestinationUrl = "https://api.github.com/repos/$DestinationOwner/$DestinationRepo"

    $null = Invoke-GitHubRequest `
        -Uri $DestinationUrl `
        -Headers $DestinationHeaders

    Write-Host "Destination repository verified." -ForegroundColor Green

    Write-Host "`nSTEP 5: Applying repository settings..." -ForegroundColor Yellow

    $null = Invoke-GitHubRequest `
        -Uri $DestinationUrl `
        -Headers $DestinationHeaders `
        -Method PATCH `
        -Body $Settings

    Write-Host "Repository settings update request completed." -ForegroundColor Green

    Write-Host "`nSTEP 6: Verifying destination settings..." -ForegroundColor Yellow

    $UpdatedSettings = Invoke-GitHubRequest `
        -Uri $DestinationUrl `
        -Headers $DestinationHeaders

    $Verification = [ordered]@{
        description = $UpdatedSettings.description
        homepage = $UpdatedSettings.homepage
        has_issues = $UpdatedSettings.has_issues
        has_projects = $UpdatedSettings.has_projects
        has_wiki = $UpdatedSettings.has_wiki
        allow_squash_merge = $UpdatedSettings.allow_squash_merge
        allow_merge_commit = $UpdatedSettings.allow_merge_commit
        allow_rebase_merge = $UpdatedSettings.allow_rebase_merge
        allow_auto_merge = $UpdatedSettings.allow_auto_merge
        delete_branch_on_merge = $UpdatedSettings.delete_branch_on_merge
    }

    $VerificationFile = Join-Path $SettingsDirectory "destination-settings-verification.json"

    $Verification |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $VerificationFile -Encoding utf8

    $Differences = @()

    foreach ($Key in $Settings.Keys) {
        if ([string]($Settings[$Key]) -cne [string]($Verification[$Key])) {
            $Differences += $Key
        }
    }

    if ($Differences.Count -gt 0) {
        throw "Settings verification mismatch: $($Differences -join ', ')"
    }

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host " CONFIGURATION MIGRATION SUCCESSFUL" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "Source: $SourceOwner/$SourceRepo"
    Write-Host "Destination: $DestinationOwner/$DestinationRepo"
    Write-Host "Settings verified: $($Settings.Count)"
    Write-Host "Verification file: $VerificationFile"
}
catch {
    Write-Host "`nCONFIGURATION MIGRATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $SourcePlainToken = $null
    $DestinationPlainToken = $null

    if ($SourceToken) {
        $SourceToken.Dispose()
    }

    if ($DestinationToken) {
        $DestinationToken.Dispose()
    }

    [GC]::Collect()
    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}
