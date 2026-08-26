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
        'linkMode',
        'linkStatus',
        'targetPlanId',
        'targetSuiteIds',
        'unresolvedReferenceCount',
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
            "?detailsToInclude=WorkItems,Iterations,Point&`$skip=$skip&`$top=$pageSize" +
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

function Get-AdoTestPlanDetails {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$PlanId,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $cacheKey = "plan:$PlanId"
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $plan = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/testplan/plans/${PlanId}?api-version=$($script:ApiVersion)"
    $Cache[$cacheKey] = $plan
    return $plan
}

function Get-AdoTestSuiteDetails {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$PlanId,

        [Parameter(Mandatory)]
        [int]$SuiteId,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $cacheKey = "suite:${PlanId}:$SuiteId"
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $suite = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/testplan/Plans/${PlanId}/Suites/${SuiteId}?api-version=$($script:ApiVersion)"
    $Cache[$cacheKey] = $suite
    return $suite
}

function Get-AdoTestPointList {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$PlanId,

        [Parameter(Mandatory)]
        [int]$SuiteId,

        [AllowEmptyCollection()]
        [int[]]$TestPointIds,

        [AllowNull()]
        [Nullable[int]]$TestCaseId,

        [switch]$IsRecursive
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $queryParts = @(
        'includePointDetails=true',
        "api-version=$($script:ApiVersion)"
    )

    if ($IsRecursive.IsPresent) {
        $queryParts += 'isRecursive=true'
    }
    if ($null -ne $TestCaseId) {
        $queryParts += "testCaseId=$TestCaseId"
    }
    if ($null -ne $TestPointIds -and $TestPointIds.Count -gt 0) {
        $queryParts += "testPointIds=$([string]::Join(',', $TestPointIds))"
    }

    $response = Invoke-AdoRestMethod `
        -Context $Context `
        -Method GET `
        -Path "$encodedProject/_apis/testplan/Plans/$PlanId/Suites/$SuiteId/TestPoint?$(($queryParts -join '&'))"
    return @(Get-CollectionValue -Response $response)
}

function Get-AdoAssociatedBugIds {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $bugIds = [Collections.Generic.HashSet[int]]::new()
    foreach ($associatedBug in @(Get-PropertyValue -Source $Result -Name 'associatedBugs' -DefaultValue @())) {
        $bugId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $associatedBug -Name 'id' -DefaultValue $associatedBug)
        if ($null -ne $bugId) {
            $null = $bugIds.Add($bugId)
        }
    }

    foreach ($workItem in @(Get-PropertyValue -Source $Result -Name 'workItems' -DefaultValue @())) {
        $workItemType = [string](Get-PropertyValue -Source $workItem -Name 'type')
        if ([string]::IsNullOrWhiteSpace($workItemType) -or
            -not $workItemType.Equals('Bug', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $bugId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $workItem -Name 'id')
        if ($null -ne $bugId) {
            $null = $bugIds.Add($bugId)
        }
    }

    return @($bugIds | Sort-Object)
}

function Get-AdoRunLinkMetadata {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$Run,

        [Parameter(Mandatory)]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [hashtable]$PlanCache,

        [Parameter(Mandatory)]
        [hashtable]$SuiteCache
    )

    $entries = [Collections.Generic.List[object]]::new()
    $planInfo = Get-AdoReferenceInfo -Source $Run -PropertyNames @('plan')
    $planDetails = $null
    $pointIndex = @{}
    $lookupFailureReason = $null
    $plannedPointIds = @($Results | ForEach-Object {
            ConvertTo-IntIfPossible -Value (
                Get-PropertyValue -Source (Get-PropertyValue -Source $_ -Name 'testPoint') -Name 'id'
            )
        } | Where-Object { $null -ne $_ } | Sort-Object -Unique)

    if ($plannedPointIds.Count -gt 0) {
        if ($null -eq $planInfo.Id) {
            $lookupFailureReason = 'Source run contains planned results but run.plan.id was not returned.'
        }
        else {
            try {
                $planDetails = Get-AdoTestPlanDetails `
                    -Context $Context `
                    -PlanId $planInfo.Id `
                    -Cache $PlanCache
                if ([string]::IsNullOrWhiteSpace([string]$planInfo.Name)) {
                    $planInfo.Name = [string](Get-PropertyValue -Source $planDetails -Name 'name')
                }

                $rootSuiteInfo = Get-AdoReferenceInfo -Source $planDetails -PropertyNames @('rootSuite')
                if ($null -eq $rootSuiteInfo.Id) {
                    throw 'Source test plan details did not include rootSuite.id.'
                }

                foreach ($pointBatch in @(Split-AdoIntBatch -Values $plannedPointIds -Size 200)) {
                    foreach ($point in @(Get-AdoTestPointList `
                                -Context $Context `
                                -PlanId $planInfo.Id `
                                -SuiteId $rootSuiteInfo.Id `
                                -TestPointIds $pointBatch `
                                -IsRecursive)) {
                        $pointId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $point -Name 'id')
                        if ($null -ne $pointId) {
                            $pointIndex["$pointId"] = $point
                        }
                    }
                }
            }
            catch {
                $lookupFailureReason = $_.Exception.Message
                Write-AdoLog `
                    -Level Warning `
                    -Message 'Planned test point metadata lookup failed during export.' `
                    -Context @{
                        runId  = $Run.id
                        planId = $planInfo.Id
                        error  = $_.Exception.Message
                    }
            }
        }
    }

    foreach ($result in $Results) {
        $sourceResultId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $result -Name 'id')
        $sourceTestCase = Get-AdoReferenceInfo -Source $result -PropertyNames @('testCase')
        if ($null -eq $sourceTestCase.Id) {
            $sourceTestCase.Id = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $result -Name 'testCaseId')
        }
        if ([string]::IsNullOrWhiteSpace([string]$sourceTestCase.Name)) {
            $sourceTestCase.Name = [string](Get-PropertyValue -Source $result -Name 'testCaseTitle')
        }

        $sourcePointId = ConvertTo-IntIfPossible -Value (
            Get-PropertyValue -Source (Get-PropertyValue -Source $result -Name 'testPoint') -Name 'id'
        )
        $sourceConfiguration = Get-AdoReferenceInfo -Source $result -PropertyNames @('configuration')
        $sourceAssociatedBugIds = @(Get-AdoAssociatedBugIds -Result $result)

        $entry = [ordered]@{
            sourceResultId          = $sourceResultId
            sourceTestCaseId        = $sourceTestCase.Id
            sourceTestCaseName      = $sourceTestCase.Name
            sourcePointId           = $sourcePointId
            sourcePlanId            = $planInfo.Id
            sourcePlanName          = $planInfo.Name
            sourceSuiteId           = $null
            sourceSuiteName         = $null
            sourceConfigurationId   = $sourceConfiguration.Id
            sourceConfigurationName = $sourceConfiguration.Name
            sourceAssociatedBugIds  = $sourceAssociatedBugIds
            resolution              = 'Resolved'
            status                  = 'Planned'
            reason                  = $null
        }

        if ($null -eq $sourcePointId) {
            $entry.resolution = 'NotApplicable'
            $entry.status = 'Unplanned'
            $entry.reason = 'Source result has no test point metadata and can only be imported as an unplanned result.'
            $entries.Add([pscustomobject]$entry)
            continue
        }

        if ($null -eq $planInfo.Id) {
            $entry.resolution = 'Unresolved'
            $entry.status = 'IncompleteMetadata'
            $entry.reason = 'Source run contains a planned result but run.plan.id is missing.'
            $entries.Add([pscustomobject]$entry)
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($lookupFailureReason)) {
            $entry.resolution = 'Unresolved'
            $entry.status = 'LookupFailed'
            $entry.reason = "Source planned metadata lookup failed. $lookupFailureReason"
            $entries.Add([pscustomobject]$entry)
            continue
        }

        $point = $pointIndex["$sourcePointId"]
        if ($null -eq $point) {
            $entry.resolution = 'Unresolved'
            $entry.status = 'LookupFailed'
            $entry.reason = "Source test point $sourcePointId was not returned by the TestPoint lookup."
            $entries.Add([pscustomobject]$entry)
            continue
        }

        $pointTestCase = Get-AdoReferenceInfo -Source $point -PropertyNames @('testCase')
        if ($null -eq $entry.sourceTestCaseId) {
            $entry.sourceTestCaseId = $pointTestCase.Id
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.sourceTestCaseName)) {
            $entry.sourceTestCaseName = $pointTestCase.Name
        }

        $suiteInfo = Get-AdoReferenceInfo -Source $point -PropertyNames @('testSuite', 'suite')
        if ($null -ne $suiteInfo.Id -and [string]::IsNullOrWhiteSpace([string]$suiteInfo.Name)) {
            try {
                $suiteDetails = Get-AdoTestSuiteDetails `
                    -Context $Context `
                    -PlanId $planInfo.Id `
                    -SuiteId $suiteInfo.Id `
                    -Cache $SuiteCache
                $suiteInfo.Name = [string](Get-PropertyValue -Source $suiteDetails -Name 'name')
            }
            catch {
                Write-AdoLog `
                    -Level Warning `
                    -Message 'Source suite name lookup failed during export.' `
                    -Context @{
                        runId   = $Run.id
                        planId  = $planInfo.Id
                        suiteId = $suiteInfo.Id
                        error   = $_.Exception.Message
                    }
            }
        }
        $entry.sourceSuiteId = $suiteInfo.Id
        $entry.sourceSuiteName = $suiteInfo.Name

        $pointConfiguration = Get-AdoReferenceInfo -Source $point -PropertyNames @('configuration', 'testConfiguration')
        if ($null -eq $entry.sourceConfigurationId) {
            $entry.sourceConfigurationId = $pointConfiguration.Id
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.sourceConfigurationName)) {
            $entry.sourceConfigurationName = $pointConfiguration.Name
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.sourcePlanName) -and $null -ne $planDetails) {
            $entry.sourcePlanName = [string](Get-PropertyValue -Source $planDetails -Name 'name')
        }

        $missingCore = [Collections.Generic.List[string]]::new()
        foreach ($coreField in @('sourcePlanId', 'sourceSuiteId', 'sourceTestCaseId', 'sourcePointId')) {
            if ($null -eq $entry[$coreField]) {
                $missingCore.Add($coreField)
            }
        }

        if ($missingCore.Count -gt 0) {
            $entry.resolution = 'Unresolved'
            $entry.status = 'IncompleteMetadata'
            $entry.reason = "Required planned metadata is missing: $($missingCore -join ', ')."
            $entries.Add([pscustomobject]$entry)
            continue
        }

        $missingOptional = [Collections.Generic.List[string]]::new()
        foreach ($nameField in @(
                'sourcePlanName',
                'sourceSuiteName',
                'sourceTestCaseName',
                'sourceConfigurationId',
                'sourceConfigurationName'
            )) {
            $value = $entry[$nameField]
            if ($null -eq $value -or ([string]$value).Length -eq 0) {
                $missingOptional.Add($nameField)
            }
        }

        if ($missingOptional.Count -gt 0) {
            $entry.resolution = 'Partial'
            $entry.status = 'IncompleteMetadata'
            $entry.reason = "Optional planned metadata is missing: $($missingOptional -join ', ')."
        }

        $entries.Add([pscustomobject]$entry)
    }

    $entryArray = $entries.ToArray()
    $resolvedResultCount = @($entryArray | Where-Object resolution -eq 'Resolved').Count
    $partialResultCount = @($entryArray | Where-Object resolution -eq 'Partial').Count
    $unresolvedResultCount = @($entryArray | Where-Object resolution -eq 'Unresolved').Count
    $notApplicableResultCount = @($entryArray | Where-Object resolution -eq 'NotApplicable').Count

    return [ordered]@{
        generatedAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
        sourceRunId              = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $Run -Name 'id')
        sourcePlanId             = $planInfo.Id
        sourcePlanName           = $planInfo.Name
        resultCount              = $entryArray.Count
        resolvedResultCount      = $resolvedResultCount
        partialResultCount       = $partialResultCount
        unresolvedResultCount    = $unresolvedResultCount
        notApplicableResultCount = $notApplicableResultCount
        nonLinkableResultCount   = $unresolvedResultCount + $notApplicableResultCount
        results                  = $entryArray
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
    $sourcePlanCache = @{}
    $sourceSuiteCache = @{}
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
                            unlinkedResultCount  = $unlinkedResultCount
                            outsideAreaResultCount = $outsideAreaResultCount
                            linkMode             = $null
                            linkStatus           = $null
                            targetPlanId         = $null
                            targetSuiteIds       = $null
                            unresolvedReferenceCount = 0
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

            $linkMetadata = Get-AdoRunLinkMetadata `
                -Context $Context `
                -Run $run `
                -Results $results `
                -PlanCache $sourcePlanCache `
                -SuiteCache $sourceSuiteCache
            Save-JsonFile -Value $linkMetadata -Path (Join-Path $runPath 'links.json')

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
                    linkMetadataPath = "runs/$($runSummary.id)/links.json"
                    resultCount      = $results.Count
                    sourceResultCount = $allResults.Count
                })
            $reasonParts = [Collections.Generic.List[string]]::new()
            if ($unlinkedResultCount -gt 0 -or $outsideAreaResultCount -gt 0) {
                $reasonParts.Add(
                    "Exported matching results only. Excluded $unlinkedResultCount without Test Case link and $outsideAreaResultCount outside the selected Area Path."
                )
            }
            if ($linkMetadata.nonLinkableResultCount -gt 0) {
                $reasonParts.Add(
                    "$($linkMetadata.nonLinkableResultCount) exported result(s) are not eligible for planned linking without fallback. See links.json for details."
                )
            }
            $reportEntries.Add([pscustomobject]@{
                    operation                = 'Export'
                    status                   = 'Exported'
                    sourceRunId              = $runSummary.id
                    targetRunId              = $null
                    name                     = $runSummary.name
                    sourceResultCount        = $allResults.Count
                    processedResultCount     = $results.Count
                    unlinkedResultCount      = $unlinkedResultCount
                    outsideAreaResultCount   = $outsideAreaResultCount
                    linkMode                 = $null
                    linkStatus               = $null
                    targetPlanId             = $null
                    targetSuiteIds           = $null
                    unresolvedReferenceCount = $linkMetadata.nonLinkableResultCount
                    reason                   = if ($reasonParts.Count -gt 0) {
                        $reasonParts -join ' '
                    } else {
                        $null
                    }
                })
            Write-AdoLog `
                -Level Info `
                -Message 'Run exported successfully.' `
                -Context @{
                    runId                = $runSummary.id
                    resultCount          = $results.Count
                    nonLinkableResultCount = $linkMetadata.nonLinkableResultCount
                }
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
                        operation                = 'Export'
                        status                   = 'Unavailable'
                        sourceRunId              = $runSummary.id
                        targetRunId              = $null
                        name                     = $runSummary.name
                        sourceResultCount        = $null
                        processedResultCount     = 0
                        unlinkedResultCount      = $null
                        outsideAreaResultCount   = $null
                        linkMode                 = $null
                        linkStatus               = $null
                        targetPlanId             = $null
                        targetSuiteIds           = $null
                        unresolvedReferenceCount = 0
                        reason                   = $_.Exception.Message
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
        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory)]
        [string]$SourceName,

        [string]$TargetName = $SourceName
    )

    if ($null -eq $Source) {
        return
    }

    $property = $Source.PSObject.Properties[$SourceName]
    if ($property -and $null -ne $property.Value -and $property.Value -ne '') {
        $Target[$TargetName] = $property.Value
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    if ($null -eq $Source) {
        return $DefaultValue
    }

    $property = $Source.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        return $property.Value
    }
    return $DefaultValue
}

function ConvertTo-IntIfPossible {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $parsedValue = 0
    if ([int]::TryParse([string]$Value, [ref]$parsedValue)) {
        return $parsedValue
    }

    return $null
}

function Get-AdoReferenceInfo {
    param(
        [AllowNull()]
        [object]$Source,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    if ($null -eq $Source) {
        return [pscustomobject]@{
            Id           = $null
            Name         = $null
            Source       = $null
            PropertyName = $null
        }
    }

    foreach ($propertyName in $PropertyNames) {
        $reference = Get-PropertyValue -Source $Source -Name $propertyName
        if ($null -eq $reference) {
            continue
        }

        return [pscustomobject]@{
            Id           = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $reference -Name 'id')
            Name         = Get-PropertyValue -Source $reference -Name 'name'
            Source       = $reference
            PropertyName = $propertyName
        }
    }

    return [pscustomobject]@{
        Id           = $null
        Name         = $null
        Source       = $null
        PropertyName = $null
    }
}

function Split-AdoIntBatch {
    param(
        [AllowEmptyCollection()]
        [int[]]$Values,

        [int]$Size = 200
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return @()
    }

    $batches = [Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Values.Count; $offset += $Size) {
        $lastIndex = [Math]::Min($offset + $Size - 1, $Values.Count - 1)
        $batches.Add(@($Values[$offset..$lastIndex]))
    }

    return $batches.ToArray()
}

function Test-AdoFieldReferenceName {
    param(
        [Parameter(Mandatory)]
        [string]$FieldName
    )

    return $FieldName -match '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$'
}

function Get-AdoReflectedSourceId {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $normalized = $text.Trim()
    if ($normalized -match '^\d+$') {
        return [int]$normalized
    }
    if ($normalized -match '[\\/](\d+)$') {
        return [int]$matches[1]
    }

    return $null
}

function Get-AdoOrganizationMonikers {
    param(
        [Parameter(Mandatory)]
        [string]$Organization
    )

    $normalizedOrganization = Get-NormalizedOrganizationUrl -Organization $Organization
    $uri = [uri]$normalizedOrganization
    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $tokens.Add($normalizedOrganization.TrimEnd('/'))

    if ($uri.Host.Equals('dev.azure.com', [StringComparison]::OrdinalIgnoreCase)) {
        if ($uri.Segments.Count -gt 1) {
            $null = $tokens.Add($uri.Segments[1].Trim('/'))
        }
    }
    elseif ($uri.Host.EndsWith('.visualstudio.com', [StringComparison]::OrdinalIgnoreCase)) {
        $null = $tokens.Add($uri.Host.Substring(0, $uri.Host.IndexOf('.')))
    }

    return @($tokens)
}

function Test-AdoReflectedValueMatchesSourceContext {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$SourceOrganization,

        [Parameter(Mandatory)]
        [string]$SourceProject
    )

    if ($null -eq $Value) {
        return $false
    }

    $normalizedValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($normalizedValue)) {
        return $false
    }

    $comparisonValue = $normalizedValue.Trim().ToLowerInvariant().Replace('\', '/')
    $projectToken = $SourceProject.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($projectToken) -or -not $comparisonValue.Contains("/$projectToken/")) {
        return $false
    }

    foreach ($token in @(Get-AdoOrganizationMonikers -Organization $SourceOrganization)) {
        $normalizedToken = [string]$token
        if ([string]::IsNullOrWhiteSpace($normalizedToken)) {
            continue
        }

        $normalizedToken = $normalizedToken.ToLowerInvariant().Replace('\', '/').TrimEnd('/')
        if ($comparisonValue.Contains($normalizedToken) -or $comparisonValue.Contains("/$normalizedToken/")) {
            return $true
        }
    }

    return $false
}

function Test-AdoUnavailableFieldError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [string]$FieldName
    )

    $message = [string]$ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        return $false
    }

    return $message -match [regex]::Escape($FieldName) -and
        $message -match '(?i)(does not exist|was not found|is not a valid field|invalid field|cannot find field)'
}

function Get-AdoReflectedWorkItemIndex {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$ReflectedWorkItemIdField,

        [Parameter(Mandatory)]
        [string]$SourceOrganization,

        [Parameter(Mandatory)]
        [string]$SourceProject
    )

    $encodedProject = [uri]::EscapeDataString($Context.Project)
    $query = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND (
        [System.WorkItemType] = 'Test Plan'
        OR [System.WorkItemType] = 'Test Suite'
        OR [System.WorkItemType] = 'Test Case'
        OR [System.WorkItemType] = 'Bug'
      )
  AND [$ReflectedWorkItemIdField] <> ''
"@

    try {
        $response = Invoke-AdoRestMethod `
            -Context $Context `
            -Method POST `
            -Path "$encodedProject/_apis/wit/wiql?api-version=$($script:ApiVersion)" `
            -Body @{ query = $query }
    }
    catch {
        if (Test-AdoUnavailableFieldError -ErrorRecord $_ -FieldName $ReflectedWorkItemIdField) {
            return [pscustomobject]@{
                Available = $false
                Reason    = "Reflected work item field '$ReflectedWorkItemIdField' is not available in target project '$($Context.Project)'."
                Index     = $null
            }
        }
        throw
    }

    $ids = @($response.workItems | ForEach-Object { ConvertTo-IntIfPossible -Value $_.id } | Where-Object { $null -ne $_ })
    $index = @{}
    if ($ids.Count -eq 0) {
        Write-AdoLog `
            -Level Info `
            -Message 'Reflected work item index built.' `
            -Context @{ field = $ReflectedWorkItemIdField; indexedWorkItemCount = 0 }
        return [pscustomobject]@{
            Available = $true
            Reason    = $null
            Index     = $index
        }
    }

    $fieldList = @(
        'System.Id',
        'System.WorkItemType',
        'System.Title',
        $ReflectedWorkItemIdField
    )

    foreach ($idBatch in @(Split-AdoIntBatch -Values $ids -Size 200)) {
        $workItems = Invoke-AdoRestMethod `
            -Context $Context `
            -Method GET `
            -Path "$encodedProject/_apis/wit/workitems?ids=$([string]::Join(',', $idBatch))&fields=$([string]::Join(',', $fieldList))&errorPolicy=Omit&api-version=$($script:ApiVersion)"

        foreach ($workItem in @(Get-CollectionValue -Response $workItems)) {
            $fields = Get-PropertyValue -Source $workItem -Name 'fields'
            $workItemType = [string](Get-PropertyValue -Source $fields -Name 'System.WorkItemType')
            $reflectedValue = Get-PropertyValue -Source $fields -Name $ReflectedWorkItemIdField
            $parsedSourceId = Get-AdoReflectedSourceId -Value $reflectedValue
            if ([string]::IsNullOrWhiteSpace($workItemType) -or $null -eq $parsedSourceId) {
                continue
            }

            $candidate = [pscustomobject]@{
                targetId             = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $workItem -Name 'id')
                workItemType         = $workItemType
                title                = [string](Get-PropertyValue -Source $fields -Name 'System.Title')
                reflectedValue       = [string]$reflectedValue
                sourceId             = $parsedSourceId
                matchesSourceContext = Test-AdoReflectedValueMatchesSourceContext `
                    -Value $reflectedValue `
                    -SourceOrganization $SourceOrganization `
                    -SourceProject $SourceProject
            }
            $key = "{0}|{1}" -f $candidate.workItemType.ToLowerInvariant(), $candidate.sourceId
            if (-not $index.ContainsKey($key)) {
                $index[$key] = [Collections.Generic.List[object]]::new()
            }
            $index[$key].Add($candidate)
        }
    }

    Write-AdoLog `
        -Level Info `
        -Message 'Reflected work item index built.' `
        -Context @{ field = $ReflectedWorkItemIdField; indexedWorkItemCount = $ids.Count }
    return [pscustomobject]@{
        Available = $true
        Reason    = $null
        Index     = $index
    }
}

function Resolve-AdoReflectedWorkItem {
    param(
        [hashtable]$Index,

        [AllowNull()]
        [Nullable[int]]$SourceId,

        [Parameter(Mandatory)]
        [string]$ExpectedWorkItemType
    )

    if ($null -eq $SourceId) {
        return [pscustomobject]@{
            Resolved   = $false
            Status     = 'MissingSourceId'
            Candidate  = $null
            Candidates = @()
            Reason     = "Source $ExpectedWorkItemType ID is missing."
        }
    }

    if ($null -eq $Index) {
        return [pscustomobject]@{
            Resolved   = $false
            Status     = 'IndexUnavailable'
            Candidate  = $null
            Candidates = @()
            Reason     = 'Reflected work item index is unavailable.'
        }
    }

    $key = "{0}|{1}" -f $ExpectedWorkItemType.ToLowerInvariant(), $SourceId
    $candidates = @(if ($Index.ContainsKey($key)) { $Index[$key] } else { @() })
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            Resolved   = $false
            Status     = 'NotFound'
            Candidate  = $null
            Candidates = @()
            Reason     = "No target $ExpectedWorkItemType reflects source ID $SourceId."
        }
    }
    if ($candidates.Count -eq 1) {
        return [pscustomobject]@{
            Resolved   = $true
            Status     = 'Resolved'
            Candidate  = $candidates[0]
            Candidates = $candidates
            Reason     = $null
        }
    }

    $preferred = @($candidates | Where-Object matchesSourceContext)
    if ($preferred.Count -eq 1) {
        return [pscustomobject]@{
            Resolved   = $true
            Status     = 'Resolved'
            Candidate  = $preferred[0]
            Candidates = $candidates
            Reason     = $null
        }
    }

    $reason = if ($preferred.Count -gt 1) {
        "Multiple target $ExpectedWorkItemType work items reflect source ID $SourceId and match the source organization/project."
    }
    else {
        "Multiple target $ExpectedWorkItemType work items reflect source ID $SourceId."
    }

    return [pscustomobject]@{
        Resolved   = $false
        Status     = 'Ambiguous'
        Candidate  = $null
        Candidates = $candidates
        Reason     = $reason
    }
}

function Get-AdoTargetPointsForTestCase {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$PlanId,

        [Parameter(Mandatory)]
        [int]$SuiteId,

        [Parameter(Mandatory)]
        [int]$TestCaseId,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $cacheKey = "$PlanId|$SuiteId|$TestCaseId"
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    $points = @(Get-AdoTestPointList `
            -Context $Context `
            -PlanId $PlanId `
            -SuiteId $SuiteId `
            -TestCaseId $TestCaseId)
    $Cache[$cacheKey] = $points
    return $points
}

function Resolve-AdoTargetTestPoint {
    param(
        [Parameter(Mandatory)]
        [object[]]$Points,

        [AllowNull()]
        [string]$SourceConfigurationName
    )

    if ($Points.Count -eq 0) {
        return [pscustomobject]@{
            Resolved  = $false
            Candidate = $null
            Reason    = 'No target test points were found for the resolved target plan, suite, and test case.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($SourceConfigurationName)) {
        if ($Points.Count -eq 1) {
            return [pscustomobject]@{
                Resolved  = $true
                Candidate = $Points[0]
                Reason    = $null
            }
        }

        return [pscustomobject]@{
            Resolved  = $false
            Candidate = $null
            Reason    = 'Source configuration name is missing and the target contains multiple matching test points.'
        }
    }

    $matches = @($Points | Where-Object {
            $configuration = Get-AdoReferenceInfo -Source $_ -PropertyNames @('configuration', 'testConfiguration')
            $targetConfigurationName = [string]$configuration.Name
            -not [string]::IsNullOrWhiteSpace($targetConfigurationName) -and
            $targetConfigurationName.Equals($SourceConfigurationName, [StringComparison]::OrdinalIgnoreCase)
        })

    if ($matches.Count -eq 1) {
        return [pscustomobject]@{
            Resolved  = $true
            Candidate = $matches[0]
            Reason    = $null
        }
    }
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Resolved  = $false
            Candidate = $null
            Reason    = "No target test point matched source configuration '$SourceConfigurationName'."
        }
    }

    return [pscustomobject]@{
        Resolved  = $false
        Candidate = $null
        Reason    = "Multiple target test points matched source configuration '$SourceConfigurationName'."
    }
}

function Get-AdoLinkResolutionReason {
    param(
        [AllowEmptyCollection()]
        [object[]]$UnresolvedReferences,

        [AllowEmptyCollection()]
        [string[]]$AdditionalReasons
    )

    $messages = [Collections.Generic.List[string]]::new()
    foreach ($additionalReason in @($AdditionalReasons)) {
        if (-not [string]::IsNullOrWhiteSpace($additionalReason)) {
            $messages.Add($additionalReason)
        }
    }
    foreach ($reference in @($UnresolvedReferences)) {
        $referenceReason = [string](Get-PropertyValue -Source $reference -Name 'reason')
        if (-not [string]::IsNullOrWhiteSpace($referenceReason)) {
            $messages.Add($referenceReason)
        }
    }

    $uniqueMessages = @($messages.ToArray() | Select-Object -Unique)
    if ($uniqueMessages.Count -eq 0) {
        return $null
    }

    return $uniqueMessages -join '; '
}

function New-AdoImportReportEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [object]$SourceRunId,

        [AllowNull()]
        [object]$TargetRunId,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$SourceResultCount,

        [AllowNull()]
        [object]$ProcessedResultCount,

        [AllowNull()]
        [string]$LinkMode,

        [AllowNull()]
        [string]$LinkStatus,

        [AllowNull()]
        [object]$TargetPlanId,

        [AllowEmptyCollection()]
        [object[]]$TargetSuiteIds,

        [AllowNull()]
        [object]$UnresolvedReferenceCount,

        [AllowNull()]
        [string]$Reason
    )

    return [pscustomobject]@{
        operation                = 'Import'
        status                   = $Status
        sourceRunId              = $SourceRunId
        targetRunId              = $TargetRunId
        name                     = $Name
        sourceResultCount        = $SourceResultCount
        processedResultCount     = $ProcessedResultCount
        unlinkedResultCount      = $null
        outsideAreaResultCount   = $null
        linkMode                 = $LinkMode
        linkStatus               = $LinkStatus
        targetPlanId             = $TargetPlanId
        targetSuiteIds           = if (@($TargetSuiteIds).Count -gt 0) {
            (@($TargetSuiteIds) | Sort-Object -Unique) -join ';'
        } else {
            $null
        }
        unresolvedReferenceCount = $UnresolvedReferenceCount
        reason                   = $Reason
    }
}

function New-RunCreatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Run,

        [int]$PlanId,

        [AllowEmptyCollection()]
        [int[]]$PointIds,

        [switch]$ForceAutomated
    )

    $payload = @{
        name      = $Run.name
        state     = 'InProgress'
        comment   = "Recreated from Azure DevOps Test Run ID $($Run.id)."
        automated = $ForceAutomated.IsPresent -or
            [bool](Get-PropertyValue -Source $Run -Name 'isAutomated' -DefaultValue $false)
    }
    Add-PropertyIfPresent -Target $payload -Source $Run -SourceName 'startedDate' -TargetName 'startDate'

    if ($PSBoundParameters.ContainsKey('PlanId')) {
        $payload.plan = @{ id = $PlanId }
        $payload.pointIds = @($PointIds)
    }

    return $payload
}

function New-ResultCreatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $sourceResultId = Get-PropertyValue -Source $Result -Name 'id'
    $sourceComment = Get-PropertyValue -Source $Result -Name 'comment'
    $sourceOutcome = [string](Get-PropertyValue -Source $Result -Name 'outcome' -DefaultValue 'Unspecified')
    if ([string]::IsNullOrWhiteSpace($sourceOutcome)) {
        $sourceOutcome = 'Unspecified'
    }

    $payload = @{
        state   = 'Completed'
        outcome = $sourceOutcome
        comment = if ($sourceComment) {
            "$sourceComment`nSource result ID: $sourceResultId"
        } else {
            "Source result ID: $sourceResultId"
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
        $payload.automatedTestName = "MigratedTestResult.$sourceResultId"
        $payload.automatedTestType = 'Migrated'
    }

    return $payload
}

