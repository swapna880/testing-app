
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
$OwnSourceToken = $false
$OwnDestinationToken = $false

$ExportPath = Join-Path $ProjectPath "exports\collaborators.json"
$ReportPath = Join-Path $ProjectPath "reports\Collaborator-Migration-Report.json"

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

function Get-GitHubPaginatedData {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $AllResults = @()
    $Page = 1

    do {
        $Separator = if ($Uri.Contains("?")) { "&" } else { "?" }
        $PageUri = "${Uri}${Separator}per_page=100&page=$Page"

        $Response = Invoke-RestMethod `
            -Uri $PageUri `
            -Headers $Headers `
            -Method Get `
            -ErrorAction Stop

        $AllResults += @($Response)
        $Page++

    } while (@($Response).Count -eq 100)

    return ,$AllResults
}

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Collaborator Migration Assessment" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    New-Item -ItemType Directory -Force -Path (Split-Path $ExportPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null

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

    $Report = [ordered]@{
        SourceRepository = "$SourceOwner/$SourceRepo"
        DestinationRepository = "$DestinationOwner/$DestinationRepo"
        SourceExportStatus = "Pending"
        DestinationAccessStatus = "Pending"
        TotalSourceCollaborators = 0
        SourceOwnerCount = 0
        DestinationOwnerCount = 0
        ExternalCollaborators = 0
        ExternalMigrationStatus = "Assessment only - external invitations not performed"
        Results = @()
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

    $SourceUser = Invoke-RestMethod `
        -Uri "https://api.github.com/user" `
        -Headers $SourceHeaders

    if ($SourceUser.login -ne $SourceOwner) {
        throw "Source token belongs to '$($SourceUser.login)', not '$SourceOwner'."
    }

    Write-Host "Source account verified: $($SourceUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 2: Exporting source collaborators..." -ForegroundColor Yellow

    $SourceCollaborators = Get-GitHubPaginatedData `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo/collaborators?affiliation=direct" `
        -Headers $SourceHeaders

    $Export = @(
        foreach ($Collaborator in $SourceCollaborators) {
            [PSCustomObject]@{
                SourceUsername = $Collaborator.login
                SourceRole = $Collaborator.role_name
                Permissions = $Collaborator.permissions
            }
        }
    )

    $Export |
        ConvertTo-Json -Depth 15 |
        Set-Content -Path $ExportPath -Encoding utf8

    $Report.SourceExportStatus = "Success"
    $Report.TotalSourceCollaborators = $SourceCollaborators.Count

    Write-Host "Exported $($SourceCollaborators.Count) collaborator records." -ForegroundColor Green
    Write-Host "Export file: $ExportPath"

    Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

    $DestinationUser = Invoke-RestMethod `
        -Uri "https://api.github.com/user" `
        -Headers $DestinationHeaders

    if ($DestinationUser.login -ne $DestinationOwner) {
        throw "Destination token belongs to '$($DestinationUser.login)', not '$DestinationOwner'."
    }

    Write-Host "Destination account verified: $($DestinationUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

    $null = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $DestinationHeaders

    $Report.DestinationAccessStatus = "Verified"

    Write-Host "Destination repository access verified." -ForegroundColor Green

    Write-Host "`nSTEP 5: Checking destination collaborators..." -ForegroundColor Yellow

    $DestinationCollaborators = Get-GitHubPaginatedData `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/collaborators?affiliation=direct" `
        -Headers $DestinationHeaders

    $Results = @()

    foreach ($Collaborator in $SourceCollaborators) {

        $Username = $Collaborator.login

        $DestinationMatch = $DestinationCollaborators |
            Where-Object { $_.login -eq $Username } |
            Select-Object -First 1

        if ($Username -eq $SourceOwner) {
            $Status = "Source owner - Not transferable as collaborator"
            $Report.SourceOwnerCount++
        }
        elseif ($Username -eq $DestinationOwner) {
            $Status = "Destination owner - Ownership verified"
            $Report.DestinationOwnerCount++
        }
        elseif ($DestinationMatch) {
            $Status = "Already has destination access"
        }
        else {
            $Status = "Not migrated - External account mapping and invitation required"
            $Report.ExternalCollaborators++
        }

        $Results += [PSCustomObject]@{
            SourceUsername = $Username
            SourceRole = $Collaborator.role_name
            DestinationAccessFound = [bool]$DestinationMatch
            DestinationRole = if ($DestinationMatch) {
                $DestinationMatch.role_name
            } else {
                "Not verified"
            }
            Status = $Status
        }

        Write-Host "$Username : $Status"
    }

    $Report.Results = $Results
    $Report.Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $Report |
        ConvertTo-Json -Depth 15 |
        Set-Content -Path $ReportPath -Encoding utf8

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host " COLLABORATOR ASSESSMENT COMPLETED" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "Source collaborators: $($Report.TotalSourceCollaborators)"
    Write-Host "Source owner: $($Report.SourceOwnerCount)"
    Write-Host "Destination owner: $($Report.DestinationOwnerCount)"
    Write-Host "External collaborators: $($Report.ExternalCollaborators)"
    Write-Host "External migration: $($Report.ExternalMigrationStatus)"
    Write-Host "Export: $ExportPath"
    Write-Host "Report: $ReportPath"
}
catch {
    Write-Host "`nCOLLABORATOR ASSESSMENT FAILED: $($_.Exception.Message)" -ForegroundColor Red
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

    $SourceToken = $null
    $DestinationToken = $null

    [GC]::Collect()
    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}
