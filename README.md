# D4A IT Automation and Operations Toolkit

An interactive Windows PowerShell toolkit for repeatable database administration, server diagnostics, application monitoring, and support operations in Decide4Action environments.

Developer: Khaled Barbar

## Project at a glance

| | |
|---|---|
| Project type | IT operations automation and team-enablement toolkit |
| Primary users | Level 1 and Level 2 technical support, system administrators |
| Technologies | Windows PowerShell 5.1, SQL Server, Windows Server, Task Scheduler, GitHub |
| Core areas | Database tools, local server and file tools, site monitoring |
| Distribution | GitHub-hosted releases with automatic version and SHA-256 validation |
| Current release | IT Tools 7.0.9, Monitoring 6.5.1 |

## Why it exists

This project began as a collection of scripts for recurring support tasks. After moving into Level 2 Support, I was asked to help delegate more work safely to Level 1 Support. The scripts evolved into a centralized toolkit that turns complex interventions into guided, validated, and recoverable workflows.

The goal is not simply to save commands. It is to reduce dependence on individual expertise, make procedures consistent, lower the risk of manual error, and give Level 1 technicians enough context and safeguards to complete appropriate operations independently.

## Documentation

- [Project overview](docs/01-project-overview.md): the operational problem, project story, impact, and lessons learned.
- [Technical design](docs/02-technical-design.md): architecture, safety model, monitoring design, and update mechanism.
- [Technical user guide](docs/03-user-guide.md): installation, menu reference, common workflows, troubleshooting, and escalation guidance.
- [Changelog](CHANGELOG.md): significant releases, new capabilities, and production corrections.

## Main capabilities

- Database translation export, import, cleanup, search, migration, rollback, and performance diagnostics.
- Guided D4A and Danone configuration operations with previews, confirmations, and timestamped backups.
- Local server health checks, file and log searches, disk analysis, SQL backup-folder permissions, and port tests.
- Scheduled site monitoring for application endpoints, APIs, services, resources, Nginx, Windows events, and Watchdog evidence.
- Daily error logging, progress reporting, input validation, finite timeouts, and recoverable database changes.
- Automatic updates from the repository with HTTPS download, manifest validation, SHA-256 verification, and PowerShell syntax checks.

## Quick start

1. Download or clone the repository to a user-writable folder such as `Desktop\IT Tools` or `Documents\IT Tools`.
2. Run `IT_Tools_Database_Translations_and_Server_Checks.ps1` in Windows PowerShell 5.1.
3. Run as Administrator when the selected server, permissions, monitoring, or Scheduled Task operation requires elevation.
4. Use the numbered menus. Every workflow supports `q` to return to the previous menu.

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1
```

Use this only when an update check must be skipped temporarily:

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1 -SkipAutomaticUpdate
```

The script can offer to install the `SqlServer` or `ImportExcel` PowerShell module for the current user when a selected feature requires it. Missing official companion files are downloaded only when their feature is selected and are verified against `update-manifest.json` before use.

## Safe operation

Database-writing features create timestamped backups of target tables, show previews where practical, and require explicit confirmation. Full errors are written to the daily file under `Logs`. Site-specific monitoring configuration, credentials, logs, state, and ignore rules remain outside the release files and are preserved during monitor updates.

This toolkit supports operational work; it does not replace change-management approval, environment-specific authorization, or escalation when results are unexpected.

## Repository contents

| File | Purpose |
|---|---|
| `IT_Tools_Database_Translations_and_Server_Checks.ps1` | Main interactive toolkit |
| `D4A-ScheduledMonitor-v5.ps1` | Configuration-driven scheduled health monitor |
| `D4A-DiskSpaceAnalyzer.ps1` | Fast NTFS disk-usage analyzer with visual reporting |
| `Find-LogGaps.ps1` | Stand-alone timestamp-gap analyzer for text logs |
| `AssemblyRules_Luleburgas.sql` | Companion data for the Luleburgas system-settings workflow |
| `RoleAdminLuleburgaz-DanoneStandard-090426.sql` | Companion data for the Luleburgas roles workflow |
| `version.txt` | Public IT Tools release version |
| `update-manifest.json` | Release file list and SHA-256 integrity hashes |

## Versioning

Patch releases are used for changes in the same release week, minor releases for a later release cycle, and major releases for substantial or breaking changes. The monitoring component has its own version because it can be updated while preserving each site's local configuration and Scheduled Tasks.

For stronger production assurance, signed GitHub releases or Authenticode signatures can be added in addition to the current HTTPS and SHA-256 controls.
