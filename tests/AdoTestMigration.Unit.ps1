#requires -Version 7.2

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\AdoTestMigration.psm1'
Import-Module $modulePath -Force
$module = Get-Module AdoTestMigration
if (-not $module) {
    throw 'AdoTestMigration module did not load.'
}

& $module {
    Set-StrictMode -Version Latest

    function Assert-Equal {
        param(
            [AllowNull()]
            [object]$Actual,

            [AllowNull()]
            [object]$Expected,

            [Parameter(Mandatory)]
            [string]$Message
        )

        if ($Actual -is [array] -or $Expected -is [array]) {
            $actualJson = ConvertTo-Json -InputObject $Actual -Compress -Depth 10
            $expectedJson = ConvertTo-Json -InputObject $Expected -Compress -Depth 10
            if ($actualJson -ne $expectedJson) {
                throw "$Message Expected: $expectedJson Actual: $actualJson"
            }
            return
        }

        if ($Actual -ne $Expected) {
            throw "$Message Expected: $Expected Actual: $Actual"
        }
    }

    function Assert-True {
        param(
            [Parameter(Mandatory)]
            [bool]$Condition,

            [Parameter(Mandatory)]
            [string]$Message
        )

        if (-not $Condition) {
            throw $Message
        }
    }

    function Assert-False {
        param(
            [Parameter(Mandatory)]
            [bool]$Condition,

            [Parameter(Mandatory)]
            [string]$Message
        )

        if ($Condition) {
            throw $Message
        }
    }

    Assert-Equal -Actual (Get-AdoReflectedSourceId -Value '123') -Expected 123 -Message 'Should parse raw reflected IDs.'
    Assert-Equal -Actual (Get-AdoReflectedSourceId -Value 'https://dev.azure.com/contoso/Source/_workitems/edit/456') -Expected 456 -Message 'Should parse trailing reflected IDs from URLs.'
    Assert-Equal -Actual (Get-AdoReflectedSourceId -Value 'contoso\Source\789') -Expected 789 -Message 'Should parse trailing reflected IDs from backslash-delimited values.'
    Assert-Equal -Actual (Get-AdoReflectedSourceId -Value 'source-789') -Expected $null -Message 'Should reject reflected values without a supported source ID shape.'

    Assert-True -Condition (Test-AdoFieldReferenceName -FieldName 'Custom.ReflectedWorkItemId') -Message 'Valid reflected field names should pass.'
    Assert-False -Condition (Test-AdoFieldReferenceName -FieldName 'Custom.ReflectedWorkItemId]; DROP TABLE WorkItems; --') -Message 'Invalid reflected field names should be rejected.'

    $singlePlanIndex = @{
        'test plan|42' = [Collections.Generic.List[object]]::new()
    }
    $singlePlanIndex['test plan|42'].Add([pscustomobject]@{
            targetId             = 200
            workItemType         = 'Test Plan'
            title                = 'Target Plan'
            reflectedValue       = '42'
            sourceId             = 42
            matchesSourceContext = $false
        })
    $singlePlanResolution = Resolve-AdoReflectedWorkItem -Index $singlePlanIndex -SourceId 42 -ExpectedWorkItemType 'Test Plan'
    Assert-True -Condition $singlePlanResolution.Resolved -Message 'A single reflected candidate should resolve.'
    Assert-Equal -Actual $singlePlanResolution.Candidate.targetId -Expected 200 -Message 'Resolved plan should use the single target candidate.'

    $contextPreferredIndex = @{
        'test case|88' = [Collections.Generic.List[object]]::new()
    }
    $contextPreferredIndex['test case|88'].Add([pscustomobject]@{
            targetId             = 300
            workItemType         = 'Test Case'
            title                = 'Case A'
            reflectedValue       = '88'
            sourceId             = 88
            matchesSourceContext = $false
        })
    $contextPreferredIndex['test case|88'].Add([pscustomobject]@{
            targetId             = 301
            workItemType         = 'Test Case'
            title                = 'Case B'
            reflectedValue       = 'https://dev.azure.com/contoso/source/_workitems/edit/88'
            sourceId             = 88
            matchesSourceContext = $true
        })
    $contextPreferredResolution = Resolve-AdoReflectedWorkItem -Index $contextPreferredIndex -SourceId 88 -ExpectedWorkItemType 'Test Case'
    Assert-True -Condition $contextPreferredResolution.Resolved -Message 'A source-context match should win when multiple reflected candidates exist.'
    Assert-Equal -Actual $contextPreferredResolution.Candidate.targetId -Expected 301 -Message 'The source-context candidate should be preferred.'

    $ambiguousIndex = @{
        'bug|99' = [Collections.Generic.List[object]]::new()
    }
    $ambiguousIndex['bug|99'].Add([pscustomobject]@{
            targetId             = 400
            workItemType         = 'Bug'
            title                = 'Bug A'
            reflectedValue       = '99'
            sourceId             = 99
            matchesSourceContext = $false
        })
    $ambiguousIndex['bug|99'].Add([pscustomobject]@{
            targetId             = 401
            workItemType         = 'Bug'
            title                = 'Bug B'
            reflectedValue       = '99'
            sourceId             = 99
            matchesSourceContext = $false
        })
    $ambiguousResolution = Resolve-AdoReflectedWorkItem -Index $ambiguousIndex -SourceId 99 -ExpectedWorkItemType 'Bug'
    Assert-False -Condition $ambiguousResolution.Resolved -Message 'Ambiguous reflected candidates must not be guessed.'
    Assert-Equal -Actual $ambiguousResolution.Status -Expected 'Ambiguous' -Message 'Ambiguous reflected matches should report their status.'

    $points = @(
        [pscustomobject]@{
            id           = 11
            configuration = [pscustomobject]@{ id = 1; name = 'Chrome' }
        },
        [pscustomobject]@{
            id           = 12
            configuration = [pscustomobject]@{ id = 2; name = 'Firefox' }
        }
    )
    $configMatchedPoint = Resolve-AdoTargetTestPoint -Points $points -SourceConfigurationName 'firefox'
    Assert-True -Condition $configMatchedPoint.Resolved -Message 'Configuration names should match case-insensitively.'
    Assert-Equal -Actual $configMatchedPoint.Candidate.id -Expected 12 -Message 'The matching target point should be returned.'

    $singlePoint = @(
        [pscustomobject]@{
            id           = 21
            configuration = [pscustomobject]@{ id = 3; name = 'Linux' }
        }
    )
    $singlePointResolution = Resolve-AdoTargetTestPoint -Points $singlePoint -SourceConfigurationName $null
    Assert-True -Condition $singlePointResolution.Resolved -Message 'A single target point should resolve even when the source configuration name is missing.'
    Assert-Equal -Actual $singlePointResolution.Candidate.id -Expected 21 -Message 'The only target point should be selected.'

    $missingConfigResolution = Resolve-AdoTargetTestPoint -Points $points -SourceConfigurationName $null
    Assert-False -Condition $missingConfigResolution.Resolved -Message 'Multiple target points without a source configuration name should remain unresolved.'

    $missingLinksResolution = Resolve-AdoPlannedRunLinks `
        -Context ([pscustomobject]@{}) `
        -Manifest ([pscustomobject]@{}) `
        -RunPath (Join-Path $PSScriptRoot '__missing-links__') `
        -SourceResults @([pscustomobject]@{ id = 100 }) `
        -ReflectedIndex @{} `
        -PointCache @{}
    Assert-False -Condition $missingLinksResolution.IsLinkable -Message 'A run without links.json should not be linkable.'
    Assert-Equal -Actual $missingLinksResolution.UnresolvedReferenceCount -Expected 1 -Message 'A missing links.json file should report one unresolved reference.'
    Assert-Equal -Actual $missingLinksResolution.AdditionalReasons.Count -Expected 0 -Message 'A missing links.json file should return an empty additional-reasons collection.'

    $missingOutcomePayload = New-ResultCreatePayload -Result ([pscustomobject]@{ id = 200 })
    Assert-Equal -Actual $missingOutcomePayload.outcome -Expected 'Unspecified' -Message 'A source result without outcome should use the Azure DevOps Unspecified outcome.'

    $blankOutcomePayload = New-ResultCreatePayload -Result ([pscustomobject]@{ id = 201; outcome = '' })
    Assert-Equal -Actual $blankOutcomePayload.outcome -Expected 'Unspecified' -Message 'A blank source outcome should use the Azure DevOps Unspecified outcome.'

    $iterationPayload = New-ResultUpdatePayload `
        -Result ([pscustomobject]@{
                id               = 202
                iterationDetails = @(
                    [pscustomobject]@{
                        id            = 1
                        actionResults = @([pscustomobject]@{ actionPath = '00000002'; outcome = 'Passed' })
                    }
                )
            }) `
        -TargetResultId 302 `
        -AssociatedBugIds @()
    Assert-Equal -Actual $iterationPayload.iterationDetails[0].actionResults[0].actionPath -Expected '00000002' -Message 'Manual iteration and action result metadata should be recreated before step attachments are uploaded.'

    Assert-Equal -Actual (Get-AdoOrganizationName -OrganizationUrl 'https://dev.azure.com/contoso') -Expected 'contoso' -Message 'Organization names should be parsed from dev.azure.com URLs.'
    Assert-Equal -Actual (Get-AdoOrganizationName -OrganizationUrl 'https://contoso.visualstudio.com') -Expected 'contoso' -Message 'Organization names should be parsed from visualstudio.com URLs.'

    $sourceIdentity = [pscustomobject]@{
        displayName = 'Original User'
        uniqueName  = 'original.user@contoso.com'
    }
    function Invoke-AdoIdentityRestMethod {
        param($Context, $PrincipalName)
        return [pscustomobject]@{
            value = @(
                [pscustomobject]@{
                    id          = 'target-user-id'
                    displayName = 'Original User'
                    isActive    = $true
                    properties  = [pscustomobject]@{
                        Mail = [pscustomobject]@{ '$value' = 'original.user@contoso.com' }
                    }
                }
            )
        }
    }

    $identityResolution = Resolve-AdoTargetIdentity `
        -Context ([pscustomobject]@{ OrganizationUrl = 'https://dev.azure.com/contoso'; Headers = @{} }) `
        -SourceIdentity $sourceIdentity `
        -Cache @{}
    Assert-True -Condition $identityResolution.Resolved -Message 'An exact active target identity should resolve.'
    Assert-Equal -Actual $identityResolution.Status -Expected 'Mapped' -Message 'Resolved identities should report Mapped.'
    Assert-Equal -Actual $identityResolution.TargetId -Expected 'target-user-id' -Message 'The target identity ID should be retained.'

    $ownerPayload = New-RunCreatePayload `
        -Run ([pscustomobject]@{ id = 300; name = 'Owned run' }) `
        -OwnerResolution $identityResolution
    Assert-Equal -Actual $ownerPayload.owner.id -Expected 'target-user-id' -Message 'Run creation should use the resolved target owner ID.'
    Assert-True -Condition ($ownerPayload.comment -like '*Original User <original.user@contoso.com>*') -Message 'Run comments should retain the original owner identity.'

    $runnerPayload = New-ResultCreatePayload `
        -Result ([pscustomobject]@{ id = 301; outcome = 'Passed' }) `
        -RunByResolution $identityResolution
    Assert-Equal -Actual $runnerPayload.runBy.id -Expected 'target-user-id' -Message 'Result creation should use the resolved target runner ID.'
    Assert-True -Condition ($runnerPayload.comment -like '*Original runner: Original User <original.user@contoso.com>*') -Message 'Result comments should retain the original runner identity.'

    $runnerStatusMap = @([pscustomobject]@{ sourceResultId = 301; runByStatus = 'Mapped' })
    $failedRunnerResolution = $identityResolution.PSObject.Copy()
    $failedRunnerResolution.Status = 'ApplyFailed'
    Sync-AdoResultMapRunByStatuses `
        -ResultMap $runnerStatusMap `
        -IdentityMappings ([pscustomobject]@{ ResultRunBy = @{ '301' = $failedRunnerResolution } }) `
        -SourceResultIds @(301)
    Assert-Equal -Actual $runnerStatusMap[0].runByStatus -Expected 'ApplyFailed' -Message 'Result maps should reflect runner fallback status changes.'

    $notAppliedResolution = $identityResolution.PSObject.Copy()
    Confirm-AdoRunOwnerMapping `
        -Context ([pscustomobject]@{}) `
        -EncodedProject 'Target' `
        -TargetRun ([pscustomobject]@{ owner = [pscustomobject]@{ id = 'different-user-id' } }) `
        -OwnerResolution $notAppliedResolution
    Assert-Equal -Actual $notAppliedResolution.Status -Expected 'NotApplied' -Message 'A target run that ignores the requested owner should be reported.'

    $networkException = [InvalidOperationException]::new('Simulated network failure.')
    $networkErrorRecord = [System.Management.Automation.ErrorRecord]::new(
        $networkException,
        'NetworkFailure',
        [System.Management.Automation.ErrorCategory]::ConnectionError,
        $null
    )
    Assert-Equal -Actual (Get-AdoErrorMessage -ErrorRecord $networkErrorRecord) -Expected 'Simulated network failure.' -Message 'Errors without an HTTP response should preserve their original message.'
    $wrappedNetworkException = New-AdoRestException -ErrorRecord $networkErrorRecord -Method GET -Uri 'https://dev.azure.com/example'
    Assert-False -Condition $wrappedNetworkException.Data.Contains('StatusCode') -Message 'Errors without an HTTP response should not invent a status code.'

    $httpException = [InvalidOperationException]::new('Simulated HTTP failure.')
    $httpException | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 })
    $httpErrorRecord = [System.Management.Automation.ErrorRecord]::new(
        $httpException,
        'HttpFailure',
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null
    )
    $httpErrorRecord.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"Test run was not found."}')
    Assert-Equal -Actual (Get-AdoErrorMessage -ErrorRecord $httpErrorRecord) -Expected 'Azure DevOps returned HTTP 404. Test run was not found.' -Message 'HTTP errors should retain status and service details.'

    $attachmentTestPath = Join-Path $PSScriptRoot '__attachment-test__'
    if (Test-Path -LiteralPath $attachmentTestPath) {
        Remove-Item -LiteralPath $attachmentTestPath -Recurse -Force
    }
    $script:downloadedAttachmentPath = $null
    function Invoke-AdoRestMethod {
        param($Context, $Method, $Path, $Body)
        if ($Path -like '*/results/401?detailsToInclude=Iterations*') {
            return [pscustomobject]@{
                iterationDetails = @(
                    [pscustomobject]@{
                        id          = 1
                        attachments = @(
                            [pscustomobject]@{
                                id          = 402
                                name        = 'screenshot.png'
                                url         = 'https://example.test/attachment/402'
                                iterationId = 1
                                actionPath  = '00000001'
                            }
                        )
                    }
                )
            }
        }
        return [pscustomobject]@{ value = @() }
    }
    function Save-AdoBinary {
        param($Context, $Path, $Destination)
        $script:downloadedAttachmentPath = $Path
        Set-Content -LiteralPath $Destination -Value 'attachment' -Encoding utf8NoBOM
    }

    $attachmentSummary = Export-AdoAttachments `
        -Context ([pscustomobject]@{ Project = 'Target'; OrganizationUrl = 'https://dev.azure.com/contoso' }) `
        -RunId 400 `
        -RunPath $attachmentTestPath `
        -Results @(
            [pscustomobject]@{
                id = 401
            },
            [pscustomobject]@{
                id = 403
            }
        )
    $iterationMetadataPath = Join-Path $attachmentTestPath 'attachments\iterations\401\metadata.json'
    Assert-True -Condition (Test-Path -LiteralPath $iterationMetadataPath -PathType Leaf) -Message 'Manual test step attachment metadata should be exported.'
    $iterationMetadata = Get-Content -LiteralPath $iterationMetadataPath -Raw | ConvertFrom-Json
    Assert-Equal -Actual $iterationMetadata.actionPath -Expected '00000001' -Message 'Manual test step action paths should be preserved.'
    Assert-Equal -Actual $script:downloadedAttachmentPath -Expected 'https://vstmr.dev.azure.com/contoso/Target/_apis/testresults/runs/400/results/401/attachments/402?iterationId=1&api-version=7.1-preview.1' -Message 'Manual test step attachments should use the Test Results iteration download API.'
    Assert-Equal -Actual $attachmentSummary.IterationAttachmentCount -Expected 1 -Message 'Attachment summaries should include successfully downloaded iteration attachments across all results.'
    $emptyAttachmentSummary = Export-AdoAttachments `
        -Context ([pscustomobject]@{ Project = 'Target'; OrganizationUrl = 'https://dev.azure.com/contoso' }) `
        -RunId 404 `
        -RunPath $attachmentTestPath `
        -Results ([object[]]@())
    Assert-Equal -Actual $emptyAttachmentSummary.TotalAttachmentCount -Expected 0 -Message 'Runs without results should still return an empty attachment summary.'

    $script:attachmentUploadPaths = [Collections.Generic.List[string]]::new()
    function Add-AdoAttachment {
        param($Context, $Path, $FilePath, $Metadata)
        $script:attachmentUploadPaths.Add($Path)
        if ($Path -like '*iterationId=*') {
            throw 'Simulated unsupported step attachment API.'
        }
    }
    Import-IterationAttachmentDirectory `
        -Context ([pscustomobject]@{ OrganizationUrl = 'https://dev.azure.com/contoso' }) `
        -Directory (Join-Path $attachmentTestPath 'attachments\iterations\401') `
        -EncodedProject 'Target' `
        -TargetRunId 500 `
        -TargetResultId 501
    Assert-Equal -Actual $script:attachmentUploadPaths[0] -Expected 'https://vstmr.dev.azure.com/contoso/Target/_apis/testresults/runs/500/results/501/attachments?iterationId=1&actionPath=00000001&api-version=7.1-preview.1' -Message 'Manual test step attachments should first use the Test Results iteration API.'
    Assert-Equal -Actual $script:attachmentUploadPaths[1] -Expected 'Target/_apis/test/Runs/500/Results/501/attachments?api-version=7.1' -Message 'Unsupported step associations should fall back to a result-level attachment.'
    Remove-Item -LiteralPath $attachmentTestPath -Recurse -Force

    $script:capturedResultPath = $null
    function Invoke-AdoRestMethod {
        param($Context, $Method, $Path, $Body)
        $script:capturedResultPath = $Path
        return [pscustomobject]@{ value = @() }
    }

    $null = Get-AdoTestResults `
        -Context ([pscustomobject]@{ EncodedProject = 'Target'; Project = 'Target' }) `
        -RunId 123
    Assert-True `
        -Condition ($script:capturedResultPath -like '*detailsToInclude=WorkItems,Iterations,Point*') `
        -Message 'Result export should request Point details for planned correlation.'

    $script:failPlannedResultUpdate = $false
    $script:capturedPlannedCreateBody = $null
    function New-RunCreatePayload {
        param($Run, $PlanId, $PointIds)
        return [pscustomobject]@{
            plan     = [pscustomobject]@{ id = $PlanId }
            pointIds = @($PointIds)
        }
    }
    function Invoke-AdoRestMethod {
        param($Context, $Method, $Path, $Body)
        if ($Method -eq 'POST' -and $Path -like '*/_apis/test/runs?*') {
            $script:capturedPlannedCreateBody = $Body
            return [pscustomobject]@{ id = 900 }
        }
        if ($Method -eq 'PATCH' -and $script:failPlannedResultUpdate) {
            throw 'Simulated planned result update failure.'
        }
        return $null
    }
    function Wait-AdoRunResults {
        param($Context, $RunId, $ExpectedResultCount)
        return @(
            [pscustomobject]@{ id = 901; testPoint = [pscustomobject]@{ id = 55 } },
            [pscustomobject]@{ id = 902; testPoint = [pscustomobject]@{ id = 55 } }
        )
    }
    function New-ResultUpdatePayload {
        param($Result, $TargetResultId, $AssociatedBugIds)
        return [pscustomobject]@{ id = $TargetResultId }
    }
    function Complete-AdoRun {
        param($Context, $EncodedProject, $RunId, $SourceRun)
    }

    $duplicatePointResolution = [pscustomobject]@{
        TargetPlanId    = 77
        ResolvedResults = @(
            [pscustomobject]@{
                SourceResultId       = 101
                TargetPointId        = 55
                TargetSuiteId        = 66
                TargetTestCaseId     = 201
                TargetAssociatedBugIds = @()
            },
            [pscustomobject]@{
                SourceResultId       = 102
                TargetPointId        = 55
                TargetSuiteId        = 66
                TargetTestCaseId     = 201
                TargetAssociatedBugIds = @()
            }
        )
    }
    $duplicateSourceResults = @(
        [pscustomobject]@{ id = 101 },
        [pscustomobject]@{ id = 102 }
    )
    $notAvailableIdentity = [pscustomobject]@{
        SourceAvailable     = $false
        SourceDisplayName   = $null
        SourcePrincipalName = $null
        Resolved            = $false
        Status              = 'NotAvailable'
        TargetId            = $null
        TargetDisplayName   = $null
        Reason              = 'Not available in test data.'
    }
    $testIdentityMappings = [pscustomobject]@{
        Owner                    = $notAvailableIdentity.PSObject.Copy()
        ResultRunBy              = @{
            '101' = $notAvailableIdentity.PSObject.Copy()
            '102' = $notAvailableIdentity.PSObject.Copy()
        }
        MappedRunnerCount        = 0
        UnresolvedRunnerCount    = 0
    }
    $plannedOutcome = Import-AdoPlannedRun `
        -Context ([pscustomobject]@{}) `
        -EncodedProject 'Target' `
        -RunPath (Join-Path $PSScriptRoot '__missing-run__') `
        -SourceRun ([pscustomobject]@{}) `
        -SourceResults $duplicateSourceResults `
        -LinkResolution $duplicatePointResolution `
        -IdentityMappings $testIdentityMappings

    Assert-Equal -Actual $script:capturedPlannedCreateBody.pointIds -Expected @(55, 55) -Message 'Planned run creation should preserve repeated test points.'
    Assert-Equal -Actual $plannedOutcome.TargetPointIds -Expected @(55, 55) -Message 'The planned import outcome should preserve repeated test points.'
    Assert-Equal -Actual @($plannedOutcome.ResultMap | ForEach-Object targetResultId) -Expected @(901, 902) -Message 'Generated results should be consumed as a queue for repeated test points.'

    $script:failPlannedResultUpdate = $true
    try {
        $null = Import-AdoPlannedRun `
            -Context ([pscustomobject]@{}) `
            -EncodedProject 'Target' `
            -RunPath (Join-Path $PSScriptRoot '__missing-run__') `
            -SourceRun ([pscustomobject]@{}) `
            -SourceResults $duplicateSourceResults `
            -LinkResolution $duplicatePointResolution `
            -IdentityMappings $testIdentityMappings
        throw 'Expected the simulated planned import failure.'
    }
    catch {
        Assert-Equal -Actual $_.Exception.Data['TargetRunId'] -Expected 900 -Message 'Partial import failures should retain the created target run ID.'
    }
}

Write-Host 'AdoTestMigration unit tests passed.' -ForegroundColor Green
