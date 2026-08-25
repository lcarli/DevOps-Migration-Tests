# Azure DevOps Test History Migration

PowerShell utility that exports Test Runs, results, and attachments from an
Azure DevOps project and recreates them in another project or organization.

> Import creates new resources. IDs, audit data, identities, and references to
> Test Plans, Suites, builds, releases, and work items are not automatically
> preserved unless the target project contains an explicit reflected-ID mapping.

## Requirements

- PowerShell 7.2 or later.
- One of the following authentication methods:
  - Azure CLI authenticated as a user with Azure DevOps access; or
  - A PAT with `Test Management: Read` for export and
    `Test Management: Read & write` for import.
- Exporting with an Area Path filter requires `Work Items: Read`.
- Importing with planned run linking (`Prefer` or `Require`) also requires
  `Work Items: Read`.

## Usage

```powershell
Set-Location F:\repos\DevOps-Migration-Tests
.\Invoke-AdoTestMigration.ps1
```

The menu provides the following operations:

1. Export Test Run history.
2. Import a previous export.
3. Validate access.

The import flow prompts for a planned linking mode:

- `Prefer` (recommended/default): tries to recreate planned runs against mapped
  Test Plans, Suites, Test Cases, Test Points, and Bugs. If any core link
  cannot be resolved, the entire run falls back to the legacy unplanned path.
- `Require`: only creates a run when every core planned link resolves
  uniquely. Unresolved runs are reported as `UnresolvedLinks` and the import
  continues with the next run.
- `Disabled`: always uses the legacy unplanned import path.

When planned linking is enabled, the import also prompts for the reflected
target work item field. The default is `Custom.ReflectedWorkItemId`.

The export operation supports optional filters for the last updated date and
Area Path. The Area Path filter includes child areas and exports only results
associated with Test Cases under that path. Runs with no matching results are
skipped. Results without an associated Test Case are also skipped while the
filter is active. Enter the Area Path as displayed in Azure DevOps. The script
validates it against the project's classification tree and supports projects
whose current name differs from the Area Path root.

The date filter is applied locally to the `lastUpdatedDate` returned for each
run, starting at midnight UTC on the selected date. It does not filter by the
run start or completion date.

Use `-Verbose` for additional technical details:

```powershell
.\Invoke-AdoTestMigration.ps1 -Verbose
```

Every execution also creates a timestamped diagnostic log under `logs`. The log
records REST request URLs without credentials, request durations, the current
run ID, processing phase, filters, skipped runs, and complete error context.
PAT values and authorization headers are never written to the log.

Export and import operations also generate JSON and CSV reports with one row
per run. Export statuses include `Exported`, `SkippedNoTestCaseLink`,
`SkippedOutsideAreaPath`, `SkippedAreaPath`, and `Unavailable`. The report
separately counts results without a Test Case link and results linked to Test
Cases outside the selected Area Path. Import statuses include `Imported`,
`UnresolvedLinks`, `Failed`, `FailedPartial`, and `NotAttempted`. Import
reports also add `linkMode`, `linkStatus`, `targetPlanId`, `targetSuiteIds`,
and `unresolvedReferenceCount`. `linkStatus` distinguishes
`PlannedLinked`, `UnplannedFallback`, `Disabled`, and `UnresolvedLinks`.

## Export contents

Each export creates a directory under `exports`:

```text
exports/
  Project-20260812-102700/
    manifest.json
    runs/
      123/
        run.json
        results.json
        links.json
        attachments/
```

After import, a `migration-map-*.json` file records the source IDs and their
new target IDs, plus the chosen link mode and any resolved target plan/point
metadata.

The export manifest records runs skipped because they were deleted or became
unavailable after the initial run listing. A `404` for one of these runs does
not stop the remaining export.

Each `links.json` file stores one record per exported result with the source
result ID, Test Case, Test Point, Test Plan, Test Suite, Configuration, and
associated Bug IDs when they are available. Metadata lookup failures are
captured in the file and the export continues.

## Planned run linking

Planned linking relies on a reflected source ID field in the target project for
the following work item types:

- `Test Plan`
- `Test Suite`
- `Test Case`
- `Bug`

Supported reflected field value formats are:

- a raw integer source ID, for example `12345`
- a string ending with the source ID after `/`, for example
  `https://dev.azure.com/contoso/SourceProject/_workitems/edit/12345`
- a string ending with the source ID after `\`, for example
  `contoso\SourceProject\12345`

The import resolves the target Test Point by querying the mapped target plan,
suite, and test case, then matching the configuration name exactly
case-insensitively. If the source configuration name is missing, the import only
accepts the run as planned when exactly one target point exists for that test
case in the mapped suite.

Safe fallback behavior:

- `Prefer` never splits a run. If any core Test Plan, Suite, Test Case, or Test
  Point link is unresolved, the whole run imports through the unplanned path.
- `Require` never guesses ambiguous matches and never creates a partially linked
  planned run.
- Associated Bugs are best-effort. Unresolved bug mappings are reported but do
  not block a planned-linked run.
- Schema version 1 exports without `links.json` still import. `Prefer` falls
  back to the unplanned path and `Require` reports `UnresolvedLinks`.

## Limitations

- Planned linking requires pre-mapped target work items and matching target
  Test Points. Ambiguous matches are reported and are never guessed.
- References to work items, bugs, builds, pipelines, and releases are not
  recreated without an explicit mapping between projects.
- Operational dates can be submitted, but audit dates and identities are set by
  Azure DevOps when the resources are recreated.
- Analytics history is not rebuilt retroactively.
- Run and result attachments are included. Attachments associated exclusively
  with subresults are not included in this version.

Run a proof of concept in a disposable target project before a production
migration.

## APIs

- [Test Runs](https://learn.microsoft.com/rest/api/azure/devops/test/runs)
- [Test Results](https://learn.microsoft.com/rest/api/azure/devops/test/results)
- [Test Attachments](https://learn.microsoft.com/rest/api/azure/devops/test/attachments)