function New-ResultUpdatePayload {
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [int]$TargetResultId,

        [AllowEmptyCollection()]
        [int[]]$AssociatedBugIds
    )

    $payload = @{ id = $TargetResultId }
    foreach ($propertyName in @(
            'state',
            'outcome',
            'comment',
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

    if ($null -ne $AssociatedBugIds -and $AssociatedBugIds.Count -gt 0) {
        $payload.associatedBugs = @($AssociatedBugIds | ForEach-Object { @{ id = $_ } })
    }

    return $payload
}

function Complete-AdoRun {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$EncodedProject,

        [Parameter(Mandatory)]
        [int]$RunId,

        [Parameter(Mandatory)]
        [object]$SourceRun
    )

    $sourceCompleteDate = Get-PropertyValue -Source $SourceRun -Name 'completedDate'
    if (-not $sourceCompleteDate) {
        $sourceCompleteDate = Get-PropertyValue -Source $SourceRun -Name 'completeDate'
    }

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
        -Path "$EncodedProject/_apis/test/runs/${RunId}?api-version=$($script:ApiVersion)" `
        -Body $completePayload
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

function Resolve-AdoPlannedRunLinks {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [object]$Manifest,

        [Parameter(Mandatory)]
        [string]$RunPath,

        [Parameter(Mandatory)]
        [object[]]$SourceResults,

        [Parameter(Mandatory)]
        [hashtable]$ReflectedIndex,

        [Parameter(Mandatory)]
        [hashtable]$PointCache
    )

    $linksPath = Join-Path $RunPath 'links.json'
    $resolvedResults = [Collections.Generic.List[object]]::new()
    $unresolvedReferences = [Collections.Generic.List[object]]::new()
    $additionalReasons = [Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $linksPath -PathType Leaf)) {
        $unresolvedReferences.Add([pscustomobject]@{
                resultId      = $null
                referenceType = 'links.json'
                sourceId      = $null
                isCore        = $true
                reason        = 'links.json was not found in the exported run directory.'
            })
        return [pscustomobject]@{
            IsLinkable               = $false
            TargetPlanId             = $null
            TargetSuiteIds           = @()
            TargetPointIds           = @()
            ResolvedResults          = @()
            AdditionalReasons        = $additionalReasons.ToArray()
            UnresolvedReferenceCount = $unresolvedReferences.Count
            UnresolvedReferences     = $unresolvedReferences.ToArray()
            Reason                   = Get-AdoLinkResolutionReason -UnresolvedReferences $unresolvedReferences.ToArray() -AdditionalReasons $additionalReasons.ToArray()
        }
    }

    $linksDocument = Get-Content -LiteralPath $linksPath -Raw | ConvertFrom-Json
    $linkEntries = @(Get-PropertyValue -Source $linksDocument -Name 'results' -DefaultValue @())
    if ($linkEntries.Count -ne $SourceResults.Count) {
        $additionalReasons.Add(
            "links.json contains $($linkEntries.Count) result metadata entry(ies) for $($SourceResults.Count) exported result(s)."
        )
    }

    $linkEntryByResultId = @{}
    foreach ($linkEntry in $linkEntries) {
        $linkEntryByResultId[[string](Get-PropertyValue -Source $linkEntry -Name 'sourceResultId')] = $linkEntry
    }

    foreach ($sourceResult in $SourceResults) {
        $sourceResultIdText = [string](Get-PropertyValue -Source $sourceResult -Name 'id')
        $linkEntry = $linkEntryByResultId[$sourceResultIdText]
        if ($null -eq $linkEntry) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'ResultMetadata'
                    sourceId      = $sourceResultIdText
                    isCore        = $true
                    reason        = "links.json does not contain metadata for source result $sourceResultIdText."
                })
            continue
        }

        $sourcePlanId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $linkEntry -Name 'sourcePlanId')
        $sourceSuiteId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $linkEntry -Name 'sourceSuiteId')
        $sourceTestCaseId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $linkEntry -Name 'sourceTestCaseId')
        $sourcePointId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $linkEntry -Name 'sourcePointId')
        $sourceConfigurationName = [string](Get-PropertyValue -Source $linkEntry -Name 'sourceConfigurationName')

        if ($null -eq $sourcePointId) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'TestPoint'
                    sourceId      = $null
                    isCore        = $true
                    reason        = if (Get-PropertyValue -Source $linkEntry -Name 'reason') {
                        [string](Get-PropertyValue -Source $linkEntry -Name 'reason')
                    } else {
                        "Source result $sourceResultIdText has no planned test point metadata."
                    }
                })
            continue
        }

        $planResolution = Resolve-AdoReflectedWorkItem `
            -Index $ReflectedIndex `
            -SourceId $sourcePlanId `
            -ExpectedWorkItemType 'Test Plan'
        if (-not $planResolution.Resolved) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Plan'
                    sourceId      = $sourcePlanId
                    isCore        = $true
                    reason        = $planResolution.Reason
                })
            continue
        }

        $suiteResolution = Resolve-AdoReflectedWorkItem `
            -Index $ReflectedIndex `
            -SourceId $sourceSuiteId `
            -ExpectedWorkItemType 'Test Suite'
        if (-not $suiteResolution.Resolved) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Suite'
                    sourceId      = $sourceSuiteId
                    isCore        = $true
                    reason        = $suiteResolution.Reason
                })
            continue
        }

        $testCaseResolution = Resolve-AdoReflectedWorkItem `
            -Index $ReflectedIndex `
            -SourceId $sourceTestCaseId `
            -ExpectedWorkItemType 'Test Case'
        if (-not $testCaseResolution.Resolved) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Case'
                    sourceId      = $sourceTestCaseId
                    isCore        = $true
                    reason        = $testCaseResolution.Reason
                })
            continue
        }

        try {
            $targetPoints = @(Get-AdoTargetPointsForTestCase `
                    -Context $Context `
                    -PlanId $planResolution.Candidate.targetId `
                    -SuiteId $suiteResolution.Candidate.targetId `
                    -TestCaseId $testCaseResolution.Candidate.targetId `
                    -Cache $PointCache)
            $pointResolution = Resolve-AdoTargetTestPoint `
                -Points $targetPoints `
                -SourceConfigurationName $sourceConfigurationName
        }
        catch {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Point'
                    sourceId      = $sourcePointId
                    isCore        = $true
                    reason        = "Target test point lookup failed. $($_.Exception.Message)"
                })
            continue
        }
        if (-not $pointResolution.Resolved) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Point'
                    sourceId      = $sourcePointId
                    isCore        = $true
                    reason        = $pointResolution.Reason
                })
            continue
        }

        $targetPointId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $pointResolution.Candidate -Name 'id')
        if ($null -eq $targetPointId) {
            $unresolvedReferences.Add([pscustomobject]@{
                    resultId      = $sourceResultIdText
                    referenceType = 'Test Point'
                    sourceId      = $sourcePointId
                    isCore        = $true
                    reason        = 'The resolved target test point did not include an id.'
                })
            continue
        }

        $targetConfiguration = Get-AdoReferenceInfo -Source $pointResolution.Candidate -PropertyNames @('configuration', 'testConfiguration')
        $resolvedResults.Add([pscustomobject]@{
                SourceResultId         = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $linkEntry -Name 'sourceResultId')
                SourcePointId          = $sourcePointId
                SourceAssociatedBugIds = @((Get-PropertyValue -Source $linkEntry -Name 'sourceAssociatedBugIds' -DefaultValue @()) | ForEach-Object {
                        ConvertTo-IntIfPossible -Value $_
                    } | Where-Object { $null -ne $_ })
                TargetPlanId           = $planResolution.Candidate.targetId
                TargetPlanTitle        = $planResolution.Candidate.title
                TargetSuiteId          = $suiteResolution.Candidate.targetId
                TargetSuiteTitle       = $suiteResolution.Candidate.title
                TargetTestCaseId       = $testCaseResolution.Candidate.targetId
                TargetTestCaseTitle    = $testCaseResolution.Candidate.title
                TargetPointId          = $targetPointId
                TargetConfigurationId  = $targetConfiguration.Id
                TargetConfigurationName = $targetConfiguration.Name
                TargetAssociatedBugIds = @()
            })
    }

    $resolvedResultArray = $resolvedResults.ToArray()
    $targetPlanIds = @($resolvedResultArray | ForEach-Object TargetPlanId | Sort-Object -Unique)
    if ($targetPlanIds.Count -gt 1) {
        $additionalReasons.Add(
            "Resolved target test points span multiple target plans: $($targetPlanIds -join ', ')."
        )
    }

    $coreUnresolvedCount = @($unresolvedReferences.ToArray() | Where-Object isCore).Count
    $isLinkable = $coreUnresolvedCount -eq 0 -and
        $additionalReasons.Count -eq 0 -and
        $resolvedResultArray.Count -eq $SourceResults.Count -and
        $targetPlanIds.Count -eq 1

    if ($isLinkable) {
        foreach ($resolvedResult in $resolvedResultArray) {
            $targetBugIds = [Collections.Generic.List[int]]::new()
            foreach ($sourceBugId in @($resolvedResult.SourceAssociatedBugIds)) {
                $bugResolution = Resolve-AdoReflectedWorkItem `
                    -Index $ReflectedIndex `
                    -SourceId $sourceBugId `
                    -ExpectedWorkItemType 'Bug'
                if ($bugResolution.Resolved) {
                    $targetBugIds.Add($bugResolution.Candidate.targetId)
                }
                else {
                    $unresolvedReferences.Add([pscustomobject]@{
                            resultId      = $resolvedResult.SourceResultId
                            referenceType = 'Bug'
                            sourceId      = $sourceBugId
                            isCore        = $false
                            reason        = $bugResolution.Reason
                        })
                }
            }
            $resolvedResult.TargetAssociatedBugIds = @($targetBugIds | Sort-Object -Unique)
        }
    }

    return [pscustomobject]@{
        IsLinkable           = $isLinkable
        TargetPlanId         = if ($targetPlanIds.Count -eq 1) { $targetPlanIds[0] } else { $null }
        TargetSuiteIds       = @($resolvedResultArray | ForEach-Object TargetSuiteId | Sort-Object -Unique)
        TargetPointIds       = @($resolvedResultArray | ForEach-Object TargetPointId | Sort-Object -Unique)
        ResolvedResults      = $resolvedResultArray
        AdditionalReasons    = $additionalReasons.ToArray()
        UnresolvedReferenceCount = $unresolvedReferences.Count + $additionalReasons.Count
        UnresolvedReferences = $unresolvedReferences.ToArray()
        Reason               = Get-AdoLinkResolutionReason `
            -UnresolvedReferences $unresolvedReferences.ToArray() `
            -AdditionalReasons $additionalReasons.ToArray()
    }
}

