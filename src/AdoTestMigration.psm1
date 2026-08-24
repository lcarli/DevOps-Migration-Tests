Set-StrictMode -Version Latest
$script:ApiVersion = '7.1'
$script:AzureDevOpsResourceId = '499b84ac-1321-427f-aa17-267ca6975798'
$script:LogPath = $null

function Initialize-AdoLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parentPath = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    $script:LogPath = [IO.Path]::GetFullPath($Path)
    Set-Content `
        -LiteralPath $script:LogPath `
        -Encoding utf8NoBOM `
        -Value "$(Get-Date -Format 'o') [INFO] Logging initialized."
}

function Write-AdoLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Context
    )

    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        return
    }

    $contextText = ''
    if ($Context -and $Context.Count -gt 0) {
        $contextText = ' ' + (ConvertTo-Json -InputObject $Context -Depth 20 -Compress)
    }

    Add-Content `
        -LiteralPath $script:LogPath `
        -Encoding utf8NoBOM `
        -Value "$(Get-Date -Format 'o') [$($Level.ToUpperInvariant())] $Message$contextText"
}

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-AdoLog -Level Info -Message $Message
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
    $serviceMessage = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $errorBody = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
            if ($errorBody.message) {
                $serviceMessage = [string]$errorBody.message
            }
        }
        catch {
            $serviceMessage = $ErrorRecord.ErrorDetails.Message.Trim()
        }
    }

    $message = "Azure DevOps returned HTTP $statusCode."
    if (-not [string]::IsNullOrWhiteSpace($serviceMessage)) {
        $message += " $serviceMessage"
    }
    return $message
}

function New-AdoRestException {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri
    )

    $message = Get-AdoErrorMessage -ErrorRecord $ErrorRecord
    $exception = [InvalidOperationException]::new($message, $ErrorRecord.Exception)
    $exception.Data['Method'] = $Method
    $exception.Data['Uri'] = $Uri

    if ($ErrorRecord.Exception.Response) {
        $exception.Data['StatusCode'] = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    return $exception
}

function Test-AdoHttpStatus {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [int]$StatusCode
    )

    return $ErrorRecord.Exception.Data.Contains('StatusCode') -and
        [int]$ErrorRecord.Exception.Data['StatusCode'] -eq $StatusCode
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
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Write-AdoLog `
        -Level Debug `
        -Message 'Azure DevOps REST request started.' `
        -Context @{ method = $Method; uri = $uri }

    try {
        $response = Invoke-RestMethod @parameters
        $stopwatch.Stop()
        Write-AdoLog `
            -Level Debug `
            -Message 'Azure DevOps REST request completed.' `
            -Context @{
                method     = $Method
                uri        = $uri
                durationMs = $stopwatch.ElapsedMilliseconds
            }
        return $response
    }
    catch {
        $stopwatch.Stop()
        $exception = New-AdoRestException -ErrorRecord $_ -Method $Method -Uri $uri
        Write-AdoLog `
            -Level Error `
            -Message 'Azure DevOps REST request failed.' `
            -Context @{
                method     = $Method
                uri        = $uri
                statusCode = $exception.Data['StatusCode']
                durationMs = $stopwatch.ElapsedMilliseconds
                error      = $exception.Message
            }
        throw $exception
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
        Write-AdoLog `
            -Level Debug `
            -Message 'Attachment download started.' `
            -Context @{ uri = "$($Context.OrganizationUrl)/$Path"; destination = $Destination }
        Invoke-WebRequest `
            -Uri "$($Context.OrganizationUrl)/$Path" `
            -Headers $Context.Headers `
            -OutFile $Destination `
            -ErrorAction Stop | Out-Null
        Write-AdoLog `
            -Level Debug `
            -Message 'Attachment download completed.' `
            -Context @{ destination = $Destination }
    }
    catch {
        $exception = New-AdoRestException `
            -ErrorRecord $_ `
            -Method GET `
            -Uri "$($Context.OrganizationUrl)/$Path"
        Write-AdoLog `
            -Level Error `
            -Message 'Attachment download failed.' `
            -Context @{ destination = $Destination; error = $exception.Message }
        throw $exception
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

function Save-AdoRunReport {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries,

        [Parameter(Mandatory)]
        [hashtable]$Summary,

        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    Save-JsonFile `
        -Value ([ordered]@{
                generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                summary        = $Summary
                runs           = $Entries
            }) `
        -Path $JsonPath

    $columns = @(
        'operation',
        'status',
        'sourceRunId',
        'targetRunId',
        'name',
        'sourceResultCount',
        'processedResultCount',
        'unlinkedResultCount',
        'outsideAreaResultCount',
        'reason'
    )
    if ($Entries.Count -gt 0) {
        $Entries |
            Select-Object -Property $columns |
            Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8
    }
    else {
        Set-Content `
            -LiteralPath $CsvPath `
            -Encoding utf8NoBOM `
            -Value ($columns -join ',')
    }
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

