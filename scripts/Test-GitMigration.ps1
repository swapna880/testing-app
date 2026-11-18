
param(
    [string]$SourceAccountId = "swapna880",
    [string]$SourceRepository = "testing-app",
    [string]$DestinationAccountId = "swapnakuntala",
    [string]$DestinationRepository = "migration-automation-test"
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$ProjectRoot = Split-Path $PSScriptRoot -Parent

$MirrorPath = Join-Path $ProjectRoot "testing-app-migration-test.git"

$SourceRepoUrl = "https://github.com/$SourceAccountId/$SourceRepository.git"
$DestinationRepoUrl = "https://github.com/$DestinationAccountId/$DestinationRepository.git"

$script:LastGitExitCode = 0

# ------------------------------------------------------------
# CONVERT SECURE TOKEN
# ------------------------------------------------------------

function Convert-SecureToken {
    param(
        [System.Security.SecureString]$SecureToken
    )

    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

# ------------------------------------------------------------
# GITHUB API REQUEST
# ------------------------------------------------------------

function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Token
    )

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
}

# ------------------------------------------------------------
# GIT COMMAND WITH INDIVIDUAL TOKEN
# ------------------------------------------------------------

function Invoke-GitWithToken {
    param(
        [string[]]$GitArguments,
        [string]$Token
    )

    $AuthText = "x-access-token:$Token"
    $AuthBytes = [System.Text.Encoding]::ASCII.GetBytes($AuthText)
    $EncodedAuth = [Convert]::ToBase64String($AuthBytes)

    $ExtraHeader = "AUTHORIZATION: basic $EncodedAuth"

    $GitConfig = "http.https://github.com/.extraheader=$ExtraHeader"

    $Output = @(
        & git -c $GitConfig @GitArguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )

    $ExitCode = $LASTEXITCODE

    $script:LastGitExitCode = $ExitCode

    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output = $Output
    }
}

# ------------------------------------------------------------
# VALIDATE GIT REFERENCES
# ------------------------------------------------------------

function Get-ReferenceMap {
    param(
        [string[]]$Output
    )

    $ReferenceMap = @{}

    foreach ($Line in $Output) {

        if ($Line -match '^([0-9a-fA-F]+)\s+(.+)$') {

            $SHA = $Matches[1].ToLower()
            $RefName = $Matches[2]

            $ReferenceMap[$RefName] = $SHA
        }
    }

    return $ReferenceMap
}

# ------------------------------------------------------------
# MAIN MIGRATION PROCESS
# ------------------------------------------------------------

$SourceTokenPlain = $null
$DestinationTokenPlain = $null

$SourceSecureToken = $null
$DestinationSecureToken = $null

$PreviousGitPromptSetting = $env:GIT_TERMINAL_PROMPT