function Wait-AdoRunResults {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [int]$RunId,

        [Parameter(Mandatory)]
        [int]$ExpectedResultCount
    )

    $results = @()
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $results = @(Get-AdoTestResults -Context $Context -RunId $RunId)
        if ($results.Count -ge $ExpectedResultCount) {
            return $results
        }
        Start-Sleep -Seconds 1
    }

    return $results
}

function New-AdoPartialImportException {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [int]$TargetRunId
    )

    $exception = [InvalidOperationException]::new($ErrorRecord.Exception.Message, $ErrorRecord.Exception)
    foreach ($key in $ErrorRecord.Exception.Data.Keys) {
        $exception.Data[$key] = $ErrorRecord.Exception.Data[$key]
    }
    $exception.Data['TargetRunId'] = $TargetRunId
    return $exception
}

function Import-AdoUnplannedRun {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$EncodedProject,

        [Parameter(Mandatory)]
        [string]$RunPath,

        [Parameter(Mandatory)]
        [object]$SourceRun,

        [Parameter(Mandatory)]
        [object[]]$SourceResults
    )

    $requiresAutomatedImport = @($SourceResults | Where-Object {
            [string]::IsNullOrWhiteSpace(
                [string](Get-PropertyValue -Source $_ -Name 'automatedTestName')
            )
        }).Count -gt 0

    $newRun = Invoke-AdoRestMethod `
        -Context $Context `
        -Method POST `
        -Path "$EncodedProject/_apis/test/runs?api-version=$($script:ApiVersion)" `
        -Body (New-RunCreatePayload -Run $SourceRun -ForceAutomated:$requiresAutomatedImport)

    try {
        $resultMap = [Collections.Generic.List[object]]::new()
        for ($offset = 0; $offset -lt $SourceResults.Count; $offset += 200) {
            $lastIndex = [Math]::Min($offset + 199, $SourceResults.Count - 1)
            $sourceBatch = @($SourceResults[$offset..$lastIndex])
            $payloadBatch = @($sourceBatch | ForEach-Object { New-ResultCreatePayload -Result $_ })
            $createdResponse = Invoke-AdoRestMethod `
                -Context $Context `
                -Method POST `
                -Path "$EncodedProject/_apis/test/Runs/$($newRun.id)/results?api-version=$($script:ApiVersion)" `
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

        $runAttachmentDirectory = Join-Path $RunPath 'attachments\run'
        if (Test-Path -LiteralPath $runAttachmentDirectory -PathType Container) {
            Import-AttachmentDirectory `
                -Context $Context `
                -Directory $runAttachmentDirectory `
                -ApiPath "$EncodedProject/_apis/test/runs/$($newRun.id)/attachments?api-version=$($script:ApiVersion)"
        }

        foreach ($mappedResult in $resultMap) {
            $resultAttachmentDirectory = Join-Path $RunPath "attachments\results\$($mappedResult.sourceResultId)"
            if (-not (Test-Path -LiteralPath $resultAttachmentDirectory -PathType Container)) {
                continue
            }

            Import-AttachmentDirectory `
                -Context $Context `
                -Directory $resultAttachmentDirectory `
                -ApiPath "$EncodedProject/_apis/test/Runs/$($newRun.id)/Results/$($mappedResult.targetResultId)/attachments?api-version=$($script:ApiVersion)"
        }

        Complete-AdoRun `
            -Context $Context `
            -EncodedProject $EncodedProject `
            -RunId $newRun.id `
            -SourceRun $SourceRun

        return [pscustomobject]@{
            TargetRun      = $newRun
            ResultMap      = $resultMap.ToArray()
            TargetPointIds = @()
        }
    }
    catch {
        throw (New-AdoPartialImportException -ErrorRecord $_ -TargetRunId $newRun.id)
    }
}

