
param(
    [string]$SourceOwner = "swapna880",
    [string]$SourceRepo = "testing-app",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$DestinationRepo = "migration-automation-test",
    [string]$ProjectPath = "C:\github-migration\post-migration-validation",
    [SecureString]$SourceToken,
    [SecureString]$DestinationToken
)

$OwnSourceToken = $false
$OwnDestinationToken = $false
$ErrorActionPreference = "Stop"

$ExportPath = Join-Path $ProjectPath "exports\rulesets.json"
$PayloadFolder = Join-Path $ProjectPath "exports\ruleset-payloads"
$ReportPath = Join-Path $ProjectPath "reports\Ruleset-Migration-Report.json"

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

function Invoke-GitHubApi {
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
        $Parameters.Body = ConvertTo-Json -InputObject $Body -Depth 30
        $Parameters.ContentType = "application/json"
    }

    return Invoke-RestMethod @Parameters
}

function Get-HttpStatusCode {
    param($ErrorRecord)

    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return 0
    }
}

function Get-RulesetPayload {
    param($Ruleset)

    return [ordered]@{
        name = $Ruleset.name
        target = $Ruleset.target
        enforcement = $Ruleset.enforcement
        conditions = $Ruleset.conditions
        rules = $Ruleset.rules
        bypass_actors = @($Ruleset.bypass_actors)
    }
}