try {

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "       GITHUB MIGRATION TEST" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # --------------------------------------------------------
    # PRECHECKS
    # --------------------------------------------------------

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or not available in PATH."
    }

    Write-Host "`nGit version:" -ForegroundColor Cyan
    & git --version

    if (Test-Path $MirrorPath) {
        throw "Mirror directory already exists: $MirrorPath. Do not delete it without checking its contents."
    }

    # Prevent Git from prompting for credentials outside our secure prompts.
    $env:GIT_TERMINAL_PROMPT = "0"

    # --------------------------------------------------------
    # COLLECT TOKENS
    # --------------------------------------------------------

    Write-Host "`nEnter Source GitHub Token:" -ForegroundColor Yellow
    $SourceSecureToken = Read-Host "Source Token" -AsSecureString

    Write-Host "`nEnter Destination GitHub Token:" -ForegroundColor Yellow
    $DestinationSecureToken = Read-Host "Destination Token" -AsSecureString

    $SourceTokenPlain = Convert-SecureToken $SourceSecureToken
    $DestinationTokenPlain = Convert-SecureToken $DestinationSecureToken

    # --------------------------------------------------------
    # STEP 1: SOURCE ACCOUNT
    # --------------------------------------------------------

    Write-Host "`nStep 1: Verifying source account..." -ForegroundColor Cyan

    $SourceUser = Invoke-GitHubApi `
        -Uri "https://api.github.com/user" `
        -Token $SourceTokenPlain

    if ($SourceUser.login -ne $SourceAccountId) {
        throw "Source token belongs to $($SourceUser.login), not $SourceAccountId."
    }

    Write-Host "Source verified: $($SourceUser.login)" -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 2: DESTINATION ACCOUNT
    # --------------------------------------------------------

    Write-Host "`nStep 2: Verifying destination account..." -ForegroundColor Cyan

    $DestinationUser = Invoke-GitHubApi `
        -Uri "https://api.github.com/user" `
        -Token $DestinationTokenPlain

    if ($DestinationUser.login -ne $DestinationAccountId) {
        throw "Destination token belongs to $($DestinationUser.login), not $DestinationAccountId."
    }

    Write-Host "Destination verified: $($DestinationUser.login)" -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 3: SOURCE REPOSITORY
    # --------------------------------------------------------

    Write-Host "`nStep 3: Checking source repository..." -ForegroundColor Cyan

    $SourceRepoData = Invoke-GitHubApi `
        -Uri "https://api.github.com/repos/$SourceAccountId/$SourceRepository" `
        -Token $SourceTokenPlain

    Write-Host "Source repository access confirmed." -ForegroundColor Green
    Write-Host "Source repository: $($SourceRepoData.full_name)"
    Write-Host "Source visibility: $($SourceRepoData.visibility)"

    # --------------------------------------------------------
    # STEP 4: DESTINATION REPOSITORY
    # --------------------------------------------------------

    Write-Host "`nStep 4: Checking destination repository..." -ForegroundColor Cyan

    $DestinationRepoData = Invoke-GitHubApi `
        -Uri "https://api.github.com/repos/$DestinationAccountId/$DestinationRepository" `
        -Token $DestinationTokenPlain

    Write-Host "Destination repository details retrieved successfully." -ForegroundColor Green

    Write-Host "Destination repository: $($DestinationRepoData.full_name)"
    Write-Host "Destination visibility: $($DestinationRepoData.visibility)"

    # --------------------------------------------------------
    # STEP 5: CHECK DESTINATION GIT REFERENCES
    # --------------------------------------------------------

    Write-Host "`nStep 5: Checking destination Git references..." -ForegroundColor Cyan

    $DestinationRefCheck = Invoke-GitWithToken `
        -GitArguments @("ls-remote", "--refs", $DestinationRepoUrl) `
        -Token $DestinationTokenPlain

    if ($DestinationRefCheck.ExitCode -ne 0) {
        throw "Unable to verify destination Git references. $($DestinationRefCheck.Output -join ' ')"
    }

    $ExistingDestinationRefs = Get-ReferenceMap -Output $DestinationRefCheck.Output

    if ($ExistingDestinationRefs.Count -gt 0) {
        throw "Destination already contains Git references. Migration stopped to protect existing refs."
    }

    Write-Host "Destination has no Git references." -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 6: CHECK SOURCE GIT REFERENCES
    # --------------------------------------------------------

    Write-Host "`nStep 6: Reading source Git references..." -ForegroundColor Cyan

    $SourceRefCheck = Invoke-GitWithToken `
        -GitArguments @("ls-remote", "--refs", $SourceRepoUrl) `
        -Token $SourceTokenPlain

    if ($SourceRefCheck.ExitCode -ne 0) {
        throw "Unable to read source Git references. $($SourceRefCheck.Output -join ' ')"
    }

    $SourceReferences = Get-ReferenceMap -Output $SourceRefCheck.Output

    if ($SourceReferences.Count -eq 0) {
        throw "No Git references found in the source repository."
    }

    $SourceBranches = @(
        $SourceReferences.Keys | Where-Object { $_ -like "refs/heads/*" }
    )

    $SourceTags = @(
        $SourceReferences.Keys | Where-Object { $_ -like "refs/tags/*" }
    )

    Write-Host "Source branches found: $($SourceBranches.Count)" -ForegroundColor Green
    Write-Host "Source tags found: $($SourceTags.Count)" -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 7: CLONE SOURCE AS MIRROR
    # --------------------------------------------------------

    Write-Host "`nStep 7: Cloning source repository as mirror..." -ForegroundColor Cyan

    $CloneResult = Invoke-GitWithToken `
        -GitArguments @("clone", "--mirror", $SourceRepoUrl, $MirrorPath) `
        -Token $SourceTokenPlain

    foreach ($Line in $CloneResult.Output) {
        Write-Host $Line
    }

    if ($CloneResult.ExitCode -ne 0) {
        throw "Git mirror clone failed. Check the output above."
    }

    if (-not (Test-Path $MirrorPath)) {
        throw "Mirror clone did not create the expected directory."
    }

    Write-Host "Mirror clone completed successfully." -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 8: PUSH MIRROR TO DESTINATION
    # --------------------------------------------------------

    Write-Host "`nStep 8: Pushing mirror to destination..." -ForegroundColor Cyan

    $PushResult = Invoke-GitWithToken `
        -GitArguments @("-C", $MirrorPath, "push", "--mirror", $DestinationRepoUrl) `
        -Token $DestinationTokenPlain

    foreach ($Line in $PushResult.Output) {
        Write-Host $Line
    }

    if ($PushResult.ExitCode -ne 0) {
        throw "Git mirror push failed. Check the output above."
    }

    Write-Host "Mirror push completed successfully." -ForegroundColor Green

    # --------------------------------------------------------
    # STEP 9: VERIFY DESTINATION REFERENCES
    # --------------------------------------------------------

    Write-Host "`nStep 9: Validating destination references..." -ForegroundColor Cyan

    $DestinationFinalCheck = Invoke-GitWithToken `
        -GitArguments @("ls-remote", "--refs", $DestinationRepoUrl) `
        -Token $DestinationTokenPlain

    if ($DestinationFinalCheck.ExitCode -ne 0) {
        throw "Unable to read destination references after migration."
    }

    $DestinationReferences = Get-ReferenceMap -Output $DestinationFinalCheck.Output

    $MissingReferences = @()
    $MismatchedReferences = @()

    foreach ($RefName in $SourceReferences.Keys) {

        if (-not $DestinationReferences.ContainsKey($RefName)) {
            $MissingReferences += $RefName
        }
        elseif ($SourceReferences[$RefName] -ne $DestinationReferences[$RefName]) {
            $MismatchedReferences += $RefName
        }
    }

    $UnexpectedReferences = @()

    foreach ($RefName in $DestinationReferences.Keys) {

        if (-not $SourceReferences.ContainsKey($RefName)) {
            $UnexpectedReferences += $RefName
        }
    }

    Write-Host "`nSource reference count: $($SourceReferences.Count)"
    Write-Host "Destination reference count: $($DestinationReferences.Count)"

    Write-Host "Source branch count: $($SourceBranches.Count)"
    Write-Host "Destination branch count: $(@($DestinationReferences.Keys | Where-Object { $_ -like 'refs/heads/*' }).Count)"

    Write-Host "Source tag count: $($SourceTags.Count)"
    Write-Host "Destination tag count: $(@($DestinationReferences.Keys | Where-Object { $_ -like 'refs/tags/*' }).Count)"

    if (
        $MissingReferences.Count -gt 0 -or
        $MismatchedReferences.Count -gt 0 -or
        $UnexpectedReferences.Count -gt 0
    ) {

        Write-Host "`nReference validation failed." -ForegroundColor Red

        if ($MissingReferences.Count -gt 0) {
            Write-Host "Missing references:" -ForegroundColor Red
            $MissingReferences | ForEach-Object { Write-Host $_ }
        }

        if ($MismatchedReferences.Count -gt 0) {
            Write-Host "SHA mismatches:" -ForegroundColor Red
            $MismatchedReferences | ForEach-Object { Write-Host $_ }
        }

        if ($UnexpectedReferences.Count -gt 0) {
            Write-Host "Unexpected destination references:" -ForegroundColor Red
            $UnexpectedReferences | ForEach-Object { Write-Host $_ }
        }

        throw "Source and destination Git references do not match."
    }

    Write-Host "`nAll Git references and commit SHAs match." -ForegroundColor Green

    # --------------------------------------------------------
    # FINAL RESULT
    # --------------------------------------------------------

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "       MIGRATION TEST SUCCESSFUL" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "Source:      $SourceAccountId/$SourceRepository"
    Write-Host "Destination: $DestinationAccountId/$DestinationRepository"
    Write-Host "Branches migrated: $($SourceBranches.Count)"
    Write-Host "Tags migrated: $($SourceTags.Count)"
    Write-Host "Reference validation: PASSED"

    Write-Host "`nMirror folder: $MirrorPath" -ForegroundColor Cyan

}
catch {

    Write-Host "`nMIGRATION TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red

    Write-Host "Review the error before attempting another run." -ForegroundColor Yellow

}
finally {

    # Clear plaintext token variables.
    $SourceTokenPlain = $null
    $DestinationTokenPlain = $null

    $SourceSecureToken = $null
    $DestinationSecureToken = $null

    # Restore previous Git prompt setting.
    $env:GIT_TERMINAL_PROMPT = $PreviousGitPromptSetting

    Write-Host "`nAuthentication variables cleared from the script." -ForegroundColor DarkGray
}