function Import-AdoPlannedRun {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$EncodedProject,

        [Parameter(Mandatory)]
        [string]$RunPath,

        [Parameter(Mandatory)]
        [object]$SourceRun,

        [Parameter(Mandatory)]
        [object[]]$SourceResults,

        [Parameter(Mandatory)]
        [object]$LinkResolution
    )

    $targetPointIds = @($LinkResolution.ResolvedResults | ForEach-Object TargetPointId)
    $newRun = Invoke-AdoRestMethod `
        -Context $Context `
        -Method POST `
        -Path "$EncodedProject/_apis/test/runs?api-version=$($script:ApiVersion)" `
        -Body (New-RunCreatePayload -Run $SourceRun -PlanId $LinkResolution.TargetPlanId -PointIds $targetPointIds)

    try {
        $generatedResults = @(Wait-AdoRunResults `
                -Context $Context `
                -RunId $newRun.id `
                -ExpectedResultCount $targetPointIds.Count)
        if ($generatedResults.Count -lt $targetPointIds.Count) {
            throw "Azure DevOps generated $($generatedResults.Count) result(s) for $($targetPointIds.Count) planned point(s)."
        }

    $generatedResultsByPointId = @{}
    foreach ($generatedResult in $generatedResults) {
        $generatedPointId = ConvertTo-IntIfPossible -Value (
            Get-PropertyValue -Source (Get-PropertyValue -Source $generatedResult -Name 'testPoint') -Name 'id'
        )
        if ($null -eq $generatedPointId) {
            continue
        }

        if (-not $generatedResultsByPointId.ContainsKey("$generatedPointId")) {
            $generatedResultsByPointId["$generatedPointId"] = [Collections.Generic.List[object]]::new()
        }
        $generatedResultsByPointId["$generatedPointId"].Add($generatedResult)
    }

    $sourceResultsById = @{}
    foreach ($sourceResult in $SourceResults) {
        $sourceResultsById[[string](Get-PropertyValue -Source $sourceResult -Name 'id')] = $sourceResult
    }

    $resultMap = [Collections.Generic.List[object]]::new()
    $updatePayloads = [Collections.Generic.List[object]]::new()
    foreach ($resolvedResult in @($LinkResolution.ResolvedResults)) {
        $generatedCandidates = @(if ($generatedResultsByPointId.ContainsKey("$($resolvedResult.TargetPointId)")) {
                $generatedResultsByPointId["$($resolvedResult.TargetPointId)"]
            } else {
                @()
            })

        if ($generatedCandidates.Count -eq 0) {
            throw "No generated result remained for target test point $($resolvedResult.TargetPointId)."
        }

        $generatedResult = $generatedCandidates[0]
        $generatedResultsByPointId["$($resolvedResult.TargetPointId)"].RemoveAt(0)
        $targetResultId = ConvertTo-IntIfPossible -Value (Get-PropertyValue -Source $generatedResult -Name 'id')
        if ($null -eq $targetResultId) {
            throw "A generated result for target test point $($resolvedResult.TargetPointId) did not include an id."
        }

        $sourceResult = $sourceResultsById["$($resolvedResult.SourceResultId)"]
        if ($null -eq $sourceResult) {
            throw "Source result $($resolvedResult.SourceResultId) was not found while correlating planned test results."
        }

        $updatePayloads.Add(
            (New-ResultUpdatePayload `
                -Result $sourceResult `
                -TargetResultId $targetResultId `
                -AssociatedBugIds $resolvedResult.TargetAssociatedBugIds)
        )
        $resultMap.Add([pscustomobject]@{
                sourceResultId       = $resolvedResult.SourceResultId
                targetResultId       = $targetResultId
                targetPointId        = $resolvedResult.TargetPointId
                targetSuiteId        = $resolvedResult.TargetSuiteId
                targetTestCaseId     = $resolvedResult.TargetTestCaseId
                targetAssociatedBugs = $resolvedResult.TargetAssociatedBugIds
            })
    }

    $updatePayloadArray = $updatePayloads.ToArray()
    for ($offset = 0; $offset -lt $updatePayloadArray.Count; $offset += 200) {
        $lastIndex = [Math]::Min($offset + 199, $updatePayloadArray.Count - 1)
        $payloadBatch = @($updatePayloadArray[$offset..$lastIndex])
        $null = Invoke-AdoRestMethod `
            -Context $Context `
            -Method PATCH `
            -Path "$EncodedProject/_apis/test/Runs/$($newRun.id)/results?api-version=$($script:ApiVersion)" `
            -Body $payloadBatch
    }

    $runAttachmentDirectory = Join-Path $RunPath 'attachments\run'
    if (Test-Path -LiteralPath $runAttachmentDirectory -PathType Container) {
        Import-AttachmentDirectory `
            -Context $Context `
            -Directory $runAttachmentDirectory `
            -ApiPath "$EncodedProject/_apis/test/runs/$($newRun.id)/attachments?api-version=$($script:ApiVersion)"
    }

    foreach ($mappedResult in $resultMap) {
        $resultAttachmentDirectory = Join-Path $RunPath "attachments\results\$($mappedResult.sourceResultId)"
        if (-not (Test-Path -LiteralPath $resultAttachmentDirectory -PathType Container)) {
            continue
        }

        Import-AttachmentDirectory `
            -Context $Context `
            -Directory $resultAttachmentDirectory `
            -ApiPath "$EncodedProject/_apis/test/Runs/$($newRun.id)/Results/$($mappedResult.targetResultId)/attachments?api-version=$($script:ApiVersion)"
    }

    Complete-AdoRun `
        -Context $Context `
        -EncodedProject $EncodedProject `
        -RunId $newRun.id `
        -SourceRun $SourceRun

        return [pscustomobject]@{
            TargetRun      = $newRun
            ResultMap      = $resultMap.ToArray()
            TargetPointIds = $targetPointIds
        }
    }
    catch {
        throw (New-AdoPartialImportException -ErrorRecord $_ -TargetRunId $newRun.id)
    }
}

