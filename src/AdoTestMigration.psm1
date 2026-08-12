Set-StrictMode -Version Latest
$script:ApiVersion = '7.1'
$script:AzureDevOpsResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ">> $Message" -ForegroundColor Cyan
}

function ConvertFrom-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-NormalizedOrganizationUrl {
    param(
        [Parameter(Mandatory)]
        [string]$Organization
    )

    $value = $Organization.Trim().TrimEnd('/')
    if ($value -notmatch '^https://') {
        $value = "https://dev.azure.com/$value"
    }

    $uri = [uri]$value
    if ($uri.Host -notin @('dev.azure.com', 'visualstudio.com') -and
        -not $uri.Host.EndsWith('.visualstudio.com', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid Azure DevOps organization URL: '$Organization'."
    }

    return $value
}

function New-AdoContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateSet('AzureCli', 'Pat')]
        [string]$AuthenticationMethod,

        [securestring]$Pat
    )

    $organizationUrl = Get-NormalizedOrganizationUrl -Organization $Organization
    $headers = @{
        Accept = 'application/json'
    }

    if ($AuthenticationMethod -eq 'AzureCli') {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI was not found. Install Azure CLI or authenticate with a PAT.'
        }

        Write-Step 'Checking Azure CLI authentication'
        $account = az account show --only-show-errors 2>$null | ConvertFrom-Json
        if (-not $account) {
            Write-Host 'Starting Azure CLI login...' -ForegroundColor Yellow
            az login --only-show-errors | Out-Null
        }

        $token = az account get-access-token `
            --resource $script:AzureDevOpsResourceId `
            --query accessToken `
            --output tsv `
            --only-show-errors

        if ([string]::IsNullOrWhiteSpace($token)) {
            throw 'Azure CLI could not obtain an Azure DevOps access token.'
        }
        $headers.Authorization = "Bearer $token"
    }
    else {
        if (-not $Pat) {
            throw 'A PAT is required for PAT authentication.'
        }

        $plainPat = ConvertFrom-SecureStringToPlainText -SecureString $Pat
        $bytes = $null
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes(":$plainPat")
            $headers.Authorization = "Basic $([Convert]::ToBase64String($bytes))"
        }
        finally {
            $plainPat = $null
            if ($bytes) {
                [Array]::Clear($bytes, 0, $bytes.Length)
            }
        }
    }

    return [pscustomobject]@{
        OrganizationUrl      = $organizationUrl
        Project              = $Project.Trim()
        Headers              = $headers
        AuthenticationMethod = $AuthenticationMethod
    }
}

function Get-AdoErrorMessage {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if (-not $response) {
        return $ErrorRecord.Exception.Message
    }

    $statusCode = [int]$response.StatusCode
    return "Azure DevOps returned HTTP $statusCode. Check the organization, project, and permissions."
}

function Invoke-AdoRestMethod {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body
    )

    $uri = "$($Context.OrganizationUrl)/$Path"
    $parameters = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Context.Headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 100 -Compress
    }

    try {
        return Invoke-RestMethod @parameters
    }
    catch {
        throw (Get-AdoErrorMessage -ErrorRecord $_)
    }
}

function Save-AdoBinary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    try {
        Invoke-WebRequest `
            -Uri "$($Context.OrganizationUrl)/$Path" `
            -Headers $Context.Headers `
            -OutFile $Destination `
            -ErrorAction Stop | Out-Null
    }
    catch {
        throw (Get-AdoErrorMessage -ErrorRecord $_)
    }
}

