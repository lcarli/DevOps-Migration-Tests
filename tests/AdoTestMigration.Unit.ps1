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
    $plannedOutcome = Import-AdoPlannedRun `
        -Context ([pscustomobject]@{}) `
        -EncodedProject 'Target' `
        -RunPath (Join-Path $PSScriptRoot '__missing-run__') `
        -SourceRun ([pscustomobject]@{}) `
        -SourceResults $duplicateSourceResults `
        -LinkResolution $duplicatePointResolution

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
            -LinkResolution $duplicatePointResolution
        throw 'Expected the simulated planned import failure.'
    }
    catch {
        Assert-Equal -Actual $_.Exception.Data['TargetRunId'] -Expected 900 -Message 'Partial import failures should retain the created target run ID.'
    }
}

Write-Host 'AdoTestMigration unit tests passed.' -ForegroundColor Green
