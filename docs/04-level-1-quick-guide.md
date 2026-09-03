# D4A IT Tools: Level 1 Quick Guide

Use IT Tools to collect evidence, run approved checks, and complete approved tasks consistently. If a result is unexpected, stop and escalate with the information shown by the tool.

## Start the tool

1. Keep all IT Tools files in the same folder.
2. Right-click `IT_Tools_Database_Translations_and_Server_Checks.ps1`.
3. Select **Run with PowerShell**.
4. Wait for the automatic update check to finish. Press a key when asked.
5. Use **Run as Administrator** only when the tool requests it or when working with Scheduled Tasks, services, or disk analysis.

## Navigation

- Enter the number shown beside an option.
- Type `q` to go back.
- After results or an error, press any key to continue.
- Check the target server, database, site, or file path before continuing.

## Choose The Right Menu

| Menu | Use it for | Level 1 guidance |
|---|---|---|
| **1. Database Tools** | Read-only searches, performance checks, translation exports | Do not import, migrate, copy, delete, roll back, or change database data unless the task is approved. |
| **2. Local server and file tools** | File searches, Data Collector log tracing, system health, port checks, SSL checks, disk report | Use this menu to collect evidence before escalation. |
| **3. Troubleshooting** | `DBConfig.js Diagnostic` | Select the detected `dbconfig.js` file and run the default scan. Do not share passwords or configuration secrets. |
| **4. Site Monitoring** | Review monitor configuration, run monitor commands, deploy or update monitoring | Only add sites or change monitoring settings when the request is approved. |
| **5. Logs** | Last actions done by this script | Use this to confirm completed database or monitoring actions. |

## Common Level 1 Tasks

### Check a website or API issue

1. Open **Site Monitoring**.
2. Use **Execute Monitoring Commands**.
3. Select the affected monitoring installation.
4. View the current configuration or run a normal monitoring check.
5. Record the site name, time, affected component, and error details before escalating.

### Trace Data Collector events

1. Open **Local server and file tools** > **Trace events in Data Collector**.
2. Select the correct log file or date.
3. Enter the incident time window and search text.
4. Copy the relevant timestamps and messages into the incident ticket.

### Check SSL or a network port

1. Open **Local server and file tools**.
2. Select **SSL Checker** for a website certificate check, or **Check if a port is open** for a TCP port check.
3. Enter the requested hostname, URL, IP address, or port.
4. Attach the result to the ticket if the check fails.

### Diagnose a D4A database configuration

1. Open **Troubleshooting** > **DBConfig.js Diagnostic**.
2. Select the correct detected `dbconfig.js` file.
3. Press Enter to run the default scan.
4. Record the summary and any errors or warnings. Do not copy credentials from the file.

## Stop And Escalate

Stop and escalate when:

- a database action asks for `IMPORT`, `MIGRATE`, `DELETE`, `ROLLBACK`, or another confirmation word and you do not have approval;
- the selected server, database, site, or file is not the expected target;
- a password, webhook URL, or other secret is requested for sharing;
- the tool reports a red error, access denied, or a result you do not understand;
- the issue affects production availability, data, or security.

Include the action used, target, time, error message, and any relevant log lines in the escalation.

## Logs

- IT Tools errors are saved in the `Logs` folder beside the script.
- Database and monitoring actions are recorded in `C:\Users\edit_log.txt`.
- Use **Logs** > **Last Actions done by this script** to view the latest 10 entries.

