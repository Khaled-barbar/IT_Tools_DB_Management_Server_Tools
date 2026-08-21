# D4A IT Automation and Operations Toolkit

An interactive Windows PowerShell toolkit for repeatable database administration, server diagnostics, application monitoring, and support operations in Decide4Action environments.

## Documentation

- 📘 **[Project Overview](docs/01-project-overview.md)** - Story, problem, solution, evolution, and impact
- 🏗️ **[Technical Design](docs/02-technical-design.md)** - Architecture, implementation, safety, and monitoring
- 🛠️ **[User Guide](docs/03-user-guide.md)** - Installation, workflows, commands, and troubleshooting
- 📋 **[Changelog](CHANGELOG.md)** - Project evolution and significant release history

Developer: Khaled Barbar

## Project at a glance

| | |
|---|---|
| Project type | IT operations automation and team-enablement toolkit |
| Primary users | Level 1 and Level 2 technical support, system administrators |
| Technologies | Windows PowerShell 5.1, SQL Server, Windows Server, Task Scheduler, GitHub |
| Core areas | Database tools, local server and file tools, site monitoring, intervention logs |
| Distribution | GitHub-hosted releases with automatic version and SHA-256 validation |
| Current release | IT Tools 7.1.15, Monitoring 6.9.1 |

## Why it exists

This project began as a collection of scripts for recurring support tasks. After moving into Level 2 Support, I was asked to help delegate more work safely to Level 1 Support. The scripts evolved into a centralized toolkit that turns complex interventions into guided, validated, and recoverable workflows.

The goal is not simply to save commands. It is to reduce dependence on individual expertise, make procedures consistent, lower the risk of manual error, and give Level 1 technicians enough context and safeguards to complete appropriate operations independently.

## Main capabilities

- Database translation export, import, cleanup, search, migration, rollback, and performance diagnostics.
- Guided D4A and Danone configuration operations with previews, confirmations, and timestamped backups.
- Local server health checks, full SSL/TLS diagnostics, file and log searches, disk analysis, SQL backup-folder permissions, and port tests.
- Scheduled site monitoring for application endpoints, APIs, services, resources, Nginx, Windows events, and Watchdog evidence, with actionable alert thresholds and explicit recovery notifications.
- Operator-attributed database intervention and monitoring-change logging with selected non-sensitive variables and success or failure status.
- Daily error logging, progress reporting, input validation, finite timeouts, and recoverable database changes.
- Automatic updates for both IT Tools and the stand-alone monitor with HTTPS download, manifest validation, SHA-256 verification, and PowerShell syntax checks.

## Quick start

1. [Download the latest IT Tools PowerShell script](https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/IT_Tools_Database_Translations_and_Server_Checks.ps1), or clone the complete repository.
2. Save it in a user-writable folder such as `Desktop\IT Tools` or `Documents\IT Tools`.
3. To run the tool as the current Windows user, right-click `IT_Tools_Database_Translations_and_Server_Checks.ps1` and select **Run with PowerShell**.
4. Run PowerShell as Administrator only when the selected server, permissions, monitoring, or Scheduled Task operation requires elevation.
5. Use the numbered menus. Every workflow supports `q` to return to the previous menu.

You can also start the tool from Windows PowerShell 5.1:

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1
```

Use this only when an update check must be skipped temporarily:

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1 -SkipAutomaticUpdate
```

The script can offer to install the `SqlServer` or `ImportExcel` PowerShell module for the current user when a selected feature requires it. Monitoring deployment can also detect or install Node.js LTS and npm before creating monitor files. Missing official companion files are downloaded only when their feature is selected and are verified against `update-manifest.json` before use.

## Safe operation

Database-writing features create timestamped backups of target tables, show previews where practical, require explicit confirmation, and ask for the operator's name before the first persistent write. Database interventions and confirmed monitoring creation or configuration changes are appended to `C:\Users\edit_log.txt`; full errors are written to the daily file under `Logs`. Site-specific monitoring configuration, credentials, logs, state, and ignore rules remain outside the release files and are preserved during monitor updates.

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
| `CHANGELOG.md` | Human-readable history of significant releases, features, and corrections |
| `IT_Tools_Script_Maintenance_Conditions.md` | Standing safety, logging, validation, and release rules for future script changes |
| `version.txt` | Public IT Tools release version used only by the IT Tools updater |
| `monitor-version.txt` | Public Monitoring release version used only by deployed monitoring scripts |
| `update-manifest.json` | File allowlist and SHA-256 hashes, plus the explicit Monitoring release definition |

## Versioning

Patch releases are used for changes in the same release week, minor releases for a later release cycle, and major releases for substantial or breaking changes. IT Tools reads `version.txt`; deployed monitors read `monitor-version.txt` and the `monitoring` definition in `update-manifest.json`. The monitoring component has its own version because it can be updated while preserving each site's local configuration and Scheduled Tasks.

For stronger production assurance, signed GitHub releases or Authenticode signatures can be added in addition to the current HTTPS and SHA-256 controls.