function Test-AdoAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [ValidateSet('Read', 'Write')]
        [string]$AccessLevel
    )

    Write-Step "Validating access to project '$($Context.Project)'"
    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $null = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "_apis/projects/$encodedProject`?api-version=$($script:ApiVersion)"

    $null = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/test/runs?`$top=1&api-version=$($script:ApiVersion)"

    if ($AccessLevel -eq 'Write') {
        Write-Host 'Read access validated. Write access will be confirmed when the first run is created.' -ForegroundColor DarkGray
    }
    else {
        Write-Host 'Test Run read access validated.' -ForegroundColor DarkGray
    }
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Value |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $safeName = $Name
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        $safeName = $safeName.Replace($character, '_')
    }

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return 'attachment.bin'
    }
    return $safeName
}

function Get-CollectionValue {
    param(
        [Parameter(Mandatory)]
        [object]$Response
    )

    if ($Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }
    return @($Response)
}

function Get-AdoTestRuns {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [AllowNull()]
        [Nullable[datetime]]$MinLastUpdatedDate
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $allRuns = [Collections.Generic.List[object]]::new()
    $skip = 0
    $pageSize = 1000

    do {
        $path = "$encodedProject/_apis/test/runs?includeRunDetails=true&`$skip=$skip&`$top=$pageSize"
        if ($null -ne $MinLastUpdatedDate) {
            $dateValue = [uri]::EscapeDataString($MinLastUpdatedDate.ToUniversalTime().ToString('o'))
            $path += "&minLastUpdatedDate=$dateValue"
        }
        $path += "&api-version=$($script:ApiVersion)"

        $response = Invoke-AdoRestMethod -Context $Context -Method GET -Path $path
        $page = @(Get-CollectionValue -Response $response)
        foreach ($run in $page) {
            $allRuns.Add($run)
        }
        $skip += $page.Count
    } while ($page.Count -eq $pageSize)

    return $allRuns.ToArray()
}

function Get-AdoTestResults {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$RunId
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $allResults = [Collections.Generic.List[object]]::new()
    $skip = 0
    $pageSize = 200

    do {
        $path = "$encodedProject/_apis/test/Runs/$RunId/results" +
            "?detailsToInclude=WorkItems,Iterations&`$skip=$skip&`$top=$pageSize" +
            "&api-version=$($script:ApiVersion)"
        $response = Invoke-AdoRestMethod -Context $Context -Method GET -Path $path
        $page = @(Get-CollectionValue -Response $response)
        foreach ($result in $page) {
            $allResults.Add($result)
        }
        $skip += $page.Count
    } while ($page.Count -eq $pageSize)

    return $allResults.ToArray()
}

function Get-NormalizedAreaPath {
    param(
        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$AreaPath
    )

    $normalized = $AreaPath.Trim().Trim('\').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Area Path cannot be empty.'
    }

    if ($normalized.Equals($Project, [StringComparison]::OrdinalIgnoreCase)) {
        return $Project
    }

    if ($normalized.StartsWith("$Project\", [StringComparison]::OrdinalIgnoreCase)) {
        return $normalized
    }

    return "$Project\$normalized"
}

function Get-AdoTestCaseIdsByAreaPath {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$AreaPath
    )

    $normalizedAreaPath = Get-NormalizedAreaPath -Project $Context.Project -AreaPath $AreaPath
    $escapedAreaPath = $normalizedAreaPath.Replace("'", "''")
    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $query = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.WorkItemType] = 'Test Case'
  AND [System.AreaPath] UNDER '$escapedAreaPath'
"@

    Write-Step "Resolving Test Cases under Area Path '$normalizedAreaPath'"
    $response = Invoke-AdoRestMethod `
        -Context $Context `
        -Method POST `
        -Path "$encodedProject/_apis/wit/wiql?api-version=$($script:ApiVersion)" `
        -Body @{ query = $query }

    $testCaseIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($workItem in @($response.workItems)) {
        $null = $testCaseIds.Add([int]$workItem.id)
    }

    return [pscustomobject]@{
        AreaPath    = $normalizedAreaPath
        TestCaseIds = $testCaseIds
    }
}

function Select-AdoResultsByTestCaseIds {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[int]]$TestCaseIds
    )

    return @($Results | Where-Object {
            $testCase = Get-PropertyValue -Source $_ -Name 'testCase'
            if (-not $testCase) {
                return $false
            }

            $testCaseId = Get-PropertyValue -Source $testCase -Name 'id'
            if ($null -eq $testCaseId) {
                return $false
            }

            $parsedId = 0
            [int]::TryParse([string]$testCaseId, [ref]$parsedId) -and
                $TestCaseIds.Contains($parsedId)
        })
}

function Export-AdoAttachments {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$RunId,

        [Parameter(Mandatory)]
        [string]$RunPath,

        [object[]]$Results
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $runAttachmentPath = Join-Path $RunPath 'attachments\run'
    $runAttachmentResponse = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/test/runs/$RunId/attachments?api-version=$($script:ApiVersion)"
    $runAttachments = @(Get-CollectionValue -Response $runAttachmentResponse)

    if ($runAttachments.Count -gt 0) {
        New-Item -ItemType Directory -Path $runAttachmentPath -Force | Out-Null
        Save-JsonFile -Value $runAttachments -Path (Join-Path $runAttachmentPath 'metadata.json')
        foreach ($attachment in $runAttachments) {
            $fileName = "$(('{0:D8}' -f [int]$attachment.id))_$(Get-SafeFileName -Name $attachment.fileName)"
            Save-AdoBinary `
                -Context $Context `
                -Path "$encodedProject/_apis/test/runs/$RunId/attachments/$($attachment.id)?api-version=$($script:ApiVersion)" `
                -Destination (Join-Path $runAttachmentPath $fileName)
        }
    }

    foreach ($result in $Results) {
        $resultAttachmentResponse = Invoke-AdoRestMethod `
            -Context $Context `
            -Method GET `
            -Path "$encodedProject/_apis/test/Runs/$RunId/Results/$($result.id)/attachments?api-version=$($script:ApiVersion)"
        $resultAttachments = @(Get-CollectionValue -Response $resultAttachmentResponse)

        if ($resultAttachments.Count -eq 0) {
            continue
        }

        $resultAttachmentPath = Join-Path $RunPath "attachments\results\$($result.id)"
        New-Item -ItemType Directory -Path $resultAttachmentPath -Force | Out-Null
        Save-JsonFile -Value $resultAttachments -Path (Join-Path $resultAttachmentPath 'metadata.json')

        foreach ($attachment in $resultAttachments) {
            $fileName = "$(('{0:D8}' -f [int]$attachment.id))_$(Get-SafeFileName -Name $attachment.fileName)"
            Save-AdoBinary `
                -Context $Context `
                -Path "$encodedProject/_apis/test/Runs/$RunId/Results/$($result.id)/attachments/$($attachment.id)?api-version=$($script:ApiVersion)" `
                -Destination (Join-Path $resultAttachmentPath $fileName)
        }
    }
}

