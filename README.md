# Azure DevOps Test History Migration

PowerShell utility that exports Test Runs, results, and attachments from an
Azure DevOps project and recreates them in another project or organization.

> Import creates new resources. IDs, audit data, identities, and references to
> Test Plans, Suites, builds, releases, and work items are not automatically
> preserved.

## Requirements

- PowerShell 7.2 or later.
- One of the following authentication methods:
  - Azure CLI authenticated as a user with Azure DevOps access; or
  - A PAT with `Test Management: Read` for export and
    `Test Management: Read & write` for import.
- Exporting with an Area Path filter also requires `Work Items: Read`.

## Usage

```powershell
Set-Location F:\repos\DevOps-Migration-Tests
.\Invoke-AdoTestMigration.ps1
```

The menu provides the following operations:

1. Export Test Run history.
2. Import a previous export.
3. Validate access.

The export operation supports optional filters for the last updated date and
Area Path. The Area Path filter includes child areas and exports only results
associated with Test Cases under that path. Runs with no matching results are
skipped. Results without an associated Test Case are also skipped while the
filter is active. Enter the Area Path as displayed in Azure DevOps. The script
validates it against the project's classification tree and supports projects
whose current name differs from the Area Path root.

Use `-Verbose` for additional technical details:

```powershell
.\Invoke-AdoTestMigration.ps1 -Verbose
```

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
        attachments/
```

After import, a `migration-map-*.json` file records the source IDs and their
new target IDs.

## Limitations

- The operation recreates unplanned runs. It does not automatically map Test
  Plans, Suites, Test Points, or Configurations.
- Planned manual results are currently recreated as unplanned migrated results
  until Test Point mapping is available.
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