function Import-AdoTestHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,

        [Parameter(Mandatory)]
        [string]$ExportPath,

        [ValidateSet('Disabled', 'Prefer', 'Require')]
        [string]$LinkMode = 'Prefer',

        [string]$ReflectedWorkItemIdField = 'Custom.ReflectedWorkItemId'
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
        importedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
        sourceOrganization     = $manifest.sourceOrganization
        sourceProject          = $manifest.sourceProject
        targetOrganization     = $Context.OrganizationUrl
        targetProject          = $Context.Project
        linkMode               = $LinkMode
        reflectedWorkItemField = if ($LinkMode -eq 'Disabled') { $null } else { $ReflectedWorkItemIdField }
        runs                   = [Collections.Generic.List[object]]::new()
    }
    $reportEntries = [Collections.Generic.List[object]]::new()
    $reportTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $importReportJsonPath = Join-Path $resolvedExportPath "import-report-$reportTimestamp.json"
    $importReportCsvPath = Join-Path $resolvedExportPath "import-report-$reportTimestamp.csv"
    $targetPointCache = @{}
    $linkFallbackReason = $null
    $reflectedIndex = $null

    if ($LinkMode -ne 'Disabled') {
        if (-not (Test-AdoFieldReferenceName -FieldName $ReflectedWorkItemIdField)) {
            throw "Reflected work item field '$ReflectedWorkItemIdField' is invalid. Use a field reference name such as Custom.ReflectedWorkItemId."
        }

        $indexState = Get-AdoReflectedWorkItemIndex `
            -Context $Context `
            -ReflectedWorkItemIdField $ReflectedWorkItemIdField `
            -SourceOrganization $manifest.sourceOrganization `
            -SourceProject $manifest.sourceProject
        if (-not $indexState.Available) {
            Write-AdoLog `
                -Level Warning `
                -Message 'Reflected work item field unavailable for planned linking.' `
                -Context @{
                    linkMode = $LinkMode
                    field    = $ReflectedWorkItemIdField
                    reason   = $indexState.Reason
                }

            if ($LinkMode -eq 'Require') {
                foreach ($manifestRun in @($manifest.runs)) {
                    $reportEntries.Add(
                        (New-AdoImportReportEntry `
                            -Status 'UnresolvedLinks' `
                            -SourceRunId $manifestRun.sourceRunId `
                            -TargetRunId $null `
                            -Name $manifestRun.name `
                            -SourceResultCount (Get-PropertyValue -Source $manifestRun -Name 'resultCount') `
                            -ProcessedResultCount 0 `
                            -LinkMode $LinkMode `
                            -LinkStatus 'UnresolvedLinks' `
                            -TargetPlanId $null `
                            -TargetSuiteIds @() `
                            -UnresolvedReferenceCount 1 `
                            -Reason $indexState.Reason)
                    )
                }

                Save-AdoRunReport `
                    -Entries $reportEntries.ToArray() `
                    -Summary @{
                        totalRunCount          = $manifest.runCount
                        importedRunCount       = 0
                        failedRunCount         = 0
                        unresolvedLinkRunCount = $manifest.runCount
                        notAttemptedRunCount   = 0
                    } `
                    -JsonPath $importReportJsonPath `
                    -CsvPath $importReportCsvPath
                Write-Host "Import report: $importReportJsonPath" -ForegroundColor DarkGray
                throw $indexState.Reason
            }

            $linkFallbackReason = $indexState.Reason
        }
        else {
            $reflectedIndex = $indexState.Index
        }
    }

    $current = 0
    foreach ($manifestRun in $manifest.runs) {
        $current++
        Write-Step "Importing run $current/$($manifest.runCount): ID $($manifestRun.sourceRunId) - $($manifestRun.name)"
        $newRun = $null
        $sourceRun = $null
        $sourceResults = @()
        $linkStatus = if ($LinkMode -eq 'Disabled') { 'Disabled' } else { $null }
        $targetPlanId = $null
        $targetSuiteIds = @()
        $targetPointIds = @()
        $unresolvedReferences = @()
        $unresolvedReferenceCount = 0
        $reportReason = $null

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

            $importOutcome = $null
            if ($LinkMode -eq 'Disabled') {
                $importOutcome = Import-AdoUnplannedRun `
                    -Context $Context `
                    -EncodedProject $encodedProject `
                    -RunPath $runPath `
                    -SourceRun $sourceRun `
                    -SourceResults $sourceResults
            }
            elseif (-not [string]::IsNullOrWhiteSpace($linkFallbackReason)) {
                $linkStatus = 'UnplannedFallback'
                $reportReason = $linkFallbackReason
                $importOutcome = Import-AdoUnplannedRun `
                    -Context $Context `
                    -EncodedProject $encodedProject `
                    -RunPath $runPath `
                    -SourceRun $sourceRun `
                    -SourceResults $sourceResults
            }
            else {
                $linkResolution = Resolve-AdoPlannedRunLinks `
                    -Context $Context `
                    -Manifest $manifest `
                    -RunPath $runPath `
                    -SourceResults $sourceResults `
                    -ReflectedIndex $reflectedIndex `
                    -PointCache $targetPointCache
                $targetPlanId = $linkResolution.TargetPlanId
                $targetSuiteIds = @($linkResolution.TargetSuiteIds)
                $targetPointIds = @($linkResolution.TargetPointIds)
                $unresolvedReferences = @($linkResolution.UnresolvedReferences)
                $unresolvedReferenceCount = $linkResolution.UnresolvedReferenceCount
                $reportReason = $linkResolution.Reason

                if ($linkResolution.IsLinkable) {
                    $linkStatus = 'PlannedLinked'
                    $importOutcome = Import-AdoPlannedRun `
                        -Context $Context `
                        -EncodedProject $encodedProject `
                        -RunPath $runPath `
                        -SourceRun $sourceRun `
                        -SourceResults $sourceResults `
                        -LinkResolution $linkResolution
                    $targetPointIds = @($importOutcome.TargetPointIds)
                }
                elseif ($LinkMode -eq 'Prefer') {
                    $linkStatus = 'UnplannedFallback'
                    $importOutcome = Import-AdoUnplannedRun `
                        -Context $Context `
                        -EncodedProject $encodedProject `
                        -RunPath $runPath `
                        -SourceRun $sourceRun `
                        -SourceResults $sourceResults
                }
                else {
                    $linkStatus = 'UnresolvedLinks'
                    $migrationMap.runs.Add([pscustomobject]@{
                            sourceRunId              = $sourceRun.id
                            targetRunId              = $null
                            linkMode                 = $LinkMode
                            linkStatus               = $linkStatus
                            targetPlanId             = $targetPlanId
                            targetSuiteIds           = $targetSuiteIds
                            targetPointIds           = $targetPointIds
                            unresolvedReferenceCount = $unresolvedReferenceCount
                            unresolvedReferences     = $unresolvedReferences
                            reason                   = $reportReason
                            results                  = @()
                        })
                    $reportEntries.Add(
                        (New-AdoImportReportEntry `
                            -Status 'UnresolvedLinks' `
                            -SourceRunId $sourceRun.id `
                            -TargetRunId $null `
                            -Name $manifestRun.name `
                            -SourceResultCount $sourceResults.Count `
                            -ProcessedResultCount 0 `
                            -LinkMode $LinkMode `
                            -LinkStatus $linkStatus `
                            -TargetPlanId $targetPlanId `
                            -TargetSuiteIds $targetSuiteIds `
                            -UnresolvedReferenceCount $unresolvedReferenceCount `
                            -Reason $reportReason)
                    )
                    Write-AdoLog `
                        -Level Info `
                        -Message 'Run skipped because required planned links could not be resolved.' `
                        -Context @{
                            sourceRunId              = $sourceRun.id
                            linkMode                 = $LinkMode
                            targetPlanId             = $targetPlanId
                            unresolvedReferenceCount = $unresolvedReferenceCount
                            reason                   = $reportReason
                        }
                    continue
                }
            }

            $newRun = $importOutcome.TargetRun
            $migrationMap.runs.Add([pscustomobject]@{
                    sourceRunId              = $sourceRun.id
                    targetRunId              = $newRun.id
                    linkMode                 = $LinkMode
                    linkStatus               = $linkStatus
                    targetPlanId             = $targetPlanId
                    targetSuiteIds           = $targetSuiteIds
                    targetPointIds           = $targetPointIds
                    unresolvedReferenceCount = $unresolvedReferenceCount
                    unresolvedReferences     = $unresolvedReferences
                    reason                   = $reportReason
                    results                  = $importOutcome.ResultMap
                })
            $reportEntries.Add(
                (New-AdoImportReportEntry `
                    -Status 'Imported' `
                    -SourceRunId $sourceRun.id `
                    -TargetRunId $newRun.id `
                    -Name $manifestRun.name `
                    -SourceResultCount $sourceResults.Count `
                    -ProcessedResultCount $importOutcome.ResultMap.Count `
                    -LinkMode $LinkMode `
                    -LinkStatus $linkStatus `
                    -TargetPlanId $targetPlanId `
                    -TargetSuiteIds $targetSuiteIds `
                    -UnresolvedReferenceCount $unresolvedReferenceCount `
                    -Reason $reportReason)
            )
            Write-AdoLog `
                -Level Info `
                -Message 'Run imported successfully.' `
                -Context @{
                    sourceRunId              = $sourceRun.id
                    targetRunId              = $newRun.id
                    linkMode                 = $LinkMode
                    linkStatus               = $linkStatus
                    targetPlanId             = $targetPlanId
                    unresolvedReferenceCount = $unresolvedReferenceCount
                }
        }
        catch {
            $partialTargetRunId = $null
            if ($newRun) {
                $partialTargetRunId = $newRun.id
            }
            elseif ($_.Exception.Data.Contains('TargetRunId')) {
                $partialTargetRunId = ConvertTo-IntIfPossible -Value $_.Exception.Data['TargetRunId']
            }

            $reportEntries.Add(
                (New-AdoImportReportEntry `
                    -Status $(if ($null -ne $partialTargetRunId) { 'FailedPartial' } else { 'Failed' }) `
                    -SourceRunId $(if ($null -ne $sourceRun) { $sourceRun.id } else { $manifestRun.sourceRunId }) `
                    -TargetRunId $partialTargetRunId `
                    -Name $manifestRun.name `
                    -SourceResultCount $(if ($sourceResults.Count -gt 0) { $sourceResults.Count } else { Get-PropertyValue -Source $manifestRun -Name 'resultCount' }) `
                    -ProcessedResultCount 0 `
                    -LinkMode $LinkMode `
                    -LinkStatus $linkStatus `
                    -TargetPlanId $targetPlanId `
                    -TargetSuiteIds $targetSuiteIds `
                    -UnresolvedReferenceCount $(if ($unresolvedReferenceCount -gt 0) { $unresolvedReferenceCount } else { $null }) `
                    -Reason $_.Exception.Message)
            )

            foreach ($remainingRun in @($manifest.runs | Select-Object -Skip $current)) {
                $reportEntries.Add(
                    (New-AdoImportReportEntry `
                        -Status 'NotAttempted' `
                        -SourceRunId $remainingRun.sourceRunId `
                        -TargetRunId $null `
                        -Name $remainingRun.name `
                        -SourceResultCount $remainingRun.resultCount `
                        -ProcessedResultCount 0 `
                        -LinkMode $LinkMode `
                        -LinkStatus $null `
                        -TargetPlanId $null `
                        -TargetSuiteIds @() `
                        -UnresolvedReferenceCount $null `
                        -Reason 'Import stopped after a previous run failed.')
                )
            }

            Save-AdoRunReport `
                -Entries $reportEntries.ToArray() `
                -Summary @{
                    totalRunCount          = $manifest.runCount
                    importedRunCount       = @($reportEntries | Where-Object status -eq 'Imported').Count
                    failedRunCount         = @($reportEntries | Where-Object status -Like 'Failed*').Count
                    unresolvedLinkRunCount = @($reportEntries | Where-Object status -eq 'UnresolvedLinks').Count
                    notAttemptedRunCount   = @($reportEntries | Where-Object status -eq 'NotAttempted').Count
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
            totalRunCount          = $manifest.runCount
            importedRunCount       = @($reportEntries | Where-Object status -eq 'Imported').Count
            failedRunCount         = @($reportEntries | Where-Object status -Like 'Failed*').Count
            unresolvedLinkRunCount = @($reportEntries | Where-Object status -eq 'UnresolvedLinks').Count
            notAttemptedRunCount   = @($reportEntries | Where-Object status -eq 'NotAttempted').Count
        } `
        -JsonPath $importReportJsonPath `
        -CsvPath $importReportCsvPath
    Write-Host ''
    Write-Host 'Import summary' -ForegroundColor Cyan
    Write-Host "  Imported:   $(@($reportEntries | Where-Object status -eq 'Imported').Count)"
    Write-Host "  Unresolved: $(@($reportEntries | Where-Object status -eq 'UnresolvedLinks').Count)"
    Write-Host "  Failed:     $(@($reportEntries | Where-Object status -Like 'Failed*').Count)"
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