function Export-AdoTestHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [AllowNull()]
        [Nullable[datetime]]$MinLastUpdatedDate,

        [AllowNull()]
        [string]$AreaPath
    )

    Write-Step 'Querying Test Runs'
    $runs = @(Get-AdoTestRuns -Context $Context -MinLastUpdatedDate $MinLastUpdatedDate)
    Write-Host "$($runs.Count) run(s) found." -ForegroundColor DarkGray

    $areaFilter = $null
    if (-not [string]::IsNullOrWhiteSpace($AreaPath)) {
        $areaFilter = Get-AdoTestCaseIdsByAreaPath -Context $Context -AreaPath $AreaPath
        Write-Host "$($areaFilter.TestCaseIds.Count) Test Case(s) found in the selected Area Path." -ForegroundColor DarkGray
        Write-Host 'Results without an associated Test Case are excluded when this filter is active.' -ForegroundColor DarkGray
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeProject = Get-SafeFileName -Name $Context.Project
    $exportPath = Join-Path $OutputRoot "$safeProject-$timestamp"
    $runsPath = Join-Path $exportPath 'runs'
    New-Item -ItemType Directory -Path $runsPath -Force | Out-Null

    $manifestRuns = [Collections.Generic.List[object]]::new()
    $skippedRunCount = 0
    $skippedResultCount = 0
    $current = 0
    foreach ($runSummary in $runs) {
        $current++
        Write-Step "Inspecting run $current/$($runs.Count): ID $($runSummary.id) - $($runSummary.name)"
        $encodedProject = [uri]::EscapeDataString($Context.Project)
        $run = Invoke-AdoRestMethod `
            -Context $Context `
            -Method GET `
            -Path "$encodedProject/_apis/test/runs/$($runSummary.id)?includeDetails=true&api-version=$($script:ApiVersion)"
        $allResults = @(Get-AdoTestResults -Context $Context -RunId $runSummary.id)
        $results = $allResults

        if ($areaFilter) {
            $results = @(Select-AdoResultsByTestCaseIds `
                    -Results $allResults `
                    -TestCaseIds $areaFilter.TestCaseIds)
            $skippedResultCount += $allResults.Count - $results.Count

            if ($results.Count -eq 0) {
                $skippedRunCount++
                Write-Host '   Skipped: no results match the selected Area Path.' -ForegroundColor DarkGray
                continue
            }
        }

        Write-Host "   Exporting $($results.Count) result(s)." -ForegroundColor DarkGray
        $runPath = Join-Path $runsPath ([string]$runSummary.id)
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
        Save-JsonFile -Value $run -Path (Join-Path $runPath 'run.json')
        Save-JsonFile -Value ([pscustomobject]@{
                count = $results.Count
                value = $results
            }) -Path (Join-Path $runPath 'results.json')

        Export-AdoAttachments `
            -Context $Context `
            -RunId $runSummary.id `
            -RunPath $runPath `
            -Results $results

        $manifestRuns.Add([pscustomobject]@{
                sourceRunId = $runSummary.id
                name        = $runSummary.name
                path        = "runs/$($runSummary.id)"
                resultCount = $results.Count
                sourceResultCount = $allResults.Count
            })
    }

    $manifest = [ordered]@{
        schemaVersion      = 1
        exportedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        sourceOrganization = $Context.OrganizationUrl
        sourceProject      = $Context.Project
        apiVersion         = $script:ApiVersion
        minLastUpdatedDate = if ($null -ne $MinLastUpdatedDate) {
            $MinLastUpdatedDate.ToUniversalTime().ToString('o')
        } else {
            $null
        }
        areaPath            = if ($areaFilter) { $areaFilter.AreaPath } else { $null }
        skippedRunCount     = $skippedRunCount
        skippedResultCount  = $skippedResultCount
        runCount           = $manifestRuns.Count
        runs               = $manifestRuns.ToArray()
    }
    Save-JsonFile -Value $manifest -Path (Join-Path $exportPath 'manifest.json')

    return $exportPath
}

function Add-PropertyIfPresent {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Target,

        [Parameter(Mandatory)]
        [object]$Source,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [string]$TargetName = $SourceName
    )

    $property = $Source.PSObject.Properties[$SourceName]
    if ($property -and $null -ne $property.Value -and $property.Value -ne '') {
        $Target[$TargetName] = $property.Value
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$Source,

        [Parameter(Mandatory)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    $property = $Source.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        return $property.Value
    }
    return $DefaultValue
}

function New-RunCreatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Run
    )

    $payload = @{
        name      = $Run.name
        state     = 'InProgress'
        comment   = "Recreated from Azure DevOps Test Run ID $($Run.id)."
        automated = [bool](Get-PropertyValue -Source $Run -Name 'isAutomated' -DefaultValue $false)
    }
    Add-PropertyIfPresent -Target $payload -Source $Run -SourceName 'startDate'
    return $payload
}

function New-ResultCreatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $sourceComment = Get-PropertyValue -Source $Result -Name 'comment'
    $payload = @{
        state   = 'Completed'
        outcome = $Result.outcome
        comment = if ($sourceComment) {
            "$sourceComment`nSource result ID: $($Result.id)"
        } else {
            "Source result ID: $($Result.id)"
        }
    }

    foreach ($propertyName in @(
            'testCaseTitle',
            'automatedTestName',
            'automatedTestStorage',
            'automatedTestType',
            'automatedTestTypeId',
            'computerName',
            'durationInMs',
            'errorMessage',
            'stackTrace',
            'startedDate',
            'completedDate',
            'failureType',
            'resolutionState'
        )) {
        Add-PropertyIfPresent -Target $payload -Source $Result -SourceName $propertyName
    }

    return $payload
}

