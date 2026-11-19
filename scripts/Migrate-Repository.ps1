
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$SourceRepo = "testing-app",
    [string]$DestinationRepo = "migration-automation-test",
    [string]$ProjectPath = "C:\GitHub-Migration-POC",
    [SecureString]$SourceToken,
    [SecureString]$DestinationToken
)
$OwnSourceToken = $false
$OwnDestinationToken = $false

$ErrorActionPreference = "Stop"

$MirrorPath = Join-Path $ProjectPath "$SourceRepo-to-$DestinationRepo-mirror.git"
$SourceUrl = "https://github.com/$SourceOwner/$SourceRepo.git"
$DestinationUrl = "https://github.com/$DestinationOwner/$DestinationRepo.git"

$SourcePlainToken = $null
$DestinationPlainToken = $null
$SourceBstr = [IntPtr]::Zero
$DestinationBstr = [IntPtr]::Zero

function Convert-SecureTokenToPlainText {
    param([SecureString]$SecureValue)

    if ($null -eq $SecureValue) {
        throw "A required token was not supplied."
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

function Get-GitAuthorizationHeader {
    param([string]$Token)

    $Bytes = [Text.Encoding]::UTF8.GetBytes("x-access-token:$Token")
    $Encoded = [Convert]::ToBase64String($Bytes)

    return "AUTHORIZATION: basic $Encoded"
}

function Invoke-GitWithToken {
    param(
        [string[]]$GitArguments,
        [string]$Token
    )

    $Header = Get-GitAuthorizationHeader -Token $Token

    & git -c "http.extraheader=$Header" @GitArguments

    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed. Review the Git output above."
    }
}

function Test-GitHubIdentity {
    param(
        [string]$Token,
        [string]$ExpectedOwner,
        [string]$AccountLabel
    )

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept        = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $User = Invoke-RestMethod `
        -Uri "https://api.github.com/user" `
        -Headers $Headers `
        -Method Get

    if ($User.login -ne $ExpectedOwner) {
        throw "$AccountLabel token belongs to '$($User.login)', not '$ExpectedOwner'."
    }

    Write-Host "$AccountLabel account verified: $($User.login)" -ForegroundColor Green
}

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "       GitHub Repository Migration        " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }

    if (-not (Test-Path $ProjectPath)) {
        throw "Project directory does not exist: $ProjectPath"
    }

    if (-not $SourceToken) {
    $SourceToken = Read-Host "Enter SOURCE GitHub token" -AsSecureString
    $OwnSourceToken = $true
    }

    if (-not $DestinationToken) {
    $DestinationToken = Read-Host "Enter DESTINATION GitHub token" -AsSecureString
    $OwnDestinationToken = $true
    }

    $SourcePlainToken = Convert-SecureTokenToPlainText $SourceToken
    $DestinationPlainToken = Convert-SecureTokenToPlainText $DestinationToken

    Write-Host "`nSTEP 1: Verifying GitHub accounts..." -ForegroundColor Yellow

    Test-GitHubIdentity -Token $SourcePlainToken `
        -ExpectedOwner $SourceOwner -AccountLabel "Source"

    Test-GitHubIdentity -Token $DestinationPlainToken `
        -ExpectedOwner $DestinationOwner -AccountLabel "Destination"

    Write-Host "`nSTEP 2: Checking source repository..." -ForegroundColor Yellow

    $SourceHeaders = @{
        Authorization = "Bearer $SourcePlainToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $SourceRepository = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo" `
        -Headers $SourceHeaders `
        -Method Get

    Write-Host "Source repository verified: $($SourceRepository.full_name)" -ForegroundColor Green

    Write-Host "`nSTEP 3: Checking destination repository..." -ForegroundColor Yellow

    $DestinationHeaders = @{
        Authorization = "Bearer $DestinationPlainToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $DestinationRepository = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $DestinationHeaders `
        -Method Get

    Write-Host "Destination repository verified: $($DestinationRepository.full_name)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Checking destination Git references..." -ForegroundColor Yellow

    $DestinationRefOutput = & git -c "http.extraheader=$(Get-GitAuthorizationHeader $DestinationPlainToken)" ls-remote --refs $DestinationUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Could not verify destination references."
    }

    if ($DestinationRefOutput) {
        throw "Destination is not empty. Migration stopped to prevent overwriting existing references."
    }

    Write-Host "Destination has no Git references." -ForegroundColor Green

    Write-Host "`nSTEP 5: Checking local mirror directory..." -ForegroundColor Yellow

    if (Test-Path $MirrorPath) {
        throw "Mirror directory already exists: $MirrorPath. Inspect it before retrying."
    }

    Write-Host "`nSTEP 6: Cloning source repository as a mirror..." -ForegroundColor Yellow

    Invoke-GitWithToken -Token $SourcePlainToken -GitArguments @(
        "clone", "--mirror", $SourceUrl, $MirrorPath
    )

    Write-Host "Source mirror clone completed." -ForegroundColor Green

    Write-Host "`nSTEP 7: Pushing mirror to destination..." -ForegroundColor Yellow

    Invoke-GitWithToken -Token $DestinationPlainToken -GitArguments @(
        "-C", $MirrorPath, "push", "--mirror", $DestinationUrl
    )

    Write-Host "Mirror push completed." -ForegroundColor Green

    Write-Host "`nSTEP 8: Verifying destination references..." -ForegroundColor Yellow

    $SourceRefs = & git -c "http.extraheader=$(Get-GitAuthorizationHeader $SourcePlainToken)" ls-remote --refs $SourceUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Could not retrieve source references for final verification."
    }
    if (-not $SourceRefs) {
    throw "Source repository contains no Git references. Migration stopped."
    }
    $DestinationRefs = & git -c "http.extraheader=$(Get-GitAuthorizationHeader $DestinationPlainToken)" ls-remote --refs $DestinationUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Could not retrieve destination references for final verification."
    }

    $SourceRefMap = @{}
    foreach ($Ref in $SourceRefs) {
        $Parts = $Ref -split "\s+", 2
        if ($Parts.Count -eq 2) {
            $SourceRefMap[$Parts[1]] = $Parts[0]
        }
    }

    $DestinationRefMap = @{}
    foreach ($Ref in $DestinationRefs) {
        $Parts = $Ref -split "\s+", 2
        if ($Parts.Count -eq 2) {
            $DestinationRefMap[$Parts[1]] = $Parts[0]
        }
    }

    if ($SourceRefMap.Count -ne $DestinationRefMap.Count) {
        throw "Reference count mismatch. Source: $($SourceRefMap.Count), Destination: $($DestinationRefMap.Count)"
    }

    foreach ($RefName in $SourceRefMap.Keys) {
        if (-not $DestinationRefMap.ContainsKey($RefName) -or
            $SourceRefMap[$RefName] -ne $DestinationRefMap[$RefName]) {
            throw "Reference verification failed for: $RefName"
        }
    }

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       REPOSITORY MIGRATION SUCCESS       " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "Source: $SourceOwner/$SourceRepo"
    Write-Host "Destination: $DestinationOwner/$DestinationRepo"
    Write-Host "Verified references: $($SourceRefMap.Count)"
    Write-Host "Reference validation: PASSED"
    Write-Host "Mirror folder: $MirrorPath"
}
catch {
    Write-Host "`nMIGRATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $SourcePlainToken = $null
    $DestinationPlainToken = $null

    if ($OwnSourceToken -and $SourceToken) {
        $SourceToken.Dispose()
    }

    if ($OwnDestinationToken -and $DestinationToken) {
        $DestinationToken.Dispose()
    }

    [GC]::Collect()
    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}