function Select-AdoRunsByLastUpdatedDate {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Runs,

        [AllowNull()]
        [Nullable[datetime]]$MinLastUpdatedDate
    )

    if ($null -eq $MinLastUpdatedDate) {
        return $Runs
    }

    $minimumDate = [DateTimeOffset]$MinLastUpdatedDate.ToUniversalTime()
    return @($Runs | Where-Object {
            $lastUpdatedDate = Get-PropertyValue -Source $_ -Name 'lastUpdatedDate'
            if ([string]::IsNullOrWhiteSpace([string]$lastUpdatedDate)) {
                return $false
            }

            $parsedDate = [DateTimeOffset]::MinValue
            [DateTimeOffset]::TryParse(
                [string]$lastUpdatedDate,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$parsedDate
            ) -and $parsedDate.ToUniversalTime() -ge $minimumDate
        })
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
        $path += "&api-version=$($script:ApiVersion)"

        $response = Invoke-AdoRestMethod -Context $Context -Method GET -Path $path
        $page = @(Get-CollectionValue -Response $response)
        foreach ($run in $page) {
            if ([string]$run.state -ne '255') {
                $allRuns.Add($run)
            }
        }
        $skip += $page.Count
    } while ($page.Count -eq $pageSize)

    if ($null -eq $MinLastUpdatedDate) {
        return $allRuns.ToArray()
    }

    $detailedRuns = [Collections.Generic.List[object]]::new()
    foreach ($run in $allRuns) {
        $details = Invoke-AdoRestMethod `
            -Context $Context `
            -Method GET `
            -Path "$encodedProject/_apis/test/runs/$($run.id)?includeDetails=true&api-version=$($script:ApiVersion)"
        $detailedRuns.Add($details)
    }

    return @(Select-AdoRunsByLastUpdatedDate `
            -Runs $detailedRuns.ToArray() `
            -MinLastUpdatedDate $MinLastUpdatedDate)
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

function Get-NormalizedAreaPathValue {
    param(
        [Parameter(Mandatory)]
        [string]$AreaPath
    )

    $normalized = $AreaPath.Trim().Trim('\').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Area Path cannot be empty.'
    }

    return $normalized
}

function Get-AdoAreaPaths {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $root = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/wit/classificationnodes/Areas?`$depth=100&api-version=$($script:ApiVersion)"

    $areaPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $nodes = [Collections.Generic.Stack[object]]::new()
    $nodes.Push([pscustomobject]@{
            Node     = $root
            AreaPath = [string]$root.name
        })

    while ($nodes.Count -gt 0) {
        $entry = $nodes.Pop()
        $node = $entry.Node
        $null = $areaPaths.Add($entry.AreaPath)

        $children = Get-PropertyValue -Source $node -Name 'children' -DefaultValue @()
        foreach ($child in @($children)) {
            $nodes.Push([pscustomobject]@{
                    Node     = $child
                    AreaPath = "$($entry.AreaPath)\$($child.name)"
                })
        }
    }

    return ,$areaPaths
}