function Add-AdoAttachment {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [object]$Metadata
    )

    $metadataComment = Get-PropertyValue -Source $Metadata -Name 'comment'
    $metadataType = Get-PropertyValue -Source $Metadata -Name 'attachmentType'
    $payload = @{
        stream         = [Convert]::ToBase64String([IO.File]::ReadAllBytes($FilePath))
        fileName       = $Metadata.fileName
        comment        = if ($metadataComment) { $metadataComment } else { 'Migrated attachment' }
        attachmentType = if ($metadataType) {
            $metadataType
        } else {
            'GeneralAttachment'
        }
    }
    $null = Invoke-AdoRestMethod -Context $Context -Method POST -Path $Path -Body $payload
}

function Import-AttachmentDirectory {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$ApiPath
    )

    $metadataPath = Join-Path $Directory 'metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return
    }

    $metadataItems = @(Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json)
    foreach ($metadata in $metadataItems) {
        $prefix = '{0:D8}_' -f [int]$metadata.id
        $file = Get-ChildItem -LiteralPath $Directory -File |
            Where-Object Name -Like "$prefix*" |
            Select-Object -First 1
        if (-not $file) {
            Write-Warning "Attachment file $($metadata.id) was not found in '$Directory'."
            continue
        }

        Add-AdoAttachment `
            -Context $Context `
            -Path $ApiPath `
            -FilePath $file.FullName `
            -Metadata $metadata
    }
}