try {
    New-Item -ItemType Directory -Force -Path (Split-Path $ExportPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath) | Out-Null
    New-Item -ItemType Directory -Force -Path $PayloadFolder | Out-Null

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
        SourceAccessStatus = "Pending"
        DestinationAccessStatus = "Pending"
        ExportStatus = "Pending"
        MigrationStatus = "Pending"
        TotalRulesets = 0
        Migrated = 0
        AlreadyPresent = 0
        Failed = 0
        Restricted = 0
        Results = @()
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " GitHub Ruleset Migration" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

    $SourceUser = Invoke-GitHubApi `
        -Uri "https://api.github.com/user" `
        -Headers $SourceHeaders

    if ($SourceUser.login -ne $SourceOwner) {
        throw "Source token belongs to '$($SourceUser.login)', not '$SourceOwner'."
    }

    Write-Host "Source account verified: $($SourceUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 2: Exporting source rulesets..." -ForegroundColor Yellow

    $SourceRulesets = @()

    try {
        $SourceRulesets = @(
            Invoke-GitHubApi `
                -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo/rulesets?per_page=100" `
                -Headers $SourceHeaders
        )

        $Report.SourceAccessStatus = "Accessible"
        $Report.ExportStatus = "Success"

        $SourceRulesets |
            ConvertTo-Json -Depth 30 |
            Set-Content -Path $ExportPath -Encoding utf8

        # Reload exported JSON as separate ruleset objects.
        $ExportedRulesets = Get-Content -Path $ExportPath -Raw | ConvertFrom-Json
        $SourceRulesets = @($ExportedRulesets | ForEach-Object { $_ })

        if ($SourceRulesets.Count -eq 0) {
            throw "The exported ruleset file contains no rulesets."
        }

        foreach ($SourceItem in $SourceRulesets) {
            if ($SourceItem.name -is [array]) {
                throw "Invalid ruleset structure: a ruleset name contains multiple values."
            }
        }

        $Report.TotalRulesets = $SourceRulesets.Count

        # Remove stale payload files from previous runs.
        Get-ChildItem -Path $PayloadFolder -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        Write-Host "Source rulesets found: $($SourceRulesets.Count)" -ForegroundColor Green
        Write-Host "Rulesets to process: $($SourceRulesets.name -join ', ')" -ForegroundColor Cyan
    }
    catch {
        $StatusCode = Get-HttpStatusCode $_

        if ($StatusCode -eq 403) {
            $Report.SourceAccessStatus = "Restricted (HTTP 403)"
            $Report.ExportStatus = "Restricted"
            $Report.MigrationStatus = "Not performed - source ruleset access restricted"

            Write-Warning "GitHub denied source ruleset access (HTTP 403)."
            Write-Warning "Check repository plan and token/API permissions."
        }
        else {
            throw "Source ruleset export failed: $($_.Exception.Message)"
        }
    }

    if ($Report.ExportStatus -eq "Restricted") {
        $Report.Restricted = 1
        $Report.Results = @(
            [PSCustomObject]@{
                Name = "Source ruleset collection"
                Status = "Restricted"
                Details = "Source ruleset API returned HTTP 403. No destination changes were attempted."
            }
        )

        $Report |
            ConvertTo-Json -Depth 30 |
            Set-Content -Path $ReportPath -Encoding utf8

        Write-Host "`nRuleset migration skipped because source access is restricted." -ForegroundColor Yellow
        Write-Host "Report: $ReportPath"
        return
    }

    Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

    $DestinationUser = Invoke-GitHubApi `
        -Uri "https://api.github.com/user" `
        -Headers $DestinationHeaders

    if ($DestinationUser.login -ne $DestinationOwner) {
        throw "Destination token belongs to '$($DestinationUser.login)', not '$DestinationOwner'."
    }

    Write-Host "Destination account verified: $($DestinationUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

    $DestinationRepository = Invoke-GitHubApi `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $DestinationHeaders

    $Report.DestinationAccessStatus = "Verified"

    Write-Host "Destination repository verified." -ForegroundColor Green

    Write-Host "`nSTEP 5: Retrieving existing destination rulesets..." -ForegroundColor Yellow

    try {
        $DestinationRulesets = @(
            Invoke-GitHubApi `
                -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/rulesets?per_page=100" `
                -Headers $DestinationHeaders
        )
    }
    catch {
        $StatusCode = Get-HttpStatusCode $_

        if ($StatusCode -eq 403) {
            $Report.DestinationAccessStatus = "Restricted (HTTP 403)"
            $Report.Restricted = 1
            $Report.MigrationStatus = "Not performed - destination ruleset access restricted"

            $Report.Results = @(
                [PSCustomObject]@{
                    Name = "Destination ruleset collection"
                    Status = "Restricted"
                    Details = "GitHub denied destination ruleset access (HTTP 403). No destination rulesets were changed."
                }
            )

            $Report |
                ConvertTo-Json -Depth 30 |
                Set-Content -Path $ReportPath -Encoding utf8

            Write-Warning "Destination ruleset access is restricted (HTTP 403). Ruleset creation was skipped."
            Write-Host "Report: $ReportPath"
            return
        }

        throw
    }

    $Results = @()

    Write-Host "`nSTEP 6: Processing source rulesets..." -ForegroundColor Yellow

    foreach ($SourceItem in $SourceRulesets) {

        $Name = $SourceItem.name

        $Result = [ordered]@{
            Name = $Name
            Status = "Pending"
            DestinationId = $null
            Verification = "Pending"
            Details = ""
        }

        try {
            Write-Host "`nProcessing: $Name" -ForegroundColor Cyan

            $SourceDetail = Invoke-GitHubApi `
                -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo/rulesets/$($SourceItem.id)" `
                -Headers $SourceHeaders

            $Payload = Get-RulesetPayload $SourceDetail

            $SafeName = $Name -replace '[^\w.-]', '_'
            $PayloadPath = Join-Path $PayloadFolder "$SafeName.json"

            $Payload |
                ConvertTo-Json -Depth 30 |
                Set-Content -Path $PayloadPath -Encoding utf8

            $Existing = @(
                $DestinationRulesets |
                    Where-Object { $_.name -eq $Name }
            )

            if ($Existing.Count -gt 0) {
                $DestinationId = $Existing[0].id

                Write-Host "Ruleset already exists. Checking configuration..." -ForegroundColor Yellow

                $Result.Status = "Already present"
                $Report.AlreadyPresent++
            }
            else {
                $Created = Invoke-GitHubApi `
                    -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/rulesets" `
                    -Headers $DestinationHeaders `
                    -Method POST `
                    -Body $Payload

                $DestinationId = $Created.id

                $Result.Status = "Migrated"
                $Report.Migrated++

                Write-Host "Ruleset created. ID: $DestinationId" -ForegroundColor Green
            }

            $Verified = Invoke-GitHubApi `
                -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/rulesets/$DestinationId" `
                -Headers $DestinationHeaders

            $ActualPayload = Get-RulesetPayload $Verified

            $ExpectedJson = ConvertTo-Json -InputObject $Payload -Depth 30 -Compress
            $ActualJson = ConvertTo-Json -InputObject $ActualPayload -Depth 30 -Compress

            if ($ExpectedJson -ne $ActualJson) {
                throw "Destination ruleset configuration does not match source."
            }

            $Result.DestinationId = $DestinationId
            $Result.Verification = "Passed"
            $Result.Details = "Ruleset configuration matches source, including enforcement setting."

            Write-Host "Ruleset verification passed." -ForegroundColor Green
        }
        catch {
            $Result.Status = "Failed"
            $Result.Verification = "Failed"

            # Capture GitHub's detailed API response, including HTTP 422 reasons.
            $GitHubError = $_.ErrorDetails.Message

            if ([string]::IsNullOrWhiteSpace($GitHubError)) {
                $GitHubError = $_.Exception.Message
            }

            $Result.Details = $GitHubError
            $Report.Failed++

            Write-Warning "$Name failed: $GitHubError"
        }

        $Results += [PSCustomObject]$Result

        $DestinationRulesets = @(
            Invoke-GitHubApi `
                -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo/rulesets?per_page=100" `
                -Headers $DestinationHeaders
        )
    }

    $Report.Results = $Results

    if ($Report.Failed -eq 0 -and
        ($Report.Migrated + $Report.AlreadyPresent) -eq $Report.TotalRulesets) {
        $Report.MigrationStatus = "Success"
    }
    else {
        $Report.MigrationStatus = "Partially completed or failed"
    }

    $Report.Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

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
}
catch {
    Write-Host "`nRULESET MIGRATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
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