function Resolve-AdoAreaPath {
    param(
        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$AreaPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[string]]$AvailableAreaPaths
    )

    $requestedPath = Get-NormalizedAreaPathValue -AreaPath $AreaPath
    if ($AvailableAreaPaths.Contains($requestedPath)) {
        return $requestedPath
    }

    $projectRelativePath = "$Project\$requestedPath"
    if ($AvailableAreaPaths.Contains($projectRelativePath)) {
        return $projectRelativePath
    }

    $suffix = "\$requestedPath"
    $suffixMatches = @($AvailableAreaPaths | Where-Object {
            $_.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($suffixMatches.Count -eq 1) {
        return $suffixMatches[0]
    }
    if ($suffixMatches.Count -gt 1) {
        throw "Area Path '$AreaPath' is ambiguous. Enter its complete path as shown in Azure DevOps."
    }

    $availableExamples = @($AvailableAreaPaths | Sort-Object | Select-Object -First 5)
    $exampleText = if ($availableExamples.Count -gt 0) {
        " Available paths include: $($availableExamples -join '; ')."
    } else {
        ''
    }
    throw "Area Path '$AreaPath' was not found in project '$Project'.$exampleText"
}

function Get-AdoTestCaseIdsByAreaPath {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$AreaPath
    )

    Write-Step "Resolving Area Path '$AreaPath'"
    $availableAreaPaths = Get-AdoAreaPaths -Context $Context
    $resolvedAreaPath = Resolve-AdoAreaPath `
        -Project $Context.Project `
        -AreaPath $AreaPath `
        -AvailableAreaPaths $availableAreaPaths
    $escapedAreaPath = $resolvedAreaPath.Replace("'", "''")
    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $query = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.WorkItemType] = 'Test Case'
  AND [System.AreaPath] UNDER '$escapedAreaPath'
"@

    Write-Step "Resolving Test Cases under Area Path '$resolvedAreaPath'"
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
        AreaPath    = $resolvedAreaPath
        TestCaseIds = $testCaseIds
    }
}

function Get-AdoAreaPathResultSelection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.HashSet[int]]$TestCaseIds
    )

    $matched = [Collections.Generic.List[object]]::new()
    $unlinked = [Collections.Generic.List[object]]::new()
    $outsideArea = [Collections.Generic.List[object]]::new()

    foreach ($result in $Results) {
        $testCase = Get-PropertyValue -Source $result -Name 'testCase'
        $testCaseId = if ($testCase) {
            Get-PropertyValue -Source $testCase -Name 'id'
        } else {
            $null
        }

        $parsedId = 0
        if ($null -eq $testCaseId -or
            -not [int]::TryParse([string]$testCaseId, [ref]$parsedId)) {
            $unlinked.Add($result)
        }
        elseif ($TestCaseIds.Contains($parsedId)) {
            $matched.Add($result)
        }
        else {
            $outsideArea.Add($result)
        }
    }

    return [pscustomobject]@{
        Matched     = $matched.ToArray()
        Unlinked    = $unlinked.ToArray()
        OutsideArea = $outsideArea.ToArray()
    }
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
    Write-AdoLog `
        -Level Info `
        -Message 'Export parameters resolved.' `
        -Context @{
            organization       = $Context.OrganizationUrl
            project            = $Context.Project
            outputRoot         = $OutputRoot
            minLastUpdatedDate = if ($null -ne $MinLastUpdatedDate) {
                $MinLastUpdatedDate.ToUniversalTime().ToString('o')
            } else {
                $null
            }
            requestedAreaPath  = $AreaPath
        }
    $runs = @(Get-AdoTestRuns -Context $Context -MinLastUpdatedDate $MinLastUpdatedDate)
    Write-Host "$($runs.Count) run(s) found." -ForegroundColor DarkGray
    Write-AdoLog -Level Info -Message 'Candidate Test Runs loaded.' -Context @{ count = $runs.Count }
    if ($runs.Count -eq 0 -and $null -ne $MinLastUpdatedDate) {
        Write-Warning "No Test Runs matched the date filter starting at $($MinLastUpdatedDate.ToString('yyyy-MM-dd'))."
    }

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
    $unavailableRuns = [Collections.Generic.List[object]]::new()
    $reportEntries = [Collections.Generic.List[object]]::new()
    $skippedRunCount = 0
    $skippedResultCount = 0
    $unlinkedRunCount = 0
    $outsideAreaRunCount = 0
    $current = 0
    foreach ($runSummary in $runs) {
        $current++
        Write-Step "Inspecting run $current/$($runs.Count): ID $($runSummary.id) - $($runSummary.name)"
        $encodedProject = [uri]::EscapeDataString($Context.Project)
        $runPath = Join-Path $runsPath ([string]$runSummary.id)

        try {
            Write-AdoLog `
                -Level Debug `
                -Message 'Run processing started.' `
                -Context @{
                    index   = $current
                    total   = $runs.Count
                    runId   = $runSummary.id
                    runName = $runSummary.name
                    phase   = 'details'
                }
            $run = if (Get-PropertyValue -Source $runSummary -Name 'lastUpdatedDate') {
                $runSummary
            } else {
                Invoke-AdoRestMethod `
                    -Context $Context `
                    -Method GET `
                    -Path "$encodedProject/_apis/test/runs/$($runSummary.id)?includeDetails=true&api-version=$($script:ApiVersion)"
            }

            Write-AdoLog `
                -Level Debug `
                -Message 'Loading run results.' `
                -Context @{ runId = $runSummary.id; phase = 'results' }
            $allResults = @(Get-AdoTestResults -Context $Context -RunId $runSummary.id)
            $results = $allResults

            if ($areaFilter) {
                Write-AdoLog `
                    -Level Debug `
                    -Message 'Applying Area Path result filter.' `
                    -Context @{
                        runId             = $runSummary.id
                        sourceResultCount = $allResults.Count
                        areaPath          = $areaFilter.AreaPath
                        phase             = 'area-filter'
                    }
                $selection = Get-AdoAreaPathResultSelection `
                        -Results $allResults `
                        -TestCaseIds $areaFilter.TestCaseIds
                $results = @($selection.Matched)
                $unlinkedResultCount = @($selection.Unlinked).Count
                $outsideAreaResultCount = @($selection.OutsideArea).Count
                $skippedResultCount += $allResults.Count - $results.Count

                if ($results.Count -eq 0) {
                    $skippedRunCount++
                    $status = if ($unlinkedResultCount -eq $allResults.Count) {
                        $unlinkedRunCount++
                        'SkippedNoTestCaseLink'
                    }
                    elseif ($outsideAreaResultCount -eq $allResults.Count) {
                        $outsideAreaRunCount++
                        'SkippedOutsideAreaPath'
                    }
                    else {
                        'SkippedAreaPath'
                    }
                    $reason = "No results matched Area Path '$($areaFilter.AreaPath)'. " +
                        "Total: $($allResults.Count); without Test Case link: $unlinkedResultCount; " +
                        "linked to Test Cases outside the area: $outsideAreaResultCount."
                    $reportEntries.Add([pscustomobject]@{
                            operation            = 'Export'
                            status               = $status
                            sourceRunId          = $runSummary.id
                            targetRunId          = $null
                            name                 = $runSummary.name
                            sourceResultCount    = $allResults.Count
                            processedResultCount = 0
                            unlinkedResultCount   = $unlinkedResultCount
                            outsideAreaResultCount = $outsideAreaResultCount
                            reason               = $reason
                        })
                    Write-AdoLog `
                        -Level Info `
                        -Message 'Run skipped by Area Path classification.' `
                        -Context @{
                            runId                  = $runSummary.id
                            status                 = $status
                            sourceResultCount      = $allResults.Count
                            unlinkedResultCount    = $unlinkedResultCount
                            outsideAreaResultCount = $outsideAreaResultCount
                        }
                    if ($status -eq 'SkippedNoTestCaseLink') {
                        Write-Host "   Skipped: all $unlinkedResultCount result(s) have no Test Case link, so their Area Path cannot be determined." -ForegroundColor Yellow
                    }
                    elseif ($status -eq 'SkippedOutsideAreaPath') {
                        Write-Host "   Skipped: all $outsideAreaResultCount result(s) are linked to Test Cases outside '$($areaFilter.AreaPath)'." -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host "   Skipped: no results matched '$($areaFilter.AreaPath)' ($unlinkedResultCount unlinked, $outsideAreaResultCount outside the area)." -ForegroundColor DarkGray
                    }
                    continue
                }

                if ($unlinkedResultCount -gt 0 -or $outsideAreaResultCount -gt 0) {
                    Write-Host "   Area filter excluded $($unlinkedResultCount + $outsideAreaResultCount) result(s): $unlinkedResultCount without Test Case link, $outsideAreaResultCount outside the area." -ForegroundColor DarkGray
                }
            }
            else {
                $unlinkedResultCount = 0
                $outsideAreaResultCount = 0
            }

            Write-Host "   Exporting $($results.Count) result(s)." -ForegroundColor DarkGray
            Write-AdoLog `
                -Level Debug `
                -Message 'Writing run data.' `
                -Context @{ runId = $runSummary.id; resultCount = $results.Count; phase = 'files' }
            New-Item -ItemType Directory -Path $runPath -Force | Out-Null
            Save-JsonFile -Value $run -Path (Join-Path $runPath 'run.json')
            Save-JsonFile -Value ([pscustomobject]@{
                    count = $results.Count
                    value = $results
                }) -Path (Join-Path $runPath 'results.json')

            Write-AdoLog `
                -Level Debug `
                -Message 'Exporting run attachments.' `
                -Context @{ runId = $runSummary.id; phase = 'attachments' }
            Export-AdoAttachments `
                -Context $Context `
                -RunId $runSummary.id `
                -RunPath $runPath `
                -Results $results

            $manifestRuns.Add([pscustomobject]@{
                    sourceRunId      = $runSummary.id
                    name             = $runSummary.name
                    path             = "runs/$($runSummary.id)"
                    resultCount      = $results.Count
                    sourceResultCount = $allResults.Count
                })
            $reportEntries.Add([pscustomobject]@{
                    operation            = 'Export'
                    status               = 'Exported'
                    sourceRunId          = $runSummary.id
                    targetRunId          = $null
                    name                 = $runSummary.name
                    sourceResultCount    = $allResults.Count
                    processedResultCount = $results.Count
                    unlinkedResultCount   = $unlinkedResultCount
                    outsideAreaResultCount = $outsideAreaResultCount
                    reason               = if ($unlinkedResultCount -gt 0 -or $outsideAreaResultCount -gt 0) {
                        "Exported matching results only. Excluded $unlinkedResultCount without Test Case link and $outsideAreaResultCount outside the selected Area Path."
                    } else {
                        $null
                    }
                })
            Write-AdoLog `
                -Level Info `
                -Message 'Run exported successfully.' `
                -Context @{ runId = $runSummary.id; resultCount = $results.Count }
        }
        catch {
            if (Test-AdoHttpStatus -ErrorRecord $_ -StatusCode 404) {
                if (Test-Path -LiteralPath $runPath -PathType Container) {
                    Remove-Item -LiteralPath $runPath -Recurse -Force
                }

                $unavailableRuns.Add([pscustomobject]@{
                        sourceRunId = $runSummary.id
                        name        = $runSummary.name
                        reason      = $_.Exception.Message
                    })
                $reportEntries.Add([pscustomobject]@{
                        operation            = 'Export'
                        status               = 'Unavailable'
                        sourceRunId          = $runSummary.id
                        targetRunId          = $null
                        name                 = $runSummary.name
                        sourceResultCount    = $null
                        processedResultCount = 0
                        unlinkedResultCount   = $null
                        outsideAreaResultCount = $null
                        reason               = $_.Exception.Message
                    })
                Write-AdoLog `
                    -Level Warning `
                    -Message 'Run became unavailable and was skipped.' `
                    -Context @{
                        runId   = $runSummary.id
                        runName = $runSummary.name
                        error   = $_.Exception.Message
                    }
                Write-Warning "Run ID $($runSummary.id) is no longer available and was skipped."
                continue
            }

            Write-AdoLog `
                -Level Error `
                -Message 'Run processing failed and export was stopped.' `
                -Context @{
                    runId      = $runSummary.id
                    runName    = $runSummary.name
                    error      = $_.Exception.Message
                    stackTrace = $_.ScriptStackTrace
                }
            throw
        }
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
        unavailableRunCount = $unavailableRuns.Count
        unavailableRuns     = $unavailableRuns.ToArray()
        runCount           = $manifestRuns.Count
        runs               = $manifestRuns.ToArray()
    }
    Save-JsonFile -Value $manifest -Path (Join-Path $exportPath 'manifest.json')
    $exportReportJsonPath = Join-Path $exportPath 'export-report.json'
    $exportReportCsvPath = Join-Path $exportPath 'export-report.csv'
    $exportedReportEntries = @($reportEntries | Where-Object status -eq 'Exported')
    $exportedResultCount = if ($exportedReportEntries.Count -gt 0) {
        [int]($exportedReportEntries |
            Measure-Object -Property processedResultCount -Sum).Sum
    } else {
        0
    }
    Save-AdoRunReport `
        -Entries $reportEntries.ToArray() `
        -Summary @{
            candidateRunCount   = $runs.Count
            exportedRunCount    = $manifestRuns.Count
            skippedRunCount     = $skippedRunCount
            skippedNoTestCaseLinkRunCount = $unlinkedRunCount
            skippedOutsideAreaPathRunCount = $outsideAreaRunCount
            unavailableRunCount = $unavailableRuns.Count
            exportedResultCount = $exportedResultCount
        } `
        -JsonPath $exportReportJsonPath `
        -CsvPath $exportReportCsvPath
    Write-AdoLog `
        -Level Info `
        -Message 'Export completed.' `
        -Context @{
            exportPath         = $exportPath
            exportedRunCount   = $manifestRuns.Count
            skippedRunCount    = $skippedRunCount
            unavailableRunCount = $unavailableRuns.Count
        }
    Write-Host ''
    Write-Host 'Export summary' -ForegroundColor Cyan
    Write-Host "  Exported:                  $($manifestRuns.Count)"
    Write-Host "  Skipped without Test Case: $unlinkedRunCount"
    Write-Host "  Skipped outside Area Path: $outsideAreaRunCount"
    Write-Host "  Other Area Path skips:     $($skippedRunCount - $unlinkedRunCount - $outsideAreaRunCount)"
    Write-Host "  Unavailable:               $($unavailableRuns.Count)"
    Write-Host "  Report JSON: $exportReportJsonPath" -ForegroundColor DarkGray
    Write-Host "  Report CSV:  $exportReportCsvPath" -ForegroundColor DarkGray

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
        [object]$Run,

        [switch]$ForceAutomated
    )

    $payload = @{
        name      = $Run.name
        state     = 'InProgress'
        comment   = "Recreated from Azure DevOps Test Run ID $($Run.id)."
        automated = $ForceAutomated.IsPresent -or
            [bool](Get-PropertyValue -Source $Run -Name 'isAutomated' -DefaultValue $false)
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

    if (-not $payload.ContainsKey('automatedTestName')) {
        $payload.automatedTestName = "MigratedTestResult.$($Result.id)"
        $payload.automatedTestType = 'Migrated'
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
    $reportEntries = [Collections.Generic.List[object]]::new()
    $reportTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $importReportJsonPath = Join-Path $resolvedExportPath "import-report-$reportTimestamp.json"
    $importReportCsvPath = Join-Path $resolvedExportPath "import-report-$reportTimestamp.csv"

    $current = 0
    foreach ($manifestRun in $manifest.runs) {
        $current++
        Write-Step "Importing run $current/$($manifest.runCount): ID $($manifestRun.sourceRunId) - $($manifestRun.name)"
        $newRun = $null

        try {
            $runPath = Join-Path $resolvedExportPath ($manifestRun.path -replace '/', [IO.Path]::DirectorySeparatorChar)
            $sourceRun = Get-Content `
                -LiteralPath (Join-Path $runPath 'run.json') `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json
            $resultDocument = Get-Content `
                -LiteralPath (Join-Path $runPath 'results.json') `
                -Raw `
                -ErrorAction Stop |
                ConvertFrom-Json
            $sourceResults = @($resultDocument.value)
            $requiresAutomatedImport = @($sourceResults | Where-Object {
                    [string]::IsNullOrWhiteSpace(
                        [string](Get-PropertyValue -Source $_ -Name 'automatedTestName')
                    )
                }).Count -gt 0

            $newRun = Invoke-AdoRestMethod `
                -Context $Context `
                -Method POST `
                -Path "$encodedProject/_apis/test/runs?api-version=$($script:ApiVersion)" `
                -Body (New-RunCreatePayload -Run $sourceRun -ForceAutomated:$requiresAutomatedImport)

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
            $reportEntries.Add([pscustomobject]@{
                    operation            = 'Import'
                    status               = 'Imported'
                    sourceRunId          = $sourceRun.id
                    targetRunId          = $newRun.id
                    name                 = $manifestRun.name
                    sourceResultCount    = $sourceResults.Count
                    processedResultCount = $resultMap.Count
                    unlinkedResultCount   = $null
                    outsideAreaResultCount = $null
                    reason               = $null
                })
        }
        catch {
            $reportEntries.Add([pscustomobject]@{
                    operation            = 'Import'
                    status               = if ($newRun) { 'FailedPartial' } else { 'Failed' }
                    sourceRunId          = $manifestRun.sourceRunId
                    targetRunId          = if ($newRun) { $newRun.id } else { $null }
                    name                 = $manifestRun.name
                    sourceResultCount    = Get-PropertyValue -Source $manifestRun -Name 'resultCount'
                    processedResultCount = 0
                    unlinkedResultCount   = $null
                    outsideAreaResultCount = $null
                    reason               = $_.Exception.Message
                })

            foreach ($remainingRun in @($manifest.runs | Select-Object -Skip $current)) {
                $reportEntries.Add([pscustomobject]@{
                        operation            = 'Import'
                        status               = 'NotAttempted'
                        sourceRunId          = $remainingRun.sourceRunId
                        targetRunId          = $null
                        name                 = $remainingRun.name
                        sourceResultCount    = $remainingRun.resultCount
                        processedResultCount = 0
                        unlinkedResultCount   = $null
                        outsideAreaResultCount = $null
                        reason               = 'Import stopped after a previous run failed.'
                    })
            }

            Save-AdoRunReport `
                -Entries $reportEntries.ToArray() `
                -Summary @{
                    totalRunCount        = $manifest.runCount
                    importedRunCount     = @($reportEntries | Where-Object status -eq 'Imported').Count
                    failedRunCount       = @($reportEntries | Where-Object status -Like 'Failed*').Count
                    notAttemptedRunCount = @($reportEntries | Where-Object status -eq 'NotAttempted').Count
                } `
                -JsonPath $importReportJsonPath `
                -CsvPath $importReportCsvPath
            Write-Host "Import report: $importReportJsonPath" -ForegroundColor DarkGray
            throw
        }
    }

    $mapPath = Join-Path $resolvedExportPath "migration-map-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    Save-JsonFile -Value $migrationMap -Path $mapPath
    Save-AdoRunReport `
        -Entries $reportEntries.ToArray() `
        -Summary @{
            totalRunCount        = $manifest.runCount
            importedRunCount     = $reportEntries.Count
            failedRunCount       = 0
            notAttemptedRunCount = 0
        } `
        -JsonPath $importReportJsonPath `
        -CsvPath $importReportCsvPath
    Write-Host ''
    Write-Host 'Import summary' -ForegroundColor Cyan
    Write-Host "  Imported:   $($reportEntries.Count)"
    Write-Host '  Failed:     0'
    Write-Host "  Report JSON: $importReportJsonPath" -ForegroundColor DarkGray
    Write-Host "  Report CSV:  $importReportCsvPath" -ForegroundColor DarkGray
    return $mapPath
}

Export-ModuleMember -Function @(
    'Initialize-AdoLogging',
    'Write-AdoLog',
    'New-AdoContext',
    'Test-AdoAccess',
    'Export-AdoTestHistory',
    'Import-AdoTestHistory'
)