function Import-AdoTestHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    $resolvedExportPath = (Resolve-Path -LiteralPath $ExportPath).Path
    $manifestPath = Join-Path $resolvedExportPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "manifest.json was not found in '$resolvedExportPath'."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) {
        throw "Unsupported export version: $($manifest.schemaVersion)."
    }

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $migrationMap = [ordered]@{
        importedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        sourceOrganization = $manifest.sourceOrganization
        sourceProject      = $manifest.sourceProject
        targetOrganization = $Context.OrganizationUrl
        targetProject      = $Context.Project
        runs               = [Collections.Generic.List[object]]::new()
    }

    $current = 0
    foreach ($manifestRun in $manifest.runs) {
        $current++
        Write-Step "Importing run $current/$($manifest.runCount): ID $($manifestRun.sourceRunId) - $($manifestRun.name)"

        $runPath = Join-Path $resolvedExportPath ($manifestRun.path -replace '/', [IO.Path]::DirectorySeparatorChar)
        $sourceRun = Get-Content -LiteralPath (Join-Path $runPath 'run.json') -Raw | ConvertFrom-Json
        $resultDocument = Get-Content -LiteralPath (Join-Path $runPath 'results.json') -Raw | ConvertFrom-Json
        $sourceResults = @($resultDocument.value)

        $newRun = Invoke-AdoRestMethod `
            -Context $Context `
            -Method POST `
            -Path "$encodedProject/_apis/test/runs?api-version=$($script:ApiVersion)" `
            -Body (New-RunCreatePayload -Run $sourceRun)

        $resultMap = [Collections.Generic.List[object]]::new()
        for ($offset = 0; $offset -lt $sourceResults.Count; $offset += 200) {
            $lastIndex = [Math]::Min($offset + 199, $sourceResults.Count - 1)
            $sourceBatch = @($sourceResults[$offset..$lastIndex])
            $payloadBatch = @($sourceBatch | ForEach-Object { New-ResultCreatePayload -Result $_ })
            $createdResponse = Invoke-AdoRestMethod `
                -Context $Context `
                -Method POST `
                -Path "$encodedProject/_apis/test/Runs/$($newRun.id)/results?api-version=$($script:ApiVersion)" `
                -Body $payloadBatch
            $createdResults = @(Get-CollectionValue -Response $createdResponse)

            if ($createdResults.Count -ne $sourceBatch.Count) {
                throw "Azure DevOps created $($createdResults.Count) results for a batch of $($sourceBatch.Count)."
            }

            for ($index = 0; $index -lt $sourceBatch.Count; $index++) {
                $resultMap.Add([pscustomobject]@{
                        sourceResultId = $sourceBatch[$index].id
                        targetResultId = $createdResults[$index].id
                    })
            }
        }

        $runAttachmentDirectory = Join-Path $runPath 'attachments\run'
        if (Test-Path -LiteralPath $runAttachmentDirectory -PathType Container) {
            Import-AttachmentDirectory `
                -Context $Context `
                -Directory $runAttachmentDirectory `
                -ApiPath "$encodedProject/_apis/test/runs/$($newRun.id)/attachments?api-version=$($script:ApiVersion)"
        }

        foreach ($mappedResult in $resultMap) {
            $resultAttachmentDirectory = Join-Path $runPath "attachments\results\$($mappedResult.sourceResultId)"
            if (-not (Test-Path -LiteralPath $resultAttachmentDirectory -PathType Container)) {
                continue
            }

            Import-AttachmentDirectory `
                -Context $Context `
                -Directory $resultAttachmentDirectory `
                -ApiPath "$encodedProject/_apis/test/Runs/$($newRun.id)/Results/$($mappedResult.targetResultId)/attachments?api-version=$($script:ApiVersion)"
        }

        $sourceCompleteDate = Get-PropertyValue -Source $sourceRun -Name 'completeDate'
        $completePayload = @{
            state        = 'Completed'
            completeDate = if ($sourceCompleteDate) {
                $sourceCompleteDate
            } else {
                (Get-Date).ToUniversalTime().ToString('o')
            }
        }
        $null = Invoke-AdoRestMethod `
            -Context $Context `
            -Method PATCH `
            -Path "$encodedProject/_apis/test/runs/$($newRun.id)?api-version=$($script:ApiVersion)" `
            -Body $completePayload

        $migrationMap.runs.Add([pscustomobject]@{
                sourceRunId = $sourceRun.id
                targetRunId = $newRun.id
                results     = $resultMap.ToArray()
            })
    }

    $mapPath = Join-Path $resolvedExportPath "migration-map-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    Save-JsonFile -Value $migrationMap -Path $mapPath
    return $mapPath
}

Export-ModuleMember -Function @(
    'New-AdoContext',
    'Test-AdoAccess',
    'Export-AdoTestHistory',
    'Import-AdoTestHistory'
)
