#requires -Version 7.2

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src\AdoTestMigration.psm1'
Import-Module $modulePath -Force

function Read-RequiredValue {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    do {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host 'The value cannot be empty.' -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value.Trim()
}

function New-InteractiveContext {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Read', 'Write')]
        [string]$AccessLevel
    )

    Write-Host ''
    Write-Host 'Authentication' -ForegroundColor Cyan
    Write-Host '  1. Azure CLI (recommended)'
    Write-Host '  2. Personal Access Token (PAT)'

    do {
        $authenticationChoice = Read-Host 'Choose [1-2]'
    } while ($authenticationChoice -notin @('1', '2'))

    $organization = Read-RequiredValue 'Organization URL or name (e.g., https://dev.azure.com/contoso)'
    $project = Read-RequiredValue 'Project name or ID'
    $authenticationMethod = if ($authenticationChoice -eq '1') { 'AzureCli' } else { 'Pat' }

    $contextParameters = @{
        Organization         = $organization
        Project              = $project
        AuthenticationMethod = $authenticationMethod
    }

    if ($authenticationMethod -eq 'Pat') {
        Write-Host "The PAT requires Test Management $AccessLevel access." -ForegroundColor DarkGray
        Write-Host 'Area Path filtering also requires Work Items Read access.' -ForegroundColor DarkGray
        $contextParameters.Pat = Read-Host 'PAT (it will not be saved)' -AsSecureString
    }

    $context = New-AdoContext @contextParameters
    Test-AdoAccess -Context $context -AccessLevel $AccessLevel
    return $context
}

function Invoke-ExportMenu {
    $context = New-InteractiveContext -AccessLevel Read
    $defaultOutput = Join-Path $PSScriptRoot 'exports'
    $outputRoot = Read-Host "Export directory [$defaultOutput]"
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        $outputRoot = $defaultOutput
    }

    $fromDateText = Read-Host 'Export only runs updated since (YYYY-MM-DD, empty = all)'
    $fromDate = $null
    if (-not [string]::IsNullOrWhiteSpace($fromDateText)) {
        $parsedDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
                $fromDateText,
                'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [Globalization.DateTimeStyles]::AdjustToUniversal,
                [ref]$parsedDate
            )) {
            throw "Invalid date: '$fromDateText'. Use the YYYY-MM-DD format."
        }
        $fromDate = $parsedDate
    }

    $areaPath = Read-Host 'Area Path as shown in Azure DevOps (empty = all, child areas are included)'
    if ([string]::IsNullOrWhiteSpace($areaPath)) {
        $areaPath = $null
    }

    $exportPath = Export-AdoTestHistory `
        -Context $context `
        -OutputRoot $outputRoot `
        -MinLastUpdatedDate $fromDate `
        -AreaPath $areaPath
    Write-Host ''
    Write-Host "Export completed: $exportPath" -ForegroundColor Green
}

function Invoke-ImportMenu {
    Write-Host ''
    Write-Host 'Import recreates runs and results with new IDs.' -ForegroundColor Yellow
    Write-Host 'It does not preserve audit history or references without explicit mapping.' -ForegroundColor Yellow

    $context = New-InteractiveContext -AccessLevel Write
    $exportPath = Read-RequiredValue 'Export directory containing manifest.json'

    $confirmation = Read-Host "Type IMPORT to confirm data creation in '$($context.Project)'"
    if ($confirmation -cne 'IMPORT') {
        Write-Host 'Import canceled.' -ForegroundColor Yellow
        return
    }

    $mapPath = Import-AdoTestHistory -Context $context -ExportPath $exportPath
    Write-Host ''
    Write-Host "Import completed. ID map: $mapPath" -ForegroundColor Green
}

function Invoke-ValidationMenu {
    $accessChoice = Read-Host 'Validate read or write access? [R/W]'
    $accessLevel = if ($accessChoice -match '^(w|W)$') { 'Write' } else { 'Read' }
    $null = New-InteractiveContext -AccessLevel $accessLevel
    Write-Host 'Access validated successfully.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Azure DevOps Test History Migration' -ForegroundColor Cyan
Write-Host 'Exports and recreates Test Runs through the official REST APIs.' -ForegroundColor DarkGray

do {
    Write-Host ''
    Write-Host 'Main menu' -ForegroundColor Cyan
    Write-Host '  1. Export Test Run history'
    Write-Host '  2. Import exported history'
    Write-Host '  3. Validate access'
    Write-Host '  0. Exit'

    $choice = Read-Host 'Choose an option'

    try {
        switch ($choice) {
            '1' { Invoke-ExportMenu }
            '2' { Invoke-ImportMenu }
            '3' { Invoke-ValidationMenu }
            '0' { Write-Host 'Exiting.' }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
        }
    }
    catch {
        Write-Host ''
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Verbose $_.ScriptStackTrace
    }
} while ($choice -ne '0')
