# D4A IT Tools: Level 1 Quick Guide

Use IT Tools to collect evidence, run approved checks, and complete approved tasks consistently. If a result is unexpected, stop and escalate with the information shown by the tool.

## Start the tool

1. <a href="https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/IT_Tools_Database_Translations_and_Server_Checks.zip" download>Download the latest IT Tools script</a>.
2. Save it in a user-owned folder, such as `Desktop\IT Tools`.
3. Right-click `IT_Tools_Database_Translations_and_Server_Checks.ps1` and select **Run with PowerShell**.
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
| **1. Database Tools** | Translation files, approved Danone features, searches, and performance checks | Do not import, migrate, copy, delete, roll back, or change database data unless the task is approved. |
| **2. Local server and file tools** | File searches, Data Collector log tracing, system health, port checks, SSL checks, disk report | Use this menu to collect evidence before escalation. |
| **3. Troubleshooting** | `DBConfig.js Diagnostic` | Select the detected `dbconfig.js` file and run the default scan. Do not share passwords or configuration secrets. |
| **4. Site Monitoring** | Review monitor configuration, run monitor commands, deploy or update monitoring | Only add sites or change monitoring settings when the request is approved. |
| **5. Logs** | Last actions done by this script | Use this to confirm completed database or monitoring actions. |

## Common Level 1 Tasks

Use these actions in this order: check availability first, collect evidence next, then complete approved planned changes.

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

### Investigate a database performance issue

1. Open **Database Tools** > **Database Performance**.
2. Start with **Pending SQL queries**, then use heavy-query, SQL CPU, and table disk-usage checks when needed.
3. Record the session ID, start time, duration, query summary, and relevant resource values.
4. Escalate with the results. These checks are read-only.

### Find text in files or the database

1. To find a file containing text, open **Local server and file tools** > **Search for text in files**.
2. Select the folder, enter the search text, and record the matching file names and lines.
3. To search database text, open **Database Tools** > **Database Search Tools** > **Search text in Database**. Record the returned table, column, and matching value.
4. To find a column, select **Find which table has a specific column**. Use `%text%` to find a partial column-name match.
5. Use **Text Search in Sprocs** only when the issue may be caused by stored-procedure logic.

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

### Export or import language files

1. Open **Database Tools** > **Import/Export operations**.
2. For an export, select **Export Language File**, choose the language, then choose all content or missing translations only.
3. For an import, select **Import new Language with a translated CSV file** and choose the approved translated file.
4. Check the database, language, row preview, and counts.
5. Type `IMPORT` only when the request is approved and the preview is correct.

### Apply approved Danone settings or roles

1. Open **Database Tools** > **Danone Features**.
2. Select **Import Luleburgas System Settings** or **Import Luleburgas User Roles and Privileges**.
3. Verify the target database and review the displayed summary.
4. Enter your name and the requested confirmation only when the change is approved.
5. Record the final result in the ticket.

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
