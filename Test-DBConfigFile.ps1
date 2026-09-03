<#
.SYNOPSIS
Scans a JavaScript DBConfig file and validates exported declarations, syntax,
certificate file references, SMTP reachability/authentication, and SQL Server credentials.

.DESCRIPTION
The scanner uses static parsing for the JavaScript config so the file is not
executed just to discover secrets and exported names. Syntax validation uses
`node --check` when Node.js is available, which parses without running the file.
When started with Run with PowerShell, an interactive launcher offers default
or custom parameters and keeps the window open after every scan.

.PARAMETER Path
Path to the DBConfig.js file. If omitted, the interactive launcher discovers
dbconfig.js files from active D4A Data Collector service paths before offering
manual entry.

.PARAMETER ConnectionTimeoutSeconds
SQL connection timeout used for each database credential test.

.PARAMETER SkipDatabaseTests
Scans database settings but does not attempt SQL Server logins.

.PARAMETER NoDatabasePasswordPrompt
Do not prompt for a decrypted/plain SQL password when a stored database password
looks encoded or encrypted and login fails.

.PARAMETER RunUserTableSettingsProbe
Compatibility switch. The user-table-settings probe now runs by default. Use
SkipUserTableSettingsProbe when the probe should not run.

.PARAMETER SkipUserTableSettingsProbe
Do not run the D4A_UpdateUserTableSettings payload-size probe.

.PARAMETER ProbeDbConfigName
Database config object to use for the user table settings probe.

.PARAMETER ProbePayloadSizes
Payload sizes, in approximate bytes, to test with D4A_UpdateUserTableSettings.

.PARAMETER AllowUnencryptedSqlDiagnostic
Compatibility switch. The encrypt=false comparison now runs by default when an
encrypted transport reset is detected. Use SkipUnencryptedSqlDiagnostic to
disable it.

.PARAMETER SkipUnencryptedSqlDiagnostic
Do not perform the controlled encrypt=false comparison. By default, the probe
uses synthetic JSON and rolls back database changes, but this diagnostic SQL
traffic may cross the network without TLS. Run only on an approved network.

.PARAMETER RunExtendedDbConfigSimulations
Compatibility switch. Extended simulations now run by default. Use
SkipExtendedDbConfigSimulations to disable them.

.PARAMETER SkipExtendedDbConfigSimulations
Do not test safe dbConfigTampa behavioral settings one at a time when normal
controls cannot identify the failure. Server, database, username, password,
and port values are always validated but are never guessed.

.PARAMETER SkipSmtpTcpTest
Scans SMTP settings but does not test TCP reachability to host:port.

.PARAMETER SkipSmtpAuthTest
Scans SMTP settings but does not attempt SMTP AUTH LOGIN credential validation.

.PARAMETER SmtpTimeoutSeconds
Timeout used for SMTP socket connection, reads, writes, STARTTLS, and AUTH LOGIN.

.PARAMETER SetExitCode
Exit with code 1 when errors are found. By default, the script only prints
results so it is friendlier when launched interactively.

.PARAMETER NonInteractive
Bypass the right-click menu and run once with the supplied command-line
parameters. Intended for scheduled tasks and automation.
#>
# D4A-DBConfigDiagnostic-Version: 1.5.0
# D4A-DBConfigDiagnostic-ReleaseDate: 2026-09-03
[CmdletBinding()]
param(
    [string]$Path,

    [ValidateRange(1, 120)]
    [int]$ConnectionTimeoutSeconds = 5,

    [switch]$SkipDatabaseTests,

    [switch]$NoDatabasePasswordPrompt,

    [switch]$RunUserTableSettingsProbe,

    [switch]$SkipUserTableSettingsProbe,

    [string]$ProbeDbConfigName = 'dbConfigTampa',

    [int[]]$ProbePayloadSizes = @(512, 1024, 2048, 4096, 6144, 8192, 10240, 12288, 16384, 24576, 32768),

    [switch]$AllowUnencryptedSqlDiagnostic,

    [switch]$SkipUnencryptedSqlDiagnostic,

    [switch]$RunExtendedDbConfigSimulations,

    [switch]$SkipExtendedDbConfigSimulations,

    [switch]$SkipSmtpTcpTest,

    [switch]$SkipSmtpAuthTest,

    [ValidateRange(1, 120)]
    [int]$SmtpTimeoutSeconds = 15,

    [switch]$SetExitCode,

    [switch]$NonInteractive,

    [Parameter(DontShow = $true)]
    [switch]$InternalExecution
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DbConfigDiagnosticVersion = '1.5.0'
$script:DbConfigDiagnosticReleaseDate = '2026-09-03'

function Show-InteractiveParameterHelp {
    Write-Host ''
    Write-Host 'Available parameters' -ForegroundColor Cyan
    Write-Host 'Enter parameters on one line, separated by spaces. Put paths containing spaces in double quotes.' -ForegroundColor Gray
    Write-Host 'Example: -SkipSmtpAuthTest -ConnectionTimeoutSeconds 15' -ForegroundColor Gray
    Write-Host ''

    @(
        [pscustomobject]@{ Parameter = '-Path <file>'; Default = 'Prompt'; Description = 'Full path to dbconfig.js.' }
        [pscustomobject]@{ Parameter = '-ConnectionTimeoutSeconds <1-120>'; Default = '5'; Description = 'Timeout for each SQL connection test.' }
        [pscustomobject]@{ Parameter = '-SkipDatabaseTests'; Default = 'Off'; Description = 'Do not connect to SQL Server.' }
        [pscustomobject]@{ Parameter = '-NoDatabasePasswordPrompt'; Default = 'Off'; Description = 'Do not ask for a decrypted SQL password after a failed encrypted-password login.' }
        [pscustomobject]@{ Parameter = '-SkipUserTableSettingsProbe'; Default = 'Off'; Description = 'Skip the payload-size and SQL transport investigation.' }
        [pscustomobject]@{ Parameter = '-ProbeDbConfigName <name>'; Default = 'dbConfigTampa'; Description = 'Database configuration object used by the payload probe.' }
        [pscustomobject]@{ Parameter = '-ProbePayloadSizes <values>'; Default = '512..32768'; Description = 'Payload sizes to test. Use comma-separated integers.' }
        [pscustomobject]@{ Parameter = '-SkipUnencryptedSqlDiagnostic'; Default = 'Off'; Description = 'Do not compare the failing encrypted request with encrypt=false.' }
        [pscustomobject]@{ Parameter = '-SkipExtendedDbConfigSimulations'; Default = 'Off'; Description = 'Do not test safe configuration alternatives one at a time.' }
        [pscustomobject]@{ Parameter = '-SkipSmtpTcpTest'; Default = 'Off'; Description = 'Do not test whether the SMTP host and port are reachable.' }
        [pscustomobject]@{ Parameter = '-SkipSmtpAuthTest'; Default = 'Off'; Description = 'Do not validate SMTP authentication.' }
        [pscustomobject]@{ Parameter = '-SmtpTimeoutSeconds <1-120>'; Default = '15'; Description = 'Timeout for SMTP connection and authentication tests.' }
        [pscustomobject]@{ Parameter = '-SetExitCode'; Default = 'Off'; Description = 'Return exit code 1 when errors are found.' }
        [pscustomobject]@{ Parameter = '-NonInteractive'; Default = 'Off'; Description = 'Command-line only: bypass this menu for automation.' }
        [pscustomobject]@{ Parameter = '-RunUserTableSettingsProbe'; Default = 'Compatibility'; Description = 'Accepted for older commands; the probe already runs by default.' }
        [pscustomobject]@{ Parameter = '-AllowUnencryptedSqlDiagnostic'; Default = 'Compatibility'; Description = 'Accepted for older commands; this diagnostic already runs by default.' }
        [pscustomobject]@{ Parameter = '-RunExtendedDbConfigSimulations'; Default = 'Compatibility'; Description = 'Accepted for older commands; simulations already run by default.' }
    ) | Format-Table -AutoSize -Wrap
}

function ConvertFrom-InteractiveParameterText {
    param([string]$Text)

    $tokens = New-Object System.Collections.Generic.List[string]
    $allowedParameters = @{
        path = $true
        connectiontimeoutseconds = $true
        skipdatabasetests = $true
        nodatabasepasswordprompt = $true
        runusertablesettingsprobe = $true
        skipusertablesettingsprobe = $true
        probedbconfigname = $true
        probepayloadsizes = $true
        allowunencryptedsqldiagnostic = $true
        skipunencryptedsqldiagnostic = $true
        runextendeddbconfigsimulations = $true
        skipextendeddbconfigsimulations = $true
        skipsmtptcptest = $true
        skipsmtpauthtest = $true
        smtptimeoutseconds = $true
        setexitcode = $true
    }
    $pattern = '"(?:\\.|[^"])*"|''(?:''''|[^''])*''|[^\s]+'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $token = $match.Value
        if ($token.Length -ge 2 -and (($token[0] -eq '"' -and $token[$token.Length - 1] -eq '"') -or ($token[0] -eq "'" -and $token[$token.Length - 1] -eq "'"))) {
            $token = $token.Substring(1, $token.Length - 2)
        }
        if ($token -match '^(?i)-(?:InternalExecution|NonInteractive)(?::|$)') {
            throw "Parameter '$token' is reserved for internal or automated execution."
        }
        if ($token -match '^-(?<name>[A-Za-z][A-Za-z0-9]*)(?::.*)?$') {
            $parameterName = $Matches['name'].ToLowerInvariant()
            if (-not $allowedParameters.ContainsKey($parameterName)) {
                throw "Unknown parameter '-$($Matches['name'])'. Enter H at the menu to view the supported parameters."
            }
        }
        $tokens.Add($token) | Out-Null
    }

    return @($tokens)
}

function Get-D4ADataCollectorDbConfigCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object {
                ([string]$_.Name -match '(?i)^(?:Decide4Action|D4A).*data\s*collector') -or
                ([string]$_.DisplayName -match '(?i)^(?:Decide4Action|D4A).*data\s*collector')
            })
    }
    catch {
        return @()
    }

    foreach ($service in $services) {
        $pathName = [Environment]::ExpandEnvironmentVariables([string]$service.PathName)
        if ([string]::IsNullOrWhiteSpace($pathName)) { continue }

        $executablePath = if ($pathName -match '^\s*"(?<Path>[^"]+\.exe)"') {
            $Matches['Path']
        }
        elseif ($pathName -match '(?i)^\s*(?<Path>.+?\.exe)(?:\s|$)') {
            $Matches['Path'].Trim()
        }
        else {
            continue
        }

        try {
            # The Data Collector executable lives directly under
            # <D4A root>\Data Collector, including paths using Configuration\.. .
            $normalizedExecutablePath = [IO.Path]::GetFullPath($executablePath)
            $dataCollectorFolder = Split-Path -Parent $normalizedExecutablePath
            $applicationRoot = Split-Path -Parent $dataCollectorFolder
            if ([string]::IsNullOrWhiteSpace($applicationRoot)) { continue }

            $candidatePath = Join-Path $applicationRoot 'Services\API\dbconfig.js'
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }

            $resolvedCandidatePath = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
            if ($seen.Add($resolvedCandidatePath)) {
                $candidates.Add($resolvedCandidatePath) | Out-Null
            }
        }
        catch {
            # One malformed service path must not block discovery for other D4A installations.
        }
    }

    return @($candidates.ToArray() | Sort-Object)
}

function Read-ManualDbConfigPath {
    while ($true) {
        Write-Host ''
        $enteredPath = (Read-Host 'Enter the full path to dbconfig.js, press Enter to return, or type q').Trim().Trim('"').Trim("'")
        if ($enteredPath -ieq 'q' -or [string]::IsNullOrWhiteSpace($enteredPath)) { return $null }

        $resolvedPath = Resolve-Path -LiteralPath $enteredPath -ErrorAction SilentlyContinue
        if ($resolvedPath -and (Test-Path -LiteralPath $resolvedPath.Path -PathType Leaf)) {
            return $resolvedPath.Path
        }

        Write-Host "The file was not found: $enteredPath" -ForegroundColor Red
        Write-Host 'Check the path and try again.' -ForegroundColor Yellow
    }
}

function Read-DbConfigPathFromDataCollectorDiscovery {
    $candidates = @(Get-D4ADataCollectorDbConfigCandidates)
    if ($candidates.Count -eq 0) {
        Write-Host 'No dbconfig.js file was detected from Decide4Action Data Collector services.' -ForegroundColor Yellow
        return Read-ManualDbConfigPath
    }

    Write-Host ''
    Write-Host 'Detected D4A dbconfig.js file(s)' -ForegroundColor Cyan
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        Write-Host ('[{0}] {1}' -f ($index + 1), $candidates[$index])
    }

    while ($true) {
        $prompt = if ($candidates.Count -eq 1) {
            'Press Enter to use [1], type M for a manual path, or type q to return'
        }
        else {
            'Enter the number of the dbconfig.js file to scan, type M for a manual path, or type q to return'
        }
        $selection = (Read-Host $prompt).Trim()
        if ($selection -ieq 'q') { return $null }
        if ($selection -ieq 'm') { return Read-ManualDbConfigPath }
        if ([string]::IsNullOrWhiteSpace($selection) -and $candidates.Count -eq 1) { return $candidates[0] }

        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $candidates.Count) {
            return $candidates[$selectedIndex - 1]
        }
        Write-Host 'Enter a listed number, M for a manual path, or q to return.' -ForegroundColor Yellow
    }
}

function Add-InteractiveConfigPath {
    param([string[]]$Arguments)

    $hasPath = $false
    foreach ($argument in $Arguments) {
        if ($argument -match '^(?i)-Path(?:=|:|$)') {
            $hasPath = $true
            break
        }
    }
    if ($hasPath) { return @($Arguments) }

    $selectedPath = Read-DbConfigPathFromDataCollectorDiscovery
    if ([string]::IsNullOrWhiteSpace($selectedPath)) { return $null }
    return @($Arguments) + @('-Path', $selectedPath)
}

function Read-PostExecutionChoice {
    Write-Host ''
    Write-Host '[R] Run again with the same parameters' -ForegroundColor Cyan
    Write-Host '[M] Modify the parameters and run again' -ForegroundColor Cyan
    Write-Host '[Any other key] Continue and close this window' -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Choose an option: ' -NoNewline

    try {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host $key.Character
        return ([string]$key.Character).ToUpperInvariant()
    }
    catch {
        $fallback = Read-Host
        if ([string]::IsNullOrEmpty($fallback)) { return '' }
        return $fallback.Substring(0, 1).ToUpperInvariant()
    }
}

function Invoke-InteractiveLauncher {
    try { $Host.UI.RawUI.WindowTitle = 'D4A DBConfig Diagnostic' } catch {}

    $currentArguments = $null
    while ($true) {
        if ($null -eq $currentArguments) {
            while ($true) {
                Clear-Host
                Write-Host ("D4A DBConfig Diagnostic v{0} ({1})" -f $script:DbConfigDiagnosticVersion, $script:DbConfigDiagnosticReleaseDate) -ForegroundColor Cyan
                Write-Host '=======================' -ForegroundColor Cyan
                Write-Host ''
                Write-Host 'Press Enter to run with the recommended default settings.' -ForegroundColor White
                Write-Host 'Type H and press Enter to display parameter help.' -ForegroundColor White
                Write-Host 'Or enter custom parameters on one line.' -ForegroundColor White
                Write-Host ''
                Write-Host 'Default checks: SQL connectivity, payload probe, encrypted/unencrypted comparison,' -ForegroundColor Gray
                Write-Host 'extended dbConfig simulations, SMTP connectivity, and SMTP authentication.' -ForegroundColor Gray
                Write-Host ''

                $selection = Read-Host 'Press Enter for defaults, enter custom parameters, or type H for help'
                if ($selection.Trim() -match '^(?i)H$') {
                    Show-InteractiveParameterHelp
                    Write-Host ''
                    [void](Read-Host 'Press Enter to return to the menu')
                    continue
                }

                try {
                    [string[]]$selectedArguments = @()
                    if (-not [string]::IsNullOrWhiteSpace($selection)) {
                        $selectedArguments = @(ConvertFrom-InteractiveParameterText -Text $selection)
                    }
                    if (@($selectedArguments).Count -gt 0 -and $selectedArguments[0] -notmatch '^-') {
                        throw 'Custom input must begin with a parameter name, such as -SkipSmtpAuthTest.'
                    }
                    $nextArguments = Add-InteractiveConfigPath -Arguments $selectedArguments
                    if ($null -eq $nextArguments) {
                        continue
                    }
                    [string[]]$currentArguments = @($nextArguments)
                    break
                }
                catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    [void](Read-Host 'Press Enter to try again')
                }
            }
        }

        Clear-Host
        Write-Host ("Running D4A DBConfig Diagnostic v{0}..." -f $script:DbConfigDiagnosticVersion) -ForegroundColor Cyan
        Write-Host ("Parameters: {0}" -f $(if (@($currentArguments).Count -gt 0) { @($currentArguments) -join ' ' } else { '<defaults>' })) -ForegroundColor DarkGray
        Write-Host ''

        $powerShellExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
            $powerShellExe = (Get-Process -Id $PID).Path
        }
        $childArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-InternalExecution') + @($currentArguments)

        try {
            & $powerShellExe @childArguments
            $childExitCode = $LASTEXITCODE
            Write-Host ''
            Write-Host "Execution finished with exit code $childExitCode." -ForegroundColor $(if ($childExitCode -eq 0) { 'Green' } else { 'Yellow' })
        }
        catch {
            Write-Host ''
            Write-Host "The diagnostic could not be started: $($_.Exception.Message)" -ForegroundColor Red
        }

        $choice = Read-PostExecutionChoice
        if ($choice -eq 'R') {
            continue
        }
        if ($choice -eq 'M') {
            $currentArguments = $null
            continue
        }
        return
    }
}

if (-not $InternalExecution -and -not $NonInteractive) {
    Invoke-InteractiveLauncher
    return
}

# Default-on features use explicit Skip parameters. Older Run/Allow switches
# remain accepted so existing commands continue to work; Skip always wins.
$LegacyRunUserTableSettingsProbeRequested = [bool]$RunUserTableSettingsProbe
$LegacyAllowUnencryptedDiagnosticRequested = [bool]$AllowUnencryptedSqlDiagnostic
$LegacyRunExtendedSimulationsRequested = [bool]$RunExtendedDbConfigSimulations
$RunUserTableSettingsProbe = -not [bool]$SkipUserTableSettingsProbe
$AllowUnencryptedSqlDiagnostic = -not [bool]$SkipUnencryptedSqlDiagnostic
$RunExtendedDbConfigSimulations = -not [bool]$SkipExtendedDbConfigSimulations

function Write-Section {
    param([string]$Title)

    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Result {
    param(
        [ValidateSet('OK', 'WARN', 'ERROR', 'INFO')]
        [string]$Level,
        [string]$Message
    )

    $color = switch ($Level) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }

    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Add-Finding {
    param(
        [System.Collections.Generic.List[object]]$Findings,
        [ValidateSet('OK', 'WARN', 'ERROR', 'INFO')]
        [string]$Level,
        [string]$Area,
        [string]$Message
    )

    $Findings.Add([pscustomobject]@{
        Level = $Level
        Area = $Area
        Message = $Message
    }) | Out-Null
}

function Select-UniqueStringInOrder {
    param([AllowNull()][string[]]$Values)

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]

    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $key = $value.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($value) | Out-Null
        }
    }

    return @($unique)
}

function Get-LineNumber {
    param(
        [string]$Text,
        [int]$Index
    )

    if ($Index -le 0) {
        return 1
    }

    return ([regex]::Matches($Text.Substring(0, $Index), "`n").Count + 1)
}

function Get-ConfigSourceReference {
    param(
        [pscustomobject]$DbConfig,
        [string]$PropertyName
    )

    if ($DbConfig.PSObject.Properties.Name -contains 'PropertyLines' -and $DbConfig.PropertyLines) {
        $line = $DbConfig.PropertyLines[$PropertyName]
        if ($line) {
            return "line: $line"
        }
    }

    return 'property not explicitly configured'
}

function Find-MatchingBrace {
    param(
        [string]$Text,
        [int]$OpenIndex
    )

    $depth = 0
    $quote = $null
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($ch -eq "`n") {
                $lineComment = $false
            }
            continue
        }

        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $i++
            }
            continue
        }

        if ($null -ne $quote) {
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($ch -eq '\') {
                $escaped = $true
                continue
            }
            if ($ch -eq $quote) {
                $quote = $null
            }
            continue
        }

        if ($ch -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $i++
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $i++
            continue
        }
        if ($ch -eq "'" -or $ch -eq '"' -or $ch -eq '`') {
            $quote = $ch
            continue
        }
        if ($ch -eq '{') {
            $depth++
            continue
        }
        if ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }

    return -1
}

function Split-TopLevelComma {
    param([string]$Text)

    $items = New-Object System.Collections.Generic.List[string]
    $start = 0
    $depthParen = 0
    $depthBrace = 0
    $depthBracket = 0
    $quote = $null
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($lineComment) {
            if ($ch -eq "`n") {
                $lineComment = $false
            }
            continue
        }

        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $i++
            }
            continue
        }

        if ($null -ne $quote) {
            if ($escaped) {
                $escaped = $false
                continue
            }
            if ($ch -eq '\') {
                $escaped = $true
                continue
            }
            if ($ch -eq $quote) {
                $quote = $null
            }
            continue
        }

        if ($ch -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $i++
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $i++
            continue
        }
        if ($ch -eq "'" -or $ch -eq '"' -or $ch -eq '`') {
            $quote = $ch
            continue
        }

        switch ($ch) {
            '(' { $depthParen++ }
            ')' { $depthParen-- }
            '{' { $depthBrace++ }
            '}' { $depthBrace-- }
            '[' { $depthBracket++ }
            ']' { $depthBracket-- }
            ',' {
                if ($depthParen -eq 0 -and $depthBrace -eq 0 -and $depthBracket -eq 0) {
                    $items.Add($Text.Substring($start, $i - $start).Trim()) | Out-Null
                    $start = $i + 1
                }
            }
        }
    }

    if ($start -lt $Text.Length) {
        $items.Add($Text.Substring($start).Trim()) | Out-Null
    }

    return $items | Where-Object { $_ }
}

function Convert-JsLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $trimmed = $Value.Trim()
    if ($trimmed -match "^'(.*)'$" -or $trimmed -match '^"(.*)"$') {
        $inner = $Matches[1]
        return ($inner -replace "\\'", "'" -replace '\\"', '"' -replace '\\\\', '\')
    }
    if ($trimmed -match '^(?i:true)$') {
        return $true
    }
    if ($trimmed -match '^(?i:false)$') {
        return $false
    }
    if ($trimmed -match '^(?i:null|undefined)$') {
        return $null
    }
    if ($trimmed -match '^-?\d+$') {
        return [int]$trimmed
    }
    if ($trimmed -match '^-?\d+\.\d+$') {
        return [double]$trimmed
    }

    return $trimmed
}

function Get-JsPropertyValue {
    param(
        [string]$Text,
        [string]$PropertyName
    )

    $property = [regex]::Escape($PropertyName)
    $literalPattern = '(?ms)(?<![\w$]){0}\s*:\s*(?<value>''(?:\\.|[^''])*''|"(?:\\.|[^"])*"|true|false|null|undefined|-?\d+(?:\.\d+)?)' -f $property
    $match = [regex]::Match($Text, $literalPattern)
    if ($match.Success) {
        return Convert-JsLiteral $match.Groups['value'].Value
    }

    return $null
}

function Get-JsPropertyInfo {
    param(
        [string]$Text,
        [string]$PropertyName,
        [int]$BaseLine = 1
    )

    $property = [regex]::Escape($PropertyName)
    $literalPattern = '(?ms)(?<![\w$]){0}\s*:\s*(?<value>''(?:\\.|[^''])*''|"(?:\\.|[^"])*"|true|false|null|undefined|-?\d+(?:\.\d+)?)' -f $property
    $match = [regex]::Match($Text, $literalPattern)
    if (-not $match.Success) {
        return [pscustomobject]@{
            Present = $false
            Value = $null
            Line = $null
        }
    }

    return [pscustomobject]@{
        Present = $true
        Value = Convert-JsLiteral $match.Groups['value'].Value
        Line = $BaseLine + (Get-LineNumber -Text $Text -Index $match.Index) - 1
    }
}

function Get-JsPropertyDeclarationInfo {
    param(
        [string]$Text,
        [string]$PropertyName,
        [int]$BaseLine = 1
    )

    $property = [regex]::Escape($PropertyName)
    $match = [regex]::Match($Text, '(?m)(?<![\w$]){0}\s*:' -f $property)
    return [pscustomobject]@{
        Present = $match.Success
        Line = if ($match.Success) { $BaseLine + (Get-LineNumber -Text $Text -Index $match.Index) - 1 } else { $null }
    }
}

function Get-JsTopLevelPropertyInfo {
    param(
        [string]$ObjectText,
        [string]$PropertyName,
        [int]$BaseLine = 1
    )

    $openIndex = $ObjectText.IndexOf('{')
    $closeIndex = if ($openIndex -ge 0) { Find-MatchingBrace -Text $ObjectText -OpenIndex $openIndex } else { -1 }
    if ($openIndex -lt 0 -or $closeIndex -le $openIndex) {
        return [pscustomobject]@{ Present = $false; Value = $null; Line = $null }
    }

    $innerStart = $openIndex + 1
    $inner = $ObjectText.Substring($innerStart, $closeIndex - $innerStart)
    $innerBaseLine = $BaseLine + (Get-LineNumber -Text $ObjectText -Index $innerStart) - 1
    $searchIndex = 0
    $propertyPattern = '^(?s)\s*{0}\s*:' -f [regex]::Escape($PropertyName)

    foreach ($item in @(Split-TopLevelComma -Text $inner)) {
        $itemIndex = $inner.IndexOf($item, $searchIndex, [StringComparison]::Ordinal)
        if ($itemIndex -lt 0) {
            $itemIndex = $searchIndex
        }
        $searchIndex = [Math]::Min($inner.Length, $itemIndex + $item.Length)
        if ($item -match $propertyPattern) {
            $itemBaseLine = $innerBaseLine + (Get-LineNumber -Text $inner -Index $itemIndex) - 1
            return Get-JsPropertyInfo -Text $item -PropertyName $PropertyName -BaseLine $itemBaseLine
        }
    }

    return [pscustomobject]@{ Present = $false; Value = $null; Line = $null }
}

function Get-JsObjectBlockInfo {
    param(
        [string]$Text,
        [string]$PropertyName,
        [int]$BaseLine = 1
    )

    $property = [regex]::Escape($PropertyName)
    $match = [regex]::Match($Text, '(?ms)(?<![\w$]){0}\s*:\s*{{' -f $property)
    if (-not $match.Success) {
        return $null
    }

    $openIndex = $Text.IndexOf('{', $match.Index)
    $closeIndex = Find-MatchingBrace -Text $Text -OpenIndex $openIndex
    if ($closeIndex -lt 0) {
        return $null
    }

    return [pscustomobject]@{
        Text = $Text.Substring($openIndex, $closeIndex - $openIndex + 1)
        Line = $BaseLine + (Get-LineNumber -Text $Text -Index $openIndex) - 1
    }
}

function Get-JsAssignedLiteral {
    param(
        [string]$Text,
        [string]$Name
    )

    $identifier = [regex]::Escape($Name)
    $literalPattern = '(?ms)(?:^|[;\r\n])\s*(?:var|let|const)\s+{0}\s*=\s*(?<value>''(?:\\.|[^''])*''|"(?:\\.|[^"])*"|true|false|null|undefined|-?\d+(?:\.\d+)?)' -f $identifier
    $match = [regex]::Match($Text, $literalPattern)
    if ($match.Success) {
        return Convert-JsLiteral $match.Groups['value'].Value
    }

    return $null
}

function Get-JsDeclarations {
    param([string]$Text)

    $declarations = New-Object System.Collections.Generic.List[object]
    $declPattern = '(?m)^\s*(?:var|let|const)\s+(?<name>[A-Za-z_$][\w$]*)\s*='
    foreach ($match in [regex]::Matches($Text, $declPattern)) {
        $name = $match.Groups['name'].Value
        $afterEquals = $match.Index + $match.Length
        while ($afterEquals -lt $Text.Length -and [char]::IsWhiteSpace($Text[$afterEquals])) {
            $afterEquals++
        }

        $kind = 'literal'
        $rawValue = $null
        $endIndex = $afterEquals

        if ($afterEquals -lt $Text.Length -and $Text[$afterEquals] -eq '{') {
            $endIndex = Find-MatchingBrace -Text $Text -OpenIndex $afterEquals
            if ($endIndex -ge 0) {
                $kind = 'object'
                $rawValue = $Text.Substring($afterEquals, $endIndex - $afterEquals + 1)
            }
        }
        else {
            $semicolon = $Text.IndexOf(';', $afterEquals)
            $newline = $Text.IndexOf("`n", $afterEquals)
            $candidates = @($semicolon, $newline) | Where-Object { $_ -ge 0 }
            if ($candidates.Count -gt 0) {
                $endIndex = ($candidates | Measure-Object -Minimum).Minimum
                $rawValue = $Text.Substring($afterEquals, $endIndex - $afterEquals).Trim()
            }
        }

        $declarations.Add([pscustomobject]@{
            Name = $name
            Kind = $kind
            RawValue = $rawValue
            Line = Get-LineNumber -Text $Text -Index $match.Index
            RawValueLine = Get-LineNumber -Text $Text -Index $afterEquals
        }) | Out-Null
    }

    foreach ($match in [regex]::Matches($Text, '(?m)^\s*function\s+(?<name>[A-Za-z_$][\w$]*)\s*\(')) {
        $declarations.Add([pscustomobject]@{
            Name = $match.Groups['name'].Value
            Kind = 'function'
            RawValue = $null
            Line = Get-LineNumber -Text $Text -Index $match.Index
            RawValueLine = $null
        }) | Out-Null
    }

    foreach ($match in [regex]::Matches($Text, '(?m)^\s*class\s+(?<name>[A-Za-z_$][\w$]*)\b')) {
        $declarations.Add([pscustomobject]@{
            Name = $match.Groups['name'].Value
            Kind = 'class'
            RawValue = $null
            Line = Get-LineNumber -Text $Text -Index $match.Index
            RawValueLine = $null
        }) | Out-Null
    }

    return $declarations
}

function Get-ModuleExports {
    param([string]$Text)

    $exports = New-Object System.Collections.Generic.List[object]
    $match = [regex]::Match($Text, 'module\.exports\s*=\s*{')
    if (-not $match.Success) {
        return $exports
    }

    $openIndex = $Text.IndexOf('{', $match.Index)
    $closeIndex = Find-MatchingBrace -Text $Text -OpenIndex $openIndex
    if ($closeIndex -lt 0) {
        return $exports
    }

    $body = $Text.Substring($openIndex + 1, $closeIndex - $openIndex - 1)
    $items = Split-TopLevelComma -Text $body
    foreach ($item in $items) {
        if ($item -match '^(?<key>[A-Za-z_$][\w$]*|''[^'']+''|"[^"]+")\s*:\s*(?<value>[A-Za-z_$][\w$]*)$') {
            $key = ($Matches['key'] -replace '^[''"]|[''"]$', '')
            $exports.Add([pscustomobject]@{
                ExportName = $key
                ReferencedName = $Matches['value']
            }) | Out-Null
        }
        elseif ($item -match '^(?<name>[A-Za-z_$][\w$]*)$') {
            $exports.Add([pscustomobject]@{
                ExportName = $Matches['name']
                ReferencedName = $Matches['name']
            }) | Out-Null
        }
        else {
            $exports.Add([pscustomobject]@{
                ExportName = $item
                ReferencedName = $null
            }) | Out-Null
        }
    }

    return $exports
}

function Test-JavaScriptSyntax {
    param([string]$ConfigPath)

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand) {
        return [pscustomobject]@{
            Available = $false
            Success = $false
            Message = 'Node.js was not found in PATH, so JavaScript syntax parsing was skipped.'
            Line = $null
        }
    }

    $output = & $nodeCommand.Source --check $ConfigPath 2>&1
    $success = ($LASTEXITCODE -eq 0)
    $message = (($output | Out-String).Trim())
    $line = $null

    if (-not $success -and $message -match ':(?<line>\d+)(?::\d+)?') {
        $line = [int]$Matches['line']
    }

    return [pscustomobject]@{
        Available = $true
        Success = $success
        Message = $message
        Line = $line
    }
}

function Get-DbConfigs {
    param([object[]]$Declarations)

    $configs = New-Object System.Collections.Generic.List[object]
    foreach ($decl in $Declarations | Where-Object { $_.Kind -eq 'object' }) {
        $baseLine = if ($decl.RawValueLine) { [int]$decl.RawValueLine } else { [int]$decl.Line }
        $userInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'user' -BaseLine $baseLine
        $passwordInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'password' -BaseLine $baseLine
        $serverInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'server' -BaseLine $baseLine
        $databaseInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'database' -BaseLine $baseLine

        $user = $userInfo.Value
        $password = $passwordInfo.Value
        $server = $serverInfo.Value
        $database = $databaseInfo.Value

        if ($null -ne $user -and $null -ne $password -and $null -ne $server -and $null -ne $database) {
            $portInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'port' -BaseLine $baseLine
            $requestTimeoutInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'requestTimeout' -BaseLine $baseLine
            $streamInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'stream' -BaseLine $baseLine
            $parseJSONInfo = Get-JsTopLevelPropertyInfo -ObjectText $decl.RawValue -PropertyName 'parseJSON' -BaseLine $baseLine

            $optionsBlock = Get-JsObjectBlockInfo -Text $decl.RawValue -PropertyName 'options' -BaseLine $baseLine
            $optionsText = if ($optionsBlock) { $optionsBlock.Text } else { '{}' }
            $optionsLine = if ($optionsBlock) { [int]$optionsBlock.Line } else { $null }
            $encryptInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'encrypt' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })
            $trustInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'trustServerCertificate' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })
            $packetInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'packetSize' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })
            $useColumnsInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'useColumnNames' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })
            $rowDoneInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'rowCollectionOnDone' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })
            $rowRequestInfo = Get-JsTopLevelPropertyInfo -ObjectText $optionsText -PropertyName 'rowCollectionOnRequestCompletion' -BaseLine $(if ($optionsLine) { $optionsLine } else { $baseLine })

            $poolBlock = Get-JsObjectBlockInfo -Text $decl.RawValue -PropertyName 'pool' -BaseLine $baseLine
            $poolText = if ($poolBlock) { $poolBlock.Text } else { '{}' }
            $poolLine = if ($poolBlock) { [int]$poolBlock.Line } else { $null }
            $poolMinInfo = Get-JsTopLevelPropertyInfo -ObjectText $poolText -PropertyName 'min' -BaseLine $(if ($poolLine) { $poolLine } else { $baseLine })
            $poolMaxInfo = Get-JsTopLevelPropertyInfo -ObjectText $poolText -PropertyName 'max' -BaseLine $(if ($poolLine) { $poolLine } else { $baseLine })
            $poolIdleInfo = Get-JsTopLevelPropertyInfo -ObjectText $poolText -PropertyName 'idleTimeoutMillis' -BaseLine $(if ($poolLine) { $poolLine } else { $baseLine })
            $poolRequestInfo = Get-JsTopLevelPropertyInfo -ObjectText $poolText -PropertyName 'requestTimeout' -BaseLine $(if ($poolLine) { $poolLine } else { $baseLine })

            $propertyLines = @{
                object = [int]$decl.Line
                user = $userInfo.Line
                password = $passwordInfo.Line
                server = $serverInfo.Line
                database = $databaseInfo.Line
                port = $portInfo.Line
                requestTimeout = $requestTimeoutInfo.Line
                stream = $streamInfo.Line
                parseJSON = $parseJSONInfo.Line
                options = $optionsLine
                encrypt = $encryptInfo.Line
                trustServerCertificate = $trustInfo.Line
                packetSize = $packetInfo.Line
                useColumnNames = $useColumnsInfo.Line
                rowCollectionOnDone = $rowDoneInfo.Line
                rowCollectionOnRequestCompletion = $rowRequestInfo.Line
                pool = $poolLine
                'pool.min' = $poolMinInfo.Line
                'pool.max' = $poolMaxInfo.Line
                'pool.idleTimeoutMillis' = $poolIdleInfo.Line
                'pool.requestTimeout' = $poolRequestInfo.Line
            }

            $configs.Add([pscustomobject]@{
                Name = $decl.Name
                Line = $decl.Line
                User = $user
                Password = $password
                Server = $server
                Database = $database
                Port = $portInfo.Value
                RequestTimeout = $requestTimeoutInfo.Value
                Stream = $streamInfo.Value
                ParseJSON = $parseJSONInfo.Value
                Encrypt = $encryptInfo.Value
                TrustServerCertificate = $trustInfo.Value
                PacketSize = $packetInfo.Value
                UseColumnNames = $useColumnsInfo.Value
                RowCollectionOnDone = $rowDoneInfo.Value
                RowCollectionOnRequestCompletion = $rowRequestInfo.Value
                PoolMin = $poolMinInfo.Value
                PoolMax = $poolMaxInfo.Value
                PoolIdleTimeoutMillis = $poolIdleInfo.Value
                PoolRequestTimeout = $poolRequestInfo.Value
                PropertyLines = $propertyLines
            }) | Out-Null
        }
    }

    return $configs
}

function Get-LocalSqlInstanceNames {
    param([string]$ServerPrefix = 'localhost')

    if ([string]::IsNullOrWhiteSpace($ServerPrefix) -or $ServerPrefix -in @('.', '(local)')) {
        $ServerPrefix = 'localhost'
    }

    $instances = New-Object System.Collections.Generic.List[string]

    try {
        $instanceKeys = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
        if ($null -ne $instanceKeys) {
            foreach ($property in $instanceKeys.PSObject.Properties) {
                if ($property.Name -match '^PS' -or $property.Name -eq 'Name') {
                    continue
                }

                if ($property.Name -eq 'MSSQLSERVER') {
                    $instances.Add($ServerPrefix) | Out-Null
                }
                else {
                    $instances.Add("$ServerPrefix\$($property.Name)") | Out-Null
                }
            }
        }
    }
    catch {
    }

    try {
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })

        foreach ($service in $services) {
            if ($service.Name -eq 'MSSQLSERVER') {
                $instances.Add($ServerPrefix) | Out-Null
            }
            elseif ($service.Name -like 'MSSQL$*') {
                $instances.Add("$ServerPrefix\$($service.Name.Substring(6))") | Out-Null
            }
        }
    }
    catch {
    }

    return @(Select-UniqueStringInOrder -Values @($instances))
}

function Get-SqlServerBaseName {
    param([string]$Server)

    $value = ([string]$Server).Trim()
    $value = $value -replace '^(?i)(tcp|np|lpc):', ''
    if ($value -match '\\') {
        $value = ($value -split '\\', 2)[0]
    }
    if ($value -match ',') {
        $value = ($value -split ',', 2)[0]
    }

    return $value.Trim()
}

function Test-IsLocalSqlServerName {
    param([string]$Server)

    $baseName = Get-SqlServerBaseName -Server $Server
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return $false
    }

    $localNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('localhost', '.', '(local)', '127.0.0.1', '::1', $env:COMPUTERNAME)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $localNames.Add($name) | Out-Null
        }
    }

    try {
        $dnsHost = [System.Net.Dns]::GetHostName()
        if (-not [string]::IsNullOrWhiteSpace($dnsHost)) {
            $localNames.Add($dnsHost) | Out-Null
        }
    }
    catch {
    }

    return @($localNames | Sort-Object -Unique) -icontains $baseName
}

function Get-LocalSqlServerPrefixes {
    param([string]$ConfiguredServer)

    $prefixes = New-Object System.Collections.Generic.List[string]
    $configuredBase = Get-SqlServerBaseName -Server $ConfiguredServer

    if ([string]::IsNullOrWhiteSpace($configuredBase) -or $configuredBase -in @('.', '(local)')) {
        $configuredBase = 'localhost'
    }

    $prefixes.Add($configuredBase) | Out-Null
    $prefixes.Add('localhost') | Out-Null

    foreach ($name in @($env:COMPUTERNAME)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $prefixes.Add($name) | Out-Null
        }
    }

    try {
        $dnsHost = [System.Net.Dns]::GetHostName()
        if (-not [string]::IsNullOrWhiteSpace($dnsHost)) {
            $prefixes.Add($dnsHost) | Out-Null
        }
    }
    catch {
    }

    return @(Select-UniqueStringInOrder -Values @($prefixes))
}

function Get-SqlDataSourceCandidates {
    param([pscustomobject]$DbConfig)

    $server = [string]$DbConfig.Server
    $dataSource = $server
    $hasExplicitPort = ($DbConfig.Port -or $server -match ',')
    $hasExplicitInstance = ($server -match '\\')

    if ($DbConfig.Port -and $dataSource -notmatch '[,\\]') {
        $dataSource = '{0},{1}' -f $dataSource, $DbConfig.Port
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($dataSource) | Out-Null

    if ((Test-IsLocalSqlServerName -Server $server) -and -not $hasExplicitPort -and -not $hasExplicitInstance) {
        foreach ($serverPrefix in (Get-LocalSqlServerPrefixes -ConfiguredServer $server)) {
            foreach ($instance in (Get-LocalSqlInstanceNames -ServerPrefix $serverPrefix)) {
                $candidates.Add($instance) | Out-Null
            }
        }
    }

    return @(Select-UniqueStringInOrder -Values @($candidates))
}

function New-SqlConnectionString {
    param(
        [pscustomobject]$DbConfig,
        [string]$DataSource,
        [AllowNull()][string]$Database,
        [int]$TimeoutSeconds
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $DataSource
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $builder['Initial Catalog'] = $Database
    }
    $builder['User ID'] = [string]$DbConfig.User
    $builder['Password'] = [string]$DbConfig.Password
    $builder['Connect Timeout'] = $TimeoutSeconds

    $builder['Encrypt'] = if ($null -ne $DbConfig.Encrypt) { [bool]$DbConfig.Encrypt } else { $false }
    $builder['TrustServerCertificate'] = if ($null -ne $DbConfig.TrustServerCertificate) { [bool]$DbConfig.TrustServerCertificate } else { $true }
    if ($null -ne $DbConfig.PacketSize) {
        $builder['Packet Size'] = [int]$DbConfig.PacketSize
    }

    return $builder.ConnectionString
}

function Convert-SqlExceptionToDetail {
    param([System.Data.SqlClient.SqlException]$Exception)

    $sqlError = $Exception.Errors | Select-Object -First 1
    $message = $Exception.Message
    $number = if ($sqlError) { [int]$sqlError.Number } else { [int]$Exception.Number }

    switch ($number) {
        18456 {
            return 'Login failed: wrong username/password, login is disabled, or this SQL Server instance does not accept that login.'
        }
        4060 {
            return 'Login succeeded, but the configured database could not be opened or does not exist.'
        }
        53 {
            return 'Database host unreachable or SQL Server instance was not found.'
        }
        2 {
            return 'Database host unreachable or SQL Server instance was not found.'
        }
        10060 {
            return 'Database did not respond before the connection timed out.'
        }
        10061 {
            return 'Database host reached, but the SQL Server port refused the connection.'
        }
        -2 {
            return 'Database did not respond before the connection timed out.'
        }
        default {
            if ($message -match 'Login failed') {
                return 'Login failed: wrong username/password, login is disabled, or this SQL Server instance does not accept that login.'
            }
            if ($message -match 'network-related|server was not found|could not open a connection') {
                return 'Database host unreachable or SQL Server instance was not found.'
            }
            if ($message -match 'timeout') {
                return 'Database did not respond before the connection timed out.'
            }
            if ($message -match 'certificate chain.*not trusted|authority that is not trusted|SSL Provider') {
                return 'SQL TLS/certificate trust failed.'
            }
            return $message
        }
    }
}

function Test-LooksLikeEncodedBinarySecret {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    if ($trimmed.Length -lt 16 -or $trimmed -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
        return $false
    }

    try {
        $bytes = [Convert]::FromBase64String($trimmed)
        if ($bytes.Count -eq 0) {
            return $false
        }

        $nonPrintableCount = @($bytes | Where-Object { ($_ -lt 32 -and $_ -notin @(9, 10, 13)) -or $_ -gt 126 }).Count
        return (($nonPrintableCount / [double]$bytes.Count) -gt 0.2)
    }
    catch {
        return $false
    }
}

function Get-D4AEnvironmentSecret {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('D4AKEY', 'D4AIV')]
        [string]$Name
    )

    foreach ($scope in 'Process', 'Machine', 'User') {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    throw "Environment variable '$Name' was not found in Process, Machine, or User scope."
}

function Unprotect-D4APassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedPassword,

        [string]$KeyBase64 = (Get-D4AEnvironmentSecret -Name D4AKEY),

        [string]$IVBase64 = (Get-D4AEnvironmentSecret -Name D4AIV)
    )

    $aes = $null
    $decryptor = $null
    $keyBytes = $null
    $ivBytes = $null
    $encryptedBytes = $null
    $decryptedBytes = $null

    try {
        $keyBytes = [Convert]::FromBase64String($KeyBase64)
        $ivBytes = [Convert]::FromBase64String($IVBase64)
        $encryptedBytes = [Convert]::FromBase64String($EncryptedPassword)

        if ($keyBytes.Length -ne 32) {
            throw "D4AKEY must decode to 32 bytes; actual length is $($keyBytes.Length)."
        }
        if ($ivBytes.Length -ne 16) {
            throw "D4AIV must decode to 16 bytes; actual length is $($ivBytes.Length)."
        }

        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $keyBytes
        $aes.IV = $ivBytes

        $decryptor = $aes.CreateDecryptor()
        $decryptedBytes = $decryptor.TransformFinalBlock($encryptedBytes, 0, $encryptedBytes.Length)

        return [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
    }
    catch {
        throw "D4A database password decryption failed: $($_.Exception.Message)"
    }
    finally {
        if ($decryptor) {
            $decryptor.Dispose()
        }
        if ($aes) {
            $aes.Dispose()
        }
        foreach ($buffer in @($keyBytes, $ivBytes, $encryptedBytes, $decryptedBytes)) {
            if ($buffer) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Resolve-D4ADecryptedPassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedPassword,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    $cacheKey = 'd4a-decrypt|' + $EncryptedPassword
    if ($Cache.ContainsKey($cacheKey)) {
        return $Cache[$cacheKey]
    }

    try {
        $plainPassword = Unprotect-D4APassword -EncryptedPassword $EncryptedPassword
        $result = [pscustomobject]@{
            Success = $true
            Password = $plainPassword
            Message = 'D4AKEY/D4AIV decryption succeeded.'
        }
    }
    catch {
        $result = [pscustomobject]@{
            Success = $false
            Password = $null
            Message = $_.Exception.Message
        }
    }

    $Cache[$cacheKey] = $result
    return $result
}

function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][securestring]$SecureString)

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Copy-DbConfigWithPassword {
    param(
        [pscustomobject]$DbConfig,
        [string]$Password,
        [string]$PasswordSource = 'plaintext'
    )

    return [pscustomobject]@{
        Name = $DbConfig.Name
        Line = $DbConfig.Line
        User = $DbConfig.User
        Password = $Password
        PasswordSource = $PasswordSource
        Server = $DbConfig.Server
        Database = $DbConfig.Database
        Port = $DbConfig.Port
        RequestTimeout = $DbConfig.RequestTimeout
        Stream = $DbConfig.Stream
        ParseJSON = $DbConfig.ParseJSON
        Encrypt = $DbConfig.Encrypt
        TrustServerCertificate = $DbConfig.TrustServerCertificate
        PacketSize = $DbConfig.PacketSize
        UseColumnNames = $DbConfig.UseColumnNames
        RowCollectionOnDone = $DbConfig.RowCollectionOnDone
        RowCollectionOnRequestCompletion = $DbConfig.RowCollectionOnRequestCompletion
        PoolMin = $DbConfig.PoolMin
        PoolMax = $DbConfig.PoolMax
        PoolIdleTimeoutMillis = $DbConfig.PoolIdleTimeoutMillis
        PoolRequestTimeout = $DbConfig.PoolRequestTimeout
        PropertyLines = $DbConfig.PropertyLines
    }
}

function Get-InvokeSqlcmdSslParameters {
    $parameters = @{}
    $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $parameters
    }

    if ($command.Parameters.ContainsKey('Encrypt')) {
        $parameters['Encrypt'] = 'Optional'
    }

    if ($command.Parameters.ContainsKey('TrustServerCertificate')) {
        $parameters['TrustServerCertificate'] = $true
    }

    return $parameters
}

function New-InvokeSqlcmdConnectionString {
    param(
        [Parameter(Mandatory = $true)][string]$ServerInstance,
        [AllowNull()][string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $ServerInstance
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $builder['Initial Catalog'] = $Database
    }
    $builder['User ID'] = $Username
    $builder['Password'] = $Password
    $builder['Encrypt'] = $false
    $builder['TrustServerCertificate'] = $true

    return $builder.ConnectionString
}

function Test-IsSqlCertificateTrustMessage {
    param([string]$Message)

    return ($Message -match 'certificate chain.*not trusted' -or
            $Message -match 'authority that is not trusted' -or
            $Message -match 'SSL Provider')
}

function Invoke-DbConfigSqlcmd {
    param(
        [Parameter(Mandatory = $true)][string]$ServerInstance,
        [AllowNull()][string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$QueryTimeout
    )

    $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    $sqlParams = @{
        ServerInstance = $ServerInstance
        Username       = $Username
        Password       = $Password
        Query          = $Query
        QueryTimeout   = $QueryTimeout
        ErrorAction    = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $sqlParams['Database'] = $Database
    }

    foreach ($sslParameter in (Get-InvokeSqlcmdSslParameters).GetEnumerator()) {
        $sqlParams[$sslParameter.Key] = $sslParameter.Value
    }

    try {
        return Invoke-Sqlcmd @sqlParams
    }
    catch {
        $rootMessage = Get-RootExceptionMessage -Exception $_.Exception
        if ((Test-IsSqlCertificateTrustMessage -Message $rootMessage) -and
            $command.Parameters.ContainsKey('ConnectionString')) {
            $connectionString = New-InvokeSqlcmdConnectionString -ServerInstance $ServerInstance -Database $Database -Username $Username -Password $Password
            $fallbackParams = @{
                ConnectionString = $connectionString
                Query            = $Query
                QueryTimeout     = $QueryTimeout
                ErrorAction      = 'Stop'
            }

            return Invoke-Sqlcmd @fallbackParams
        }

        throw
    }
}

function Test-SqlCredentialAgainstDataSource {
    param(
        [pscustomobject]$DbConfig,
        [string]$DataSource,
        [int]$TimeoutSeconds
    )

    $result = [ordered]@{
        Name = $DbConfig.Name
        Server = $DataSource
        Database = $DbConfig.Database
        User = $DbConfig.User
        Status = 'ERROR'
        Detail = ''
        AvailableDatabases = @()
    }

    try {
        Add-Type -AssemblyName System.Data | Out-Null

        $databaseRows = Invoke-DbConfigSqlcmd -ServerInstance $DataSource -Database $null -Username ([string]$DbConfig.User) -Password ([string]$DbConfig.Password) -Query 'select name from sys.databases order by name;' -QueryTimeout $TimeoutSeconds
        if ($null -ne $databaseRows) {
            $databases = @($databaseRows | Select-Object -ExpandProperty name)
            $result.AvailableDatabases = @($databases)
            if ($databases -inotcontains [string]$DbConfig.Database) {
                $result.Detail = "Login succeeded on '$DataSource' using Invoke-Sqlcmd, but database '$($DbConfig.Database)' was not found."
                return [pscustomobject]$result
            }

            [void](Invoke-DbConfigSqlcmd -ServerInstance $DataSource -Database ([string]$DbConfig.Database) -Username ([string]$DbConfig.User) -Password ([string]$DbConfig.Password) -Query 'select 1 as ConnectionTest;' -QueryTimeout $TimeoutSeconds)
            $result.Status = 'OK'
            $result.Detail = "Connection succeeded on '$DataSource' using Invoke-Sqlcmd; database '$($DbConfig.Database)' was found and opened."
            return [pscustomobject]$result
        }

        $connectionString = New-SqlConnectionString -DbConfig $DbConfig -DataSource $DataSource -Database 'master' -TimeoutSeconds $TimeoutSeconds
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        try {
            $connection.Open()

            $command = $connection.CreateCommand()
            $command.CommandTimeout = $TimeoutSeconds
            $command.CommandText = 'select name from sys.databases order by name;'

            $databases = New-Object System.Collections.Generic.List[string]
            $reader = $command.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $databases.Add([string]$reader['name']) | Out-Null
                }
            }
            finally {
                $reader.Close()
                $reader.Dispose()
                $command.Dispose()
            }

            $result.AvailableDatabases = @($databases)
            if ($databases -inotcontains [string]$DbConfig.Database) {
                $result.Detail = "Login succeeded on '$DataSource', but database '$($DbConfig.Database)' was not found."
                return [pscustomobject]$result
            }

            $connection.ChangeDatabase([string]$DbConfig.Database)
            $result.Status = 'OK'
            $result.Detail = "Connection succeeded on '$DataSource'; database '$($DbConfig.Database)' was found and opened."
        }
        finally {
            if ($connection.State -ne 'Closed') {
                $connection.Close()
            }
            $connection.Dispose()
        }
    }
    catch [System.Data.SqlClient.SqlException] {
        $result.Detail = Convert-SqlExceptionToDetail -Exception $_.Exception
    }
    catch {
        $result.Detail = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Test-SqlCredential {
    param(
        [pscustomobject]$DbConfig,
        [int]$TimeoutSeconds
    )

    $candidates = @(Get-SqlDataSourceCandidates -DbConfig $DbConfig)
    $attempts = New-Object System.Collections.Generic.List[object]

    foreach ($dataSource in $candidates) {
        $attempt = Test-SqlCredentialAgainstDataSource -DbConfig $DbConfig -DataSource $dataSource -TimeoutSeconds $TimeoutSeconds
        $attempts.Add($attempt) | Out-Null
        if ($attempt.Status -eq 'OK') {
            if ($dataSource -ne [string]$DbConfig.Server) {
                $attempt.Detail = "$($attempt.Detail) Config server '$($DbConfig.Server)' resolved by probing local SQL instances."
            }
            return $attempt
        }
    }

    $primary = $attempts | Select-Object -First 1
    if ($null -eq $primary) {
        return [pscustomobject]@{
            Name = $DbConfig.Name
            Server = $DbConfig.Server
            Database = $DbConfig.Database
            User = $DbConfig.User
            Status = 'ERROR'
            Detail = 'No SQL Server connection candidates were available.'
            AvailableDatabases = @()
        }
    }

    if ($attempts.Count -gt 1) {
        $summary = @($attempts | ForEach-Object { "$($_.Server): $($_.Detail)" }) -join ' | '
        $primary.Detail = "All local SQL instance attempts failed for config server '$($DbConfig.Server)'. $summary"
    }

    if ((Test-LooksLikeEncodedBinarySecret -Value ([string]$DbConfig.Password)) -and
        $primary.Detail -match 'Login failed') {
        $primary.Detail = "$($primary.Detail) The configured password value looks like encoded or encrypted binary data; if the Node app decrypts it at runtime, this scanner needs the decrypted SQL password or the decryption logic to validate the login."
    }

    return $primary
}

function Resolve-DbConfigConnection {
    param(
        [pscustomobject]$DbConfig,
        [int]$TimeoutSeconds,
        [hashtable]$PasswordRetryCache,
        [switch]$NoPasswordPrompt
    )

    $activeDbConfig = $DbConfig
    $usedD4ADecryption = $false
    $d4aDecryptionFailedMessage = $null

    if (Test-LooksLikeEncodedBinarySecret -Value ([string]$DbConfig.Password)) {
        $d4aPassword = Resolve-D4ADecryptedPassword -EncryptedPassword ([string]$DbConfig.Password) -Cache $PasswordRetryCache
        if ($d4aPassword.Success -and -not [string]::IsNullOrEmpty($d4aPassword.Password)) {
            $activeDbConfig = Copy-DbConfigWithPassword -DbConfig $DbConfig -Password ([string]$d4aPassword.Password) -PasswordSource 'd4a-decrypted'
            $usedD4ADecryption = $true
            Write-Result -Level INFO -Message "$($DbConfig.Name): decrypted stored database password with D4AKEY/D4AIV."
        }
        else {
            $d4aDecryptionFailedMessage = $d4aPassword.Message
        }
    }

    $dbTest = Test-SqlCredential -DbConfig $activeDbConfig -TimeoutSeconds $TimeoutSeconds
    $usedPromptedPassword = $false

    if ($dbTest.Status -eq 'OK' -and $usedD4ADecryption) {
        $dbTest.Detail = "$($dbTest.Detail) Validated with the D4A-decrypted dbconfig password."
    }

    if ($dbTest.Status -ne 'OK' -and $usedD4ADecryption) {
        $dbTest.Detail = "D4A-decrypted dbconfig password was used, but the login still failed: $($dbTest.Detail)"
    }

    if ($dbTest.Status -ne 'OK' -and
        -not $usedD4ADecryption -and
        -not $NoPasswordPrompt -and
        (Test-LooksLikeEncodedBinarySecret -Value ([string]$DbConfig.Password)) -and
        $dbTest.Detail -match 'Login failed') {
        if ($d4aDecryptionFailedMessage) {
            Write-Result -Level WARN -Message "$($DbConfig.Name): automatic D4A password decryption was not available. $d4aDecryptionFailedMessage"
        }

        $retryCacheKey = '{0}|{1}' -f $DbConfig.User, $DbConfig.Password
        $plainRetryPassword = $null

        if ($PasswordRetryCache.ContainsKey($retryCacheKey)) {
            $plainRetryPassword = $PasswordRetryCache[$retryCacheKey]
        }
        else {
            Write-Result -Level WARN -Message "$($DbConfig.Name): the stored password looks encoded or encrypted. Enter the decrypted SQL password for user '$($DbConfig.User)' to retry, or press Enter to skip."
            $secureRetryPassword = Read-Host "Decrypted SQL password for $($DbConfig.User)" -AsSecureString
            $plainRetryPassword = ConvertFrom-SecureStringToPlainText -SecureString $secureRetryPassword
            $PasswordRetryCache[$retryCacheKey] = $plainRetryPassword
        }

        if (-not [string]::IsNullOrEmpty($plainRetryPassword)) {
            $activeDbConfig = Copy-DbConfigWithPassword -DbConfig $DbConfig -Password $plainRetryPassword -PasswordSource 'prompted-plaintext'
            $retryTest = Test-SqlCredential -DbConfig $activeDbConfig -TimeoutSeconds $TimeoutSeconds
            if ($retryTest.Status -eq 'OK') {
                $retryTest.Detail = "$($retryTest.Detail) Validated by retrying with the decrypted SQL password entered at the prompt."
                $dbTest = $retryTest
                $usedPromptedPassword = $true
            }
            else {
                $dbTest.Detail = "Config password failed. Prompted decrypted-password retry also failed: $($retryTest.Detail)"
            }
        }
    }

    return [pscustomobject]@{
        DbConfig = $activeDbConfig
        Test = $dbTest
        UsedD4ADecryption = $usedD4ADecryption
        UsedPromptedPassword = $usedPromptedPassword
    }
}

function Invoke-UserTableSettingsProbe {
    param(
        [pscustomobject]$DbConfig,
        [string]$DataSource,
        [string]$ConfigPath,
        [int[]]$PayloadSizes,
        [int]$TimeoutSeconds,
        [bool]$AllowUnencryptedDiagnostic = $false,
        [bool]$RunExtendedConfigSimulations = $true
    )

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCommand) {
        throw 'Node.js was not found in PATH. This probe must use the same Node mssql driver path as the application.'
    }

    $configDirectory = Split-Path -Parent $ConfigPath
    $helperPath = Join-Path ([IO.Path]::GetTempPath()) ("dbconfig-user-table-settings-probe-{0}.js" -f ([guid]::NewGuid().ToString('N')))
    $payloadPath = Join-Path ([IO.Path]::GetTempPath()) ("dbconfig-user-table-settings-probe-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $passwordSource = if ($DbConfig.PSObject.Properties.Name -contains 'PasswordSource') { [string]$DbConfig.PasswordSource } else { 'config' }
    $payload = [pscustomobject]@{
        configPath = $ConfigPath
        configName = $DbConfig.Name
        dataSource = $DataSource
        user = $DbConfig.User
        passwordSource = $passwordSource
        database = $DbConfig.Database
        timeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000)
        payloadSizes = @($PayloadSizes | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
        allowUnencryptedDiagnostic = $AllowUnencryptedDiagnostic
        runExtendedConfigSimulations = $RunExtendedConfigSimulations
        propertyLines = $DbConfig.PropertyLines
    }

    $helper = @'
const fs = require("fs");
const path = require("path");

function emit(type, data = {}) {
  console.log("D4A_PROBE " + JSON.stringify(Object.assign({ type }, data)));
}

function loadMssql(configDirectory) {
  const failures = [];
  for (const candidate of [configDirectory, path.dirname(configDirectory), process.cwd()]) {
    try {
      return require(require.resolve("mssql", { paths: [candidate] }));
    } catch (error) {
      failures.push(candidate + ": " + error.message);
    }
  }
  try {
    return require("mssql");
  } catch (error) {
    failures.push("global: " + error.message);
  }
  throw new Error("mssql module could not be loaded. " + failures.join(" | "));
}

function applyDataSource(cfg, dataSource) {
  const value = String(dataSource || "").trim();
  cfg.options = cfg.options || {};
  delete cfg.options.instanceName;

  const commaIndex = value.lastIndexOf(",");
  if (commaIndex > -1) {
    cfg.server = value.slice(0, commaIndex);
    cfg.port = Number(value.slice(commaIndex + 1));
    return;
  }

  const slashIndex = value.indexOf("\\");
  if (slashIndex > -1) {
    cfg.server = value.slice(0, slashIndex);
    cfg.options.instanceName = value.slice(slashIndex + 1);
    delete cfg.port;
    return;
  }

  cfg.server = value;
}

function errorDetails(error) {
  const original = error && error.originalError ? error.originalError : null;
  const cause = error && error.cause ? error.cause : null;
  const rawMessage = (original && original.message) || (error && error.message) || String(error);
  const nestedCode = [
    cause && cause.code,
    original && original.code,
    error && error.parent && error.parent.code
  ].find(Boolean);
  const inferredSocketCode = String(rawMessage).match(/\b(ECONNRESET|ECONNREFUSED|ETIMEDOUT|ESOCKET|EPIPE)\b/i);
  return {
    name: error && error.name ? error.name : null,
    code: (error && error.code) || (original && original.code) || (cause && cause.code) || null,
    number: (error && error.number) || (original && original.number) || null,
    message: rawMessage,
    causeMessage: cause && cause.message ? cause.message : null,
    causeCode: nestedCode || (inferredSocketCode ? inferredSocketCode[1].toUpperCase() : null)
  };
}

function classifyFailure(details) {
  const text = [details.code, details.causeCode, details.message, details.causeMessage].filter(Boolean).join(" ");
  if (/certificate|self signed|unable to verify|CERT_/i.test(text)) return "TLS_CERTIFICATE";
  if (/ECONNRESET|ESOCKET|Connection lost|socket hang up|forcibly closed/i.test(text)) return "TRANSPORT_RESET";
  if (/ELOGIN|Login failed/i.test(text)) return "LOGIN_FAILED";
  if (/ETIMEOUT|timed out|timeout/i.test(text)) return "TIMEOUT";
  if (/ECONNREFUSED|actively refused/i.test(text)) return "CONNECTION_REFUSED";
  if (/ENOTFOUND|getaddrinfo|server was not found|network-related/i.test(text)) return "HOST_OR_INSTANCE_NOT_FOUND";
  if (/Could not find stored procedure|is not a procedure/i.test(text)) return "PROCEDURE_MISSING";
  if (/is not a parameter for procedure|expects parameter/i.test(text)) return "PROCEDURE_SIGNATURE";
  if (/permission|denied|not authorized/i.test(text)) return "PERMISSION_DENIED";
  if (/String or binary data would be truncated|would be truncated/i.test(text)) return "DATABASE_TRUNCATION";
  return "UNCLASSIFIED";
}

async function getSessionInfo(pool) {
  try {
    const result = await pool.request().query(`
      SELECT TOP (1)
        encrypt_option AS encryptOption,
        net_transport AS netTransport,
        protocol_type AS protocolType,
        auth_scheme AS authScheme,
        net_packet_size AS negotiatedPacketSize
      FROM sys.dm_exec_connections
      WHERE session_id = @@SPID;`);
    return result.recordset && result.recordset[0] ? result.recordset[0] : null;
  } catch (error) {
    return { inspectionError: errorDetails(error).message };
  }
}

async function runScenario(sql, baseConfig, payload, scenarioName, overrides) {
  const cfg = Object.assign({}, baseConfig);
  Object.assign(cfg, overrides.config || {});
  cfg.options = Object.assign({}, baseConfig.options || {}, overrides.options || {});
  cfg.connectionTimeout = payload.timeoutMs;
  cfg.requestTimeout = payload.timeoutMs;
  const mode = overrides.mode || "application_query";

  emit("scenario_start", {
    scenario: scenarioName,
    mode,
    encrypt: cfg.options.encrypt,
    trustServerCertificate: cfg.options.trustServerCertificate,
    packetSize: cfg.options.packetSize === undefined ? null : cfg.options.packetSize,
    stream: cfg.stream === undefined ? null : cfg.stream,
    parseJSON: cfg.parseJSON === undefined ? null : cfg.parseJSON,
    useColumnNames: cfg.options.useColumnNames === undefined ? null : cfg.options.useColumnNames,
    rowCollectionOnDone: cfg.options.rowCollectionOnDone === undefined ? null : cfg.options.rowCollectionOnDone,
    rowCollectionOnRequestCompletion: cfg.options.rowCollectionOnRequestCompletion === undefined ? null : cfg.options.rowCollectionOnRequestCompletion
  });

  const rows = [];
  let firstFailure = null;
  let firstSessionInfo = null;

  for (const requestedSize of payload.payloadSizes) {
    let pool = null;
    let transaction = null;
    const tableSettings = JSON.stringify({ pad: "x".repeat(requestedSize) });
    const actualBytes = Buffer.byteLength(tableSettings, "utf8");
    let stage = "connect";
    let sqlBatch = null;

    try {
      pool = await new sql.ConnectionPool(cfg).connect();
      if (!firstSessionInfo) firstSessionInfo = await getSessionInfo(pool);

      stage = "begin rollback-only transaction";
      transaction = new sql.Transaction(pool);
      await transaction.begin();

      if (mode === "direct_parameter") {
        stage = "send direct nvarchar(max) parameter control";
        await new sql.Request(transaction)
          .input("Payload", sql.NVarChar(sql.MAX), tableSettings)
          .query("SELECT DATALENGTH(@Payload) AS PayloadBytes");
      } else if (mode === "procedure_rpc") {
        stage = "execute parameterized D4A_UpdateUserTableSettings RPC";
        await new sql.Request(transaction)
          .input("UserId", sql.NVarChar(50), null)
          .input("TableId", sql.NVarChar(50), "**D4A_PROBE**")
          .input("TableSettings", sql.NVarChar(sql.MAX), tableSettings)
          .execute("D4A_UpdateUserTableSettings");
      } else {
        stage = "execute application-style D4A_UpdateUserTableSettings SQL batch";
        const escapedSettings = tableSettings.replace(/[\/\(\)\']/g, "''");
        sqlBatch = "exec D4A_UpdateUserTableSettings null,'**D4A_PROBE**','" + escapedSettings + "'";
        await new sql.Request(transaction).query(sqlBatch);
      }

      stage = "rollback probe transaction";
      await transaction.rollback();
      transaction = null;

      const row = { scenario: scenarioName, mode, requestedSize, actualBytes, status: "OK" };
      rows.push(row);
      emit("probe", row);
    } catch (error) {
      const details = errorDetails(error);
      const category = classifyFailure(details);
      const row = Object.assign({
        scenario: scenarioName,
        mode,
        requestedSize,
        actualBytes,
        status: "FAIL",
        stage,
        category,
        sqlBatch
      }, details);
      rows.push(row);
      firstFailure = row;
      emit("probe", row);

      if (transaction) {
        try { await transaction.rollback(); } catch (_) {}
        transaction = null;
      }
      break;
    } finally {
      if (pool) {
        try { await pool.close(); } catch (_) {}
      }
    }
  }

  const result = {
    scenario: scenarioName,
    mode,
    encrypt: cfg.options.encrypt,
    trustServerCertificate: cfg.options.trustServerCertificate,
    packetSize: cfg.options.packetSize === undefined ? null : cfg.options.packetSize,
    stream: cfg.stream === undefined ? null : cfg.stream,
    parseJSON: cfg.parseJSON === undefined ? null : cfg.parseJSON,
    useColumnNames: cfg.options.useColumnNames === undefined ? null : cfg.options.useColumnNames,
    rowCollectionOnDone: cfg.options.rowCollectionOnDone === undefined ? null : cfg.options.rowCollectionOnDone,
    rowCollectionOnRequestCompletion: cfg.options.rowCollectionOnRequestCompletion === undefined ? null : cfg.options.rowCollectionOnRequestCompletion,
    sessionInfo: firstSessionInfo,
    firstFailure,
    passed: !firstFailure,
    rows
  };
  emit("scenario_end", result);
  return result;
}

function settingLine(propertyLines, key) {
  const raw = propertyLines && propertyLines[key];
  const line = Number(raw);
  return Number.isFinite(line) && line > 0 ? `line: ${line}` : "property not explicitly configured";
}

function settingValueWithLine(propertyLines, key, value) {
  return `${key}=${value} (${settingLine(propertyLines, key)})`;
}

function buildDiagnosis(config, runtime, baseline, encryptedRetry, unencryptedRetry, trustRetry, directControl, rpcControl, packetRetries, configRetries, propertyLines) {
  if (baseline.passed) {
    return {
      severity: "OK",
      code: "ALL_PAYLOADS_ACCEPTED",
      message: "The configured dbConfigTampa transport accepted every requested payload size."
    };
  }

  const failure = baseline.firstFailure;
  if (failure.category === "TRANSPORT_RESET" && config.options.encrypt !== true) {
    if (encryptedRetry && encryptedRetry.passed) {
      return {
        severity: "ERROR",
        code: "ENCRYPT_FALSE_CONFIRMED",
        message: `Configured ${settingValueWithLine(propertyLines, "encrypt", config.options.encrypt)} resets on a larger request, while the controlled encrypt=true retry accepts all payloads. Set dbConfigTampa.options.encrypt=true at ${settingLine(propertyLines, "encrypt")}, then restart the API service.`
      };
    }
    if (encryptedRetry && encryptedRetry.firstFailure && encryptedRetry.firstFailure.category === "TLS_CERTIFICATE") {
      return {
        severity: "ERROR",
        code: "ENCRYPT_REQUIRED_CERTIFICATE_FAILED",
        message: `The unencrypted path resets, and the encrypted retry reaches a TLS certificate validation problem. Review encrypt (${settingLine(propertyLines, "encrypt")}) and trustServerCertificate (${settingLine(propertyLines, "trustServerCertificate")}) and correct SQL certificate trust rather than returning to encrypt=false.`
      };
    }
    return {
      severity: "ERROR",
      code: "TRANSPORT_RESET_WITH_ENCRYPT_DISABLED",
      message: `A larger SQL request resets the transport while ${settingValueWithLine(propertyLines, "encrypt", config.options.encrypt)}. The encrypt=true retry does not fully pass, so inspect its first failure before changing additional settings.`
    };
  }

  if (failure.category === "TRANSPORT_RESET") {
    const passingPacketRetry = (packetRetries || []).find(item => item && item.passed);
    const mssqlMajor = Number(String(runtime.mssqlVersion || "0").split(".")[0]) || 0;
    const nodeMajor = Number(String(runtime.nodeVersion || "0").replace(/^v/, "").split(".")[0]) || 0;
    const unencryptedNegotiation = unencryptedRetry && unencryptedRetry.sessionInfo
      ? String(unencryptedRetry.sessionInfo.encryptOption || "").toUpperCase()
      : "";

    if (config.options.encrypt === true && unencryptedRetry && unencryptedRetry.passed) {
      if (unencryptedNegotiation === "FALSE" && passingPacketRetry) {
        return {
          severity: "ERROR",
          code: "ENCRYPTED_TDS_PACKET_PATH_CONFIRMED",
          message: `The exact payloads fail with encrypt=true (${settingLine(propertyLines, "encrypt")}) and the default packet path, but pass with encrypt=false. SQL confirms that the comparison connection was unencrypted. The same payloads also pass while still encrypted when packetSize=${passingPacketRetry.packetSize}; packetSize is ${settingLine(propertyLines, "packetSize")} and the options block is ${settingLine(propertyLines, "options")}. This proves that credentials, procedure logic, and certificate negotiation are not the defect. The practical root cause is fragmentation in the encrypted TDS path, with legacy node-mssql ${runtime.mssqlVersion} on Node ${runtime.nodeVersion} as the leading compatibility risk. Recommended secure fix: keep encrypt=true and set packetSize=${passingPacketRetry.packetSize}. Use encrypt=false only as a temporary exception on an approved trusted network.`
        };
      }

      if (unencryptedNegotiation === "FALSE") {
        return {
          severity: "ERROR",
          code: "ENCRYPTED_TDS_PATH_CONFIRMED",
          message: `The exact payloads fail with encrypt=true (${settingLine(propertyLines, "encrypt")}) and pass with encrypt=false, and SQL confirms that the comparison connection was unencrypted. This isolates the trigger to the encrypted TDS transport path rather than login credentials or procedure data. Do not treat encrypt=false as the preferred permanent fix: validate the SQL TLS path and upgrade node-mssql/tedious or use a confirmed encrypted packetSize workaround.`
        };
      }

      return {
        severity: "ERROR",
        code: "CLIENT_ENCRYPT_OPTION_PATH_CONFIRMED",
        message: `The encrypt=false client control for encrypt (${settingLine(propertyLines, "encrypt")}) passes, but SQL still reports negotiated encryption=${unencryptedNegotiation || "unknown"}. Therefore this test does not prove that removing wire encryption fixes the issue; it proves that changing the client's encryption option changes the driver path. Keep encryption enabled and prioritize the confirmed encrypted packetSize result or a node-mssql/tedious upgrade.`
      };
    }

    if (rpcControl && rpcControl.passed) {
      return {
        severity: "ERROR",
        code: "APPLICATION_SQL_BATCH_CONFIRMED",
        message: "The connection is encrypted correctly. The application-style concatenated SQL batch resets, while a typed parameterized call to the same stored procedure accepts the same payload. This isolates the defect to how server.js builds /api/updateUserTableSettings, not to the procedure or data. Permanently replace the concatenated query with typed .input() parameters and .execute('D4A_UpdateUserTableSettings')."
      };
    }

    if (directControl && directControl.passed && rpcControl && !rpcControl.passed) {
      return {
        severity: "ERROR",
        code: "PROCEDURE_PATH_RESET_CONFIRMED",
        message: "SQL accepts the same nvarchar(max) payload in a direct parameter test, but the D4A_UpdateUserTableSettings procedure call resets. Inspect that procedure, its target UserTableSettings table, SQL Server error logs, triggers, and cross-database dependencies."
      };
    }

    if (passingPacketRetry) {
      const legacyText = mssqlMajor > 0 && mssqlMajor <= 5
        ? ` The site is also using legacy node-mssql ${runtime.mssqlVersion} with Node ${runtime.nodeVersion}, which is a high-risk driver/runtime combination for large TDS writes.`
        : "";
      return {
        severity: "ERROR",
        code: "PACKET_SIZE_FRAGMENTATION_CONFIRMED",
        message: `The connection is encrypted correctly. The default SQL transport resets at the first large-payload packet boundary, including the direct parameter and parameterized procedure controls, but all payloads pass when packetSize=${passingPacketRetry.packetSize}. packetSize is ${settingLine(propertyLines, "packetSize")}; options is ${settingLine(propertyLines, "options")}.${legacyText} Short-term: add or update packetSize: ${passingPacketRetry.packetSize} under dbConfigTampa.options and restart the API. Permanent: validate an upgrade of node-mssql/tedious against the D4A release.`
      };
    }

    const passingConfigRetry = (configRetries || []).find(item => item && item.passed);
    if (passingConfigRetry) {
      return {
        severity: "ERROR",
        code: "DBCONFIG_SETTING_SIMULATION_CONFIRMED",
        message: `The configured path fails, but every payload passes when only ${passingConfigRetry.settingKey} is changed from ${String(passingConfigRetry.originalValue)} to ${String(passingConfigRetry.candidateValue)}. The affected setting is at ${settingLine(propertyLines, passingConfigRetry.settingKey)}. This isolates the behavior to that dbConfigTampa variable; apply the candidate value, restart the API, and rerun the full probe to confirm.`
      };
    }

    if (directControl && !directControl.passed) {
      const compatibility = mssqlMajor > 0 && mssqlMajor <= 5 && nodeMajor >= 20
        ? ` The site is running legacy node-mssql ${runtime.mssqlVersion} on Node ${runtime.nodeVersion}; prioritize testing a supported driver/runtime combination.`
        : "";
      return {
        severity: "ERROR",
        code: "TDS_TRANSPORT_FRAGMENTATION",
        message: `The reset also occurs with a plain nvarchar(max) parameter, before D4A_UpdateUserTableSettings logic is relevant. This isolates the failure to the Node/Tedious TDS transport, SQL endpoint, or a network/security device handling fragmented SQL packets.${compatibility} Review the packet-size retry rows and SQL/network reset logs.`
      };
    }
  }

  if (failure.category === "TLS_CERTIFICATE" && trustRetry && trustRetry.passed) {
    return {
      severity: "ERROR",
      code: "SQL_CERTIFICATE_TRUST_CONFIRMED",
      message: `TLS succeeds only when trustServerCertificate=true. The affected setting is trustServerCertificate (${settingLine(propertyLines, "trustServerCertificate")}); encrypt is at ${settingLine(propertyLines, "encrypt")}. This confirms a SQL certificate trust or hostname-chain problem. Using trustServerCertificate=true is a diagnostic/temporary workaround; the permanent fix is a certificate trusted by the API host whose name matches the configured SQL server.`
    };
  }

  const messages = {
    LOGIN_FAILED: `SQL login failed. Verify user (${settingLine(propertyLines, "user")}) and password (${settingLine(propertyLines, "password")}), decrypt the password with the matching D4AKEY/D4AIV, and verify that the login is enabled.`,
    TIMEOUT: `The SQL operation timed out. Verify server (${settingLine(propertyLines, "server")}), port (${settingLine(propertyLines, "port")}), requestTimeout (${settingLine(propertyLines, "requestTimeout")}), blocking, and procedure runtime.`,
    CONNECTION_REFUSED: `The target host was reached but the configured SQL endpoint refused the connection. Verify server (${settingLine(propertyLines, "server")}) and port (${settingLine(propertyLines, "port")}).`,
    HOST_OR_INSTANCE_NOT_FOUND: `The configured SQL server, instance, DNS name, or port could not be resolved or reached. Verify server (${settingLine(propertyLines, "server")}) and port (${settingLine(propertyLines, "port")}).`,
    TLS_CERTIFICATE: `SQL TLS negotiation failed. Verify encrypt (${settingLine(propertyLines, "encrypt")}), trustServerCertificate (${settingLine(propertyLines, "trustServerCertificate")}), and the SQL Server certificate chain/name.`,
    PROCEDURE_MISSING: `D4A_UpdateUserTableSettings is missing from the configured database or the wrong database is configured at ${settingLine(propertyLines, "database")}.`,
    PROCEDURE_SIGNATURE: "The installed D4A_UpdateUserTableSettings parameter signature does not match the application call.",
    PERMISSION_DENIED: "The configured SQL login lacks permission to execute the procedure or access one of its referenced objects.",
    DATABASE_TRUNCATION: "A target database column is too short for the tested payload.",
    TRANSPORT_RESET: "The SQL transport was reset. Compare encryption, negotiated packet size, SQL/network logs, and the encrypted retry result.",
    UNCLASSIFIED: "The probe failed with an unclassified error. Review the structured stage, code, cause code, and message."
  };

  return {
    severity: "ERROR",
    code: failure.category,
    message: messages[failure.category] || messages.UNCLASSIFIED
  };
}

async function main() {
  const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, ""));
  const configPath = path.resolve(payload.configPath);
  const configDirectory = path.dirname(configPath);
  process.chdir(configDirectory);

  const sql = loadMssql(configDirectory);
  const loaded = require(configPath);
  const allConfig = loaded && loaded.default ? loaded.default : loaded;
  if (!allConfig || !allConfig[payload.configName]) {
    throw new Error("Exported config object " + payload.configName + " was not found in " + configPath);
  }

  const cfg = Object.assign({}, allConfig[payload.configName]);
  cfg.options = Object.assign({}, cfg.options || {});
  applyDataSource(cfg, payload.dataSource);
  cfg.user = payload.user;
  cfg.password = process.env.D4A_PROBE_PASSWORD;
  cfg.database = payload.database;
  if (!cfg.password) throw new Error("The probe password was not supplied to the child process.");

  const configuredEncrypt = cfg.options.encrypt;
  const configuredTrust = cfg.options.trustServerCertificate;
  if (cfg.options.encrypt === undefined) cfg.options.encrypt = false;
  if (cfg.options.trustServerCertificate === undefined) cfg.options.trustServerCertificate = true;

  emit("runtime_config", {
    configName: payload.configName,
    server: cfg.server,
    instanceName: cfg.options.instanceName || null,
    port: cfg.port || null,
    database: cfg.database,
    encryptConfigured: configuredEncrypt === undefined ? null : configuredEncrypt,
    encryptEffective: cfg.options.encrypt,
    trustServerCertificateConfigured: configuredTrust === undefined ? null : configuredTrust,
    trustServerCertificateEffective: cfg.options.trustServerCertificate,
    packetSize: cfg.options.packetSize === undefined ? null : cfg.options.packetSize,
    useColumnNames: cfg.options.useColumnNames === undefined ? null : cfg.options.useColumnNames,
    rowCollectionOnDone: cfg.options.rowCollectionOnDone === undefined ? null : cfg.options.rowCollectionOnDone,
    rowCollectionOnRequestCompletion: cfg.options.rowCollectionOnRequestCompletion === undefined ? null : cfg.options.rowCollectionOnRequestCompletion,
    stream: cfg.stream === undefined ? null : cfg.stream,
    parseJSON: cfg.parseJSON === undefined ? null : cfg.parseJSON,
    requestTimeout: cfg.requestTimeout === undefined ? null : cfg.requestTimeout,
    mssqlVersion: (() => { try { return require(require.resolve("mssql/package.json", { paths: [configDirectory] })).version; } catch (_) { return null; } })(),
    nodeVersion: process.version,
    passwordSource: payload.passwordSource
  });

  const runtime = {
    mssqlVersion: (() => { try { return require(require.resolve("mssql/package.json", { paths: [configDirectory] })).version; } catch (_) { return null; } })(),
    nodeVersion: process.version
  };

  const baseline = await runScenario(sql, cfg, payload, "configured_application_path", { options: {}, mode: "application_query" });
  let encryptedRetry = null;
  if (!baseline.passed && baseline.firstFailure.category === "TRANSPORT_RESET" && cfg.options.encrypt !== true) {
    encryptedRetry = await runScenario(sql, cfg, payload, "diagnostic_encrypt_true", {
      options: { encrypt: true, trustServerCertificate: cfg.options.trustServerCertificate },
      mode: "application_query"
    });
  }

  let unencryptedRetry = null;
  if (!baseline.passed && baseline.firstFailure.category === "TRANSPORT_RESET" && cfg.options.encrypt === true && payload.allowUnencryptedDiagnostic === true) {
    unencryptedRetry = await runScenario(sql, cfg, payload, "diagnostic_encrypt_false", {
      options: { encrypt: false },
      mode: "application_query"
    });
  }

  let trustRetry = null;
  if (!baseline.passed && baseline.firstFailure.category === "TLS_CERTIFICATE" && cfg.options.trustServerCertificate !== true && payload.runExtendedConfigSimulations === true) {
    trustRetry = await runScenario(sql, cfg, payload, "diagnostic_trust_server_certificate_true", {
      options: { trustServerCertificate: true },
      mode: "application_query"
    });
  }

  let directControl = null;
  let rpcControl = null;
  const packetRetries = [];
  const unresolvedReset = !baseline.passed && baseline.firstFailure.category === "TRANSPORT_RESET" && (!encryptedRetry || !encryptedRetry.passed);
  if (unresolvedReset) {
    const failurePayload = Object.assign({}, payload, { payloadSizes: [baseline.firstFailure.requestedSize] });
    directControl = await runScenario(sql, cfg, failurePayload, "control_direct_parameter", { options: {}, mode: "direct_parameter" });
    rpcControl = await runScenario(sql, cfg, failurePayload, "control_parameterized_rpc", { options: {}, mode: "procedure_rpc" });

    for (const packetSize of [8192, 16368]) {
      const retry = await runScenario(sql, cfg, payload, "diagnostic_packet_size_" + packetSize, {
        options: { packetSize },
        mode: "application_query"
      });
      packetRetries.push(retry);
      if (retry.passed) break;
    }
  }

  const configRetries = [];
  const specificControlPassed = Boolean(
    (unencryptedRetry && unencryptedRetry.passed) ||
    (rpcControl && rpcControl.passed) ||
    packetRetries.some(item => item && item.passed)
  );
  if (unresolvedReset && !specificControlPassed && payload.runExtendedConfigSimulations === true) {
    const candidates = [
      { key: "stream", originalValue: cfg.stream, candidateValue: cfg.stream === true ? false : true, config: { stream: cfg.stream === true ? false : true }, options: {} },
      { key: "parseJSON", originalValue: cfg.parseJSON, candidateValue: cfg.parseJSON === true ? false : true, config: { parseJSON: cfg.parseJSON === true ? false : true }, options: {} },
      { key: "useColumnNames", originalValue: cfg.options.useColumnNames, candidateValue: cfg.options.useColumnNames === true ? false : true, config: {}, options: { useColumnNames: cfg.options.useColumnNames === true ? false : true } },
      { key: "rowCollectionOnDone", originalValue: cfg.options.rowCollectionOnDone, candidateValue: cfg.options.rowCollectionOnDone === true ? false : true, config: {}, options: { rowCollectionOnDone: cfg.options.rowCollectionOnDone === true ? false : true } },
      { key: "rowCollectionOnRequestCompletion", originalValue: cfg.options.rowCollectionOnRequestCompletion, candidateValue: cfg.options.rowCollectionOnRequestCompletion === true ? false : true, config: {}, options: { rowCollectionOnRequestCompletion: cfg.options.rowCollectionOnRequestCompletion === true ? false : true } }
    ];

    for (const candidate of candidates) {
      const retry = await runScenario(sql, cfg, payload, `diagnostic_config_${candidate.key}_${String(candidate.candidateValue)}`, {
        config: candidate.config,
        options: candidate.options,
        mode: "application_query"
      });
      retry.settingKey = candidate.key;
      retry.originalValue = candidate.originalValue === undefined ? null : candidate.originalValue;
      retry.candidateValue = candidate.candidateValue;
      configRetries.push(retry);
      if (retry.passed) break;
    }
  }

  emit("summary", buildDiagnosis(cfg, runtime, baseline, encryptedRetry, unencryptedRetry, trustRetry, directControl, rpcControl, packetRetries, configRetries, payload.propertyLines || {}));
}

main().catch(error => {
  emit("fatal", Object.assign({ severity: "ERROR", category: classifyFailure(errorDetails(error)) }, errorDetails(error)));
  process.exitCode = 2;
});
'@

    $process = $null
    $stdout = ''
    $stderr = ''
    $exitCode = -1
    $probeWrapperStage = 'prepare Node probe'
    try {
        $probeWrapperStage = 'write temporary Node helper'
        [IO.File]::WriteAllText($helperPath, $helper, [Text.UTF8Encoding]::new($false))
        $probeWrapperStage = 'write temporary probe payload'
        [IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

        $probeWrapperStage = 'configure Node probe process'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $nodeCommand.Source
        $startInfo.Arguments = ('"{0}" "{1}"' -f $helperPath, $payloadPath)
        $startInfo.WorkingDirectory = $configDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['D4A_PROBE_PASSWORD'] = [string]$DbConfig.Password

        $probeWrapperStage = 'start Node probe process'
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Node probe process did not start.'
        }

        $probeWrapperStage = 'read Node probe output'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        # Baseline plus encryption A/B, trust, transport, packet-size, and setting controls may run.
        $payloadSizeCount = [Math]::Max(1, @($payload.payloadSizes).Count)
        $estimatedTimeoutMs = [double]($payloadSizeCount * 13 * ($TimeoutSeconds + 5) * 1000)
        $processTimeoutMs = [int][Math]::Min([int]::MaxValue, [Math]::Max(60000, $estimatedTimeoutMs))
        $probeWrapperStage = 'wait for Node probe process'
        if (-not $process.WaitForExit($processTimeoutMs)) {
            try { $process.Kill() } catch {}
            throw "Node probe exceeded its safety timeout of $([Math]::Round($processTimeoutMs / 1000)) seconds."
        }

        $probeWrapperStage = 'collect Node probe output'
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    catch {
        throw "Probe wrapper failed during $probeWrapperStage. $($_.Exception.Message)"
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    }

    $events = New-Object System.Collections.Generic.List[object]
    $unparsedStdout = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($stdout -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^D4A_PROBE\s+(?<json>{.*})$') {
            try {
                $events.Add(($Matches['json'] | ConvertFrom-Json)) | Out-Null
            }
            catch {
                $unparsedStdout.Add($line) | Out-Null
            }
        }
        else {
            $unparsedStdout.Add($line) | Out-Null
        }
    }

    $stderrWarnings = New-Object System.Collections.Generic.List[string]
    $stderrErrors = New-Object System.Collections.Generic.List[string]
    $stderrText = $stderr.Trim()
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        if ($stderrText -match 'NODE_TLS_REJECT_UNAUTHORIZED.*insecure.*certificate verification') {
            $stderrWarnings.Add('dbconfig.js sets NODE_TLS_REJECT_UNAUTHORIZED=0. This warning is unrelated to the SQL probe result, but it means HTTPS certificate verification is disabled process-wide.') | Out-Null
            $remaining = [regex]::Replace($stderrText, '(?ms)\(node:\d+\) Warning: Setting the NODE_TLS_REJECT_UNAUTHORIZED.*?(?=(?:\r?\n){2}|$)', '').Trim()
            if (-not [string]::IsNullOrWhiteSpace($remaining)) {
                $stderrErrors.Add($remaining) | Out-Null
            }
        }
        else {
            $stderrErrors.Add($stderrText) | Out-Null
        }
    }

    $runtimeConfig = $events | Where-Object { $_.type -eq 'runtime_config' } | Select-Object -Last 1
    $summary = $events | Where-Object { $_.type -eq 'summary' } | Select-Object -Last 1
    $fatal = $events | Where-Object { $_.type -eq 'fatal' } | Select-Object -Last 1
    $scenarioEvents = @($events | Where-Object { $_.type -eq 'scenario_end' })
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($event in @($events | Where-Object { $_.type -eq 'probe' })) {
        $detail = if ($event.status -eq 'OK') {
            'Node mssql stored procedure call succeeded inside a rollback-only transaction.'
        }
        else {
            $detailParts = New-Object System.Collections.Generic.List[string]
            $detailParts.Add("category=$($event.category)") | Out-Null
            $detailParts.Add("stage=$($event.stage)") | Out-Null
            if (-not [string]::IsNullOrWhiteSpace([string]$event.code)) {
                $detailParts.Add("code=$($event.code)") | Out-Null
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$event.causeCode)) {
                $detailParts.Add("causeCode=$($event.causeCode)") | Out-Null
            }
            $detailParts.Add([string]$event.message) | Out-Null
            $detailParts -join '; '
        }
        $rows.Add([pscustomobject]@{
            Scenario = [string]$event.scenario
            PayloadBytes = [int]$event.requestedSize
            ActualBytes = [int]$event.actualBytes
            Status = [string]$event.status
            Detail = $detail
            SqlBatch = if ($event.PSObject.Properties.Name -contains 'sqlBatch') { [string]$event.sqlBatch } else { $null }
        }) | Out-Null
    }

    $baselineScenario = $scenarioEvents | Where-Object { $_.scenario -eq 'configured_application_path' } | Select-Object -Last 1
    $firstFailure = $null
    if ($baselineScenario -and $baselineScenario.firstFailure) {
        $failure = $baselineScenario.firstFailure
        $firstFailure = [pscustomobject]@{
            PayloadBytes = [int]$failure.requestedSize
            ActualBytes = [int]$failure.actualBytes
            Category = [string]$failure.category
            Stage = [string]$failure.stage
            Code = [string]$failure.code
            CauseCode = [string]$failure.causeCode
            Detail = [string]$failure.message
            SqlBatch = if ($failure.PSObject.Properties.Name -contains 'sqlBatch') { [string]$failure.sqlBatch } else { $null }
        }
    }

    if ($exitCode -ne 0 -and -not $fatal) {
        $nodeFailure = if ($stderrErrors.Count -gt 0) { $stderrErrors -join ' | ' } elseif ($unparsedStdout.Count -gt 0) { $unparsedStdout -join ' | ' } else { 'Node exited without a structured fatal event.' }
        throw "Node probe helper failed with exit code $exitCode. $nodeFailure"
    }
    if ($fatal) {
        throw "Node probe failed during startup. category=$($fatal.category); code=$($fatal.code); $($fatal.message)"
    }
    if (-not $summary) {
        throw 'Node probe completed without a structured summary. Review unparsed stdout/stderr diagnostics.'
    }

    return [pscustomobject]@{
        Rows = @($rows | ForEach-Object { $_ })
        FirstFailure = $firstFailure
        RuntimeConfig = $runtimeConfig
        Scenarios = $scenarioEvents
        Summary = $summary
        StdErrWarnings = @($stderrWarnings | ForEach-Object { $_ })
        StdErrErrors = @($stderrErrors | ForEach-Object { $_ })
        UnparsedStdout = @($unparsedStdout | ForEach-Object { $_ })
    }
}

function Get-SmtpConfig {
    param([string]$Text)

    $match = [regex]::Match($Text, 'nodemailer\.createTransport\s*\(\s*{')
    if (-not $match.Success) {
        return $null
    }

    $openIndex = $Text.IndexOf('{', $match.Index)
    $closeIndex = Find-MatchingBrace -Text $Text -OpenIndex $openIndex
    if ($closeIndex -lt 0) {
        return $null
    }

    $body = $Text.Substring($openIndex, $closeIndex - $openIndex + 1)
    return [pscustomobject]@{
        Host = Get-JsPropertyValue -Text $body -PropertyName 'host'
        Port = Get-JsPropertyValue -Text $body -PropertyName 'port'
        Secure = Get-JsPropertyValue -Text $body -PropertyName 'secure'
        User = Get-JsPropertyValue -Text $body -PropertyName 'user'
        Password = Get-JsPropertyValue -Text $body -PropertyName 'pass'
        HasPassword = ($null -ne (Get-JsPropertyValue -Text $body -PropertyName 'pass'))
        Cipher = Get-JsPropertyValue -Text $body -PropertyName 'ciphers'
    }
}

function Read-SmtpResponse {
    param([System.IO.StreamReader]$Reader)

    $lines = New-Object System.Collections.Generic.List[string]
    $code = $null

    while ($true) {
        try {
            $line = $Reader.ReadLine()
        }
        catch {
            throw "Timed out waiting for SMTP server response."
        }

        if ($null -eq $line) {
            throw "SMTP server closed the connection unexpectedly."
        }

        $lines.Add($line) | Out-Null
        if ($line -match '^(?<code>\d{3})(?<separator>[ -])') {
            $code = [int]$Matches['code']
            if ($Matches['separator'] -eq ' ') {
                break
            }
        }
        else {
            break
        }
    }

    return [pscustomobject]@{
        Code = $code
        Lines = @($lines)
        Text = ($lines -join ' | ')
    }
}

function Send-SmtpCommand {
    param(
        [System.IO.StreamWriter]$Writer,
        [System.IO.StreamReader]$Reader,
        [string]$Command
    )

    $Writer.WriteLine($Command)
    return Read-SmtpResponse -Reader $Reader
}

function New-SmtpTextReaderWriter {
    param([System.IO.Stream]$Stream)

    $reader = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::ASCII)
    $writer = New-Object System.IO.StreamWriter($Stream, [System.Text.Encoding]::ASCII)
    $writer.NewLine = "`r`n"
    $writer.AutoFlush = $true

    return [pscustomobject]@{
        Reader = $reader
        Writer = $writer
    }
}

function ConvertTo-SmtpBase64 {
    param([string]$Value)

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-RootExceptionMessage {
    param([System.Exception]$Exception)

    $messages = New-Object System.Collections.Generic.List[string]
    $current = $Exception
    while ($current) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message)) {
            $messages.Add($current.Message) | Out-Null
        }
        $current = $current.InnerException
    }

    return ($messages | Select-Object -Unique) -join ' | '
}

function Enable-SmtpTls {
    param(
        [System.IO.Stream]$Stream,
        [string]$HostName,
        [int]$TimeoutSeconds
    )

    $certificateCallback = [System.Net.Security.RemoteCertificateValidationCallback]{
        param($Sender, $Certificate, $Chain, $SslPolicyErrors)
        return ($SslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None)
    }

    $sslStream = New-Object System.Net.Security.SslStream($Stream, $false, $certificateCallback)
    $sslStream.ReadTimeout = $TimeoutSeconds * 1000
    $sslStream.WriteTimeout = $TimeoutSeconds * 1000

    $clientCertificates = New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection
    $sslStream.AuthenticateAsClient($HostName, $clientCertificates, [System.Security.Authentication.SslProtocols]::Tls12, $false)

    return $sslStream
}

function Test-SmtpCredential {
    param(
        [pscustomobject]$SmtpConfig,
        [int]$TimeoutSeconds
    )

    $result = [ordered]@{
        Host = $SmtpConfig.Host
        Port = $SmtpConfig.Port
        User = $SmtpConfig.User
        Status = 'ERROR'
        Detail = ''
    }

    $client = $null
    $networkStream = $null
    $activeStream = $null
    $reader = $null
    $writer = $null

    try {
        if (-not $SmtpConfig.Host -or -not $SmtpConfig.Port) {
            $result.Detail = 'SMTP host or port is missing.'
            return [pscustomobject]$result
        }
        if (-not $SmtpConfig.User -or -not $SmtpConfig.HasPassword) {
            $result.Detail = 'SMTP username or password is missing, so AUTH LOGIN was not attempted.'
            return [pscustomobject]$result
        }

        $client = New-Object System.Net.Sockets.TcpClient
        $client.SendTimeout = $TimeoutSeconds * 1000
        $client.ReceiveTimeout = $TimeoutSeconds * 1000

        $connect = $client.BeginConnect([string]$SmtpConfig.Host, [int]$SmtpConfig.Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000, $false)) {
            $result.Detail = "SMTP host $($SmtpConfig.Host):$($SmtpConfig.Port) did not respond before the connection timed out."
            return [pscustomobject]$result
        }
        $client.EndConnect($connect)

        $networkStream = $client.GetStream()
        $networkStream.ReadTimeout = $TimeoutSeconds * 1000
        $networkStream.WriteTimeout = $TimeoutSeconds * 1000
        $activeStream = $networkStream

        $usesImplicitTls = (($SmtpConfig.Secure -eq $true) -or ([int]$SmtpConfig.Port -eq 465))
        if ($usesImplicitTls) {
            $activeStream = Enable-SmtpTls -Stream $networkStream -HostName ([string]$SmtpConfig.Host) -TimeoutSeconds $TimeoutSeconds
        }

        $io = New-SmtpTextReaderWriter -Stream $activeStream
        $reader = $io.Reader
        $writer = $io.Writer

        $banner = Read-SmtpResponse -Reader $reader
        if ($banner.Code -ne 220) {
            $result.Detail = "SMTP server returned unexpected banner: $($banner.Text)"
            return [pscustomobject]$result
        }

        $localName = $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($localName)) {
            $localName = 'localhost'
        }

        $ehlo = Send-SmtpCommand -Writer $writer -Reader $reader -Command "EHLO $localName"
        if ($ehlo.Code -ne 250) {
            $ehlo = Send-SmtpCommand -Writer $writer -Reader $reader -Command "HELO $localName"
        }
        if ($ehlo.Code -ne 250) {
            $result.Detail = "SMTP greeting failed: $($ehlo.Text)"
            return [pscustomobject]$result
        }

        if (-not $usesImplicitTls) {
            if ($ehlo.Text -match '(?i)\bSTARTTLS\b') {
                $startTls = Send-SmtpCommand -Writer $writer -Reader $reader -Command 'STARTTLS'
                if ($startTls.Code -ne 220) {
                    $result.Detail = "SMTP server refused STARTTLS: $($startTls.Text)"
                    return [pscustomobject]$result
                }

                $activeStream = Enable-SmtpTls -Stream $networkStream -HostName ([string]$SmtpConfig.Host) -TimeoutSeconds $TimeoutSeconds
                $io = New-SmtpTextReaderWriter -Stream $activeStream
                $reader = $io.Reader
                $writer = $io.Writer

                $ehlo = Send-SmtpCommand -Writer $writer -Reader $reader -Command "EHLO $localName"
                if ($ehlo.Code -ne 250) {
                    $result.Detail = "SMTP greeting after STARTTLS failed: $($ehlo.Text)"
                    return [pscustomobject]$result
                }
            }
            else {
                $result.Detail = 'SMTP server did not advertise STARTTLS; credentials were not sent over plaintext.'
                return [pscustomobject]$result
            }
        }

        $auth = Send-SmtpCommand -Writer $writer -Reader $reader -Command 'AUTH LOGIN'
        if ($auth.Code -eq 503) {
            $result.Status = 'OK'
            $result.Detail = 'SMTP server reports the session is already authenticated.'
            return [pscustomobject]$result
        }
        if ($auth.Code -ne 334) {
            $result.Detail = "SMTP AUTH LOGIN was not accepted: $($auth.Text)"
            return [pscustomobject]$result
        }

        $usernameResponse = Send-SmtpCommand -Writer $writer -Reader $reader -Command (ConvertTo-SmtpBase64 -Value ([string]$SmtpConfig.User))
        if ($usernameResponse.Code -ne 334) {
            $result.Detail = "SMTP username was rejected before password validation: $($usernameResponse.Text)"
            return [pscustomobject]$result
        }

        $passwordResponse = Send-SmtpCommand -Writer $writer -Reader $reader -Command (ConvertTo-SmtpBase64 -Value ([string]$SmtpConfig.Password))
        switch ($passwordResponse.Code) {
            235 {
                $result.Status = 'OK'
                $result.Detail = 'SMTP credentials were accepted. No email was sent.'
            }
            535 {
                $result.Detail = 'SMTP authentication failed: wrong username/password, disabled SMTP AUTH, or account policy blocked the login.'
            }
            534 {
                $result.Detail = 'SMTP authentication failed: the server requires a stronger authentication method or an app password.'
            }
            454 {
                $result.Detail = 'SMTP authentication temporarily unavailable or throttled by the server.'
            }
            default {
                $result.Detail = "SMTP authentication failed: $($passwordResponse.Text)"
            }
        }
    }
    catch [System.Net.Sockets.SocketException] {
        $result.Detail = "SMTP host unreachable or connection refused: $($_.Exception.Message)"
    }
    catch [System.Security.Authentication.AuthenticationException] {
        $result.Detail = "SMTP TLS handshake failed before credentials were sent: $(Get-RootExceptionMessage -Exception $_.Exception)"
    }
    catch {
        $rootMessage = Get-RootExceptionMessage -Exception $_.Exception
        if ($rootMessage -match 'No credentials are available in the security package') {
            $result.Detail = 'SMTP TLS handshake failed before credentials were sent: Windows Schannel could not acquire local TLS credentials. Check local TLS 1.2/Schannel policy and certificate-store health on this machine.'
        }
        elseif ($rootMessage -match 'Authentication failed') {
            $result.Detail = "SMTP TLS handshake failed before credentials were sent: $rootMessage"
        }
        else {
            $result.Detail = $rootMessage
        }
    }
    finally {
        if ($writer -and $client -and $client.Connected) {
            try {
                $writer.WriteLine('QUIT')
            }
            catch {
            }
        }
        if ($reader) {
            $reader.Dispose()
        }
        if ($writer) {
            $writer.Dispose()
        }
        if ($activeStream -and $activeStream -ne $networkStream) {
            $activeStream.Dispose()
        }
        if ($networkStream) {
            $networkStream.Dispose()
        }
        if ($client) {
            $client.Close()
            $client.Dispose()
        }
    }

    return [pscustomobject]$result
}

function Test-TcpReachability {
    param(
        [string]$HostName,
        [int]$Port
    )

    try {
        if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
            $tcp = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
            return [bool]$tcp.TcpTestSucceeded
        }

        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne(5000, $false)
        if ($success) {
            $client.EndConnect($async)
        }
        $client.Close()
        return $success
    }
    catch {
        return $false
    }
}

function Get-CertificateReferences {
    param(
        [object[]]$Declarations,
        [string]$ConfigDirectory
    )

    $refs = New-Object System.Collections.Generic.List[object]
    foreach ($decl in $Declarations | Where-Object { $_.Kind -eq 'literal' -and $_.RawValue }) {
        $value = Convert-JsLiteral $decl.RawValue
        if ($value -isnot [string]) {
            continue
        }

        $nameLooksLikeCertificate = $decl.Name -match '(?i)(cert|certificate|pfx|pem|crt|cer|key)'
        $valueLooksLikeCertificate = $value -match '(?i)\.(pfx|pem|crt|cer|key)$'
        if (-not ($nameLooksLikeCertificate -or $valueLooksLikeCertificate)) {
            continue
        }

        $candidate = $value
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $ConfigDirectory $candidate
        }

        $refs.Add([pscustomobject]@{
            Name = $decl.Name
            Value = $value
            ResolvedPath = $candidate
            Exists = Test-Path -LiteralPath $candidate -PathType Leaf
            Line = $decl.Line
        }) | Out-Null
    }

    return $refs
}

if ($LegacyRunUserTableSettingsProbeRequested -and $SkipUserTableSettingsProbe) {
    Write-Result -Level WARN -Message 'Both -RunUserTableSettingsProbe and -SkipUserTableSettingsProbe were supplied. The Skip parameter takes priority.'
}
if ($LegacyAllowUnencryptedDiagnosticRequested -and $SkipUnencryptedSqlDiagnostic) {
    Write-Result -Level WARN -Message 'Both -AllowUnencryptedSqlDiagnostic and -SkipUnencryptedSqlDiagnostic were supplied. The Skip parameter takes priority.'
}
if ($LegacyRunExtendedSimulationsRequested -and $SkipExtendedDbConfigSimulations) {
    Write-Result -Level WARN -Message 'Both -RunExtendedDbConfigSimulations and -SkipExtendedDbConfigSimulations were supplied. The Skip parameter takes priority.'
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Read-Host 'Enter the full path to DBConfig.js'
}

$resolvedConfig = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
if (-not $resolvedConfig) {
    Write-Result -Level ERROR -Message "File does not exist: $Path"
    if ($SetExitCode) {
        exit 1
    }
    return
}

$configPath = $resolvedConfig.Path
if ([System.IO.Path]::GetExtension($configPath) -ne '.js') {
    Write-Result -Level WARN -Message "File extension is not .js: $configPath"
}

$findings = New-Object System.Collections.Generic.List[object]
$configDirectory = Split-Path -Parent $configPath
$content = Get-Content -LiteralPath $configPath -Raw

Write-Host "Scanning: $configPath" -ForegroundColor White

Write-Section 'Selected Checks'
Write-Result -Level INFO -Message ("SQL connection tests: {0}" -f $(if ($SkipDatabaseTests) { 'disabled (-SkipDatabaseTests)' } else { 'enabled' }))
Write-Result -Level INFO -Message ("User table settings probe: {0}" -f $(if ($SkipDatabaseTests) { 'disabled because SQL connection tests are disabled' } elseif (-not $RunUserTableSettingsProbe) { 'disabled (-SkipUserTableSettingsProbe)' } else { 'enabled' }))
Write-Result -Level INFO -Message ("Encrypted/unencrypted comparison: {0}" -f $(if (-not $AllowUnencryptedSqlDiagnostic) { 'disabled (-SkipUnencryptedSqlDiagnostic)' } else { 'enabled when an encrypted transport reset is detected' }))
Write-Result -Level INFO -Message ("Extended dbConfig simulations: {0}" -f $(if (-not $RunExtendedDbConfigSimulations) { 'disabled (-SkipExtendedDbConfigSimulations)' } else { 'enabled when normal controls do not identify the failure' }))
Write-Result -Level INFO -Message ("SMTP TCP test: {0}" -f $(if ($SkipSmtpTcpTest) { 'disabled (-SkipSmtpTcpTest)' } else { 'enabled' }))
Write-Result -Level INFO -Message ("SMTP authentication test: {0}" -f $(if ($SkipSmtpAuthTest) { 'disabled (-SkipSmtpAuthTest)' } else { 'enabled' }))

Write-Section 'JavaScript Syntax'
$syntax = Test-JavaScriptSyntax -ConfigPath $configPath
if (-not $syntax.Available) {
    Add-Finding -Findings $findings -Level WARN -Area 'Syntax' -Message $syntax.Message
    Write-Result -Level WARN -Message $syntax.Message
}
elseif ($syntax.Success) {
    Add-Finding -Findings $findings -Level OK -Area 'Syntax' -Message 'No JavaScript syntax errors found by node --check.'
    Write-Result -Level OK -Message 'No JavaScript syntax errors found by node --check.'
}
else {
    $lineText = if ($syntax.Line) { " line $($syntax.Line)" } else { '' }
    Add-Finding -Findings $findings -Level ERROR -Area 'Syntax' -Message "JavaScript syntax error found$lineText. $($syntax.Message)"
    Write-Result -Level ERROR -Message "JavaScript syntax error found$lineText."
    if ($syntax.Message) {
        Write-Host $syntax.Message -ForegroundColor DarkYellow
    }
}

$declarations = @(Get-JsDeclarations -Text $content)
$declarationNames = @{}
foreach ($decl in $declarations) {
    $declarationNames[$decl.Name] = $true
}

Write-Section 'module.exports'
$exports = @(Get-ModuleExports -Text $content)
if ($exports.Count -eq 0) {
    Add-Finding -Findings $findings -Level ERROR -Area 'Exports' -Message 'No module.exports object was found.'
    Write-Result -Level ERROR -Message 'No module.exports object was found.'
}
else {
    Write-Result -Level INFO -Message ("Found {0} exported definition(s)." -f $exports.Count)
    foreach ($export in $exports) {
        if ([string]::IsNullOrWhiteSpace($export.ReferencedName)) {
            Add-Finding -Findings $findings -Level WARN -Area 'Exports' -Message "Could not statically validate export entry '$($export.ExportName)'."
            Write-Result -Level WARN -Message "Could not statically validate export entry '$($export.ExportName)'."
        }
        elseif ($declarationNames.ContainsKey($export.ReferencedName)) {
            Write-Result -Level OK -Message ("{0} -> {1} exists." -f $export.ExportName, $export.ReferencedName)
        }
        else {
            Add-Finding -Findings $findings -Level ERROR -Area 'Exports' -Message "Export '$($export.ExportName)' references missing declaration '$($export.ReferencedName)'."
            Write-Result -Level ERROR -Message "Export '$($export.ExportName)' references missing declaration '$($export.ReferencedName)'."
        }
    }
}

Write-Section 'Database Credentials'
$dbConfigDeclarations = @($declarations | Where-Object { $_.Kind -eq 'object' -and $_.Name -match '^dbConfig' })
foreach ($dbDeclaration in $dbConfigDeclarations) {
    $baseLine = if ($dbDeclaration.RawValueLine) { [int]$dbDeclaration.RawValueLine } else { [int]$dbDeclaration.Line }
    foreach ($requiredProperty in @('user', 'password', 'server', 'database')) {
        $propertyDeclaration = Get-JsPropertyDeclarationInfo -Text $dbDeclaration.RawValue -PropertyName $requiredProperty -BaseLine $baseLine
        if (-not $propertyDeclaration.Present) {
            $message = "$($dbDeclaration.Name).$requiredProperty is missing. Add it inside the object beginning at line $($dbDeclaration.Line)."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }
    }
}

$dbConfigs = @(Get-DbConfigs -Declarations $declarations)
$databasePasswordRetryCache = @{}
$validatedDatabaseConnections = @{}
if ($dbConfigs.Count -eq 0) {
    Add-Finding -Findings $findings -Level WARN -Area 'Database' -Message 'No database credential objects with user/password/server/database were found.'
    Write-Result -Level WARN -Message 'No database credential objects with user/password/server/database were found.'
}
else {
    Write-Result -Level INFO -Message ("Found {0} database credential object(s)." -f $dbConfigs.Count)

    foreach ($db in $dbConfigs) {
        $target = if ($db.Port) { "$($db.Server):$($db.Port)" } else { $db.Server }
        Write-Result -Level INFO -Message ("{0}: server={1} ({2}); database={3} ({4}); user={5} ({6}); password=<hidden> ({7})" -f
            $db.Name,
            $target,
            (Get-ConfigSourceReference -DbConfig $db -PropertyName 'server'),
            $db.Database,
            (Get-ConfigSourceReference -DbConfig $db -PropertyName 'database'),
            $db.User,
            (Get-ConfigSourceReference -DbConfig $db -PropertyName 'user'),
            (Get-ConfigSourceReference -DbConfig $db -PropertyName 'password'))

        if ($null -ne $db.Port -and ($db.Port -lt 1 -or $db.Port -gt 65535)) {
            $message = "$($db.Name).port=$($db.Port) is outside 1-65535 ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'port'))."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }
        if ($null -ne $db.PacketSize -and $db.PacketSize -le 0) {
            $message = "$($db.Name).options.packetSize must be positive ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'packetSize'))."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }
        if ($null -ne $db.PoolMin -and $null -ne $db.PoolMax -and $db.PoolMin -gt $db.PoolMax) {
            $message = "$($db.Name).pool.min=$($db.PoolMin) ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'pool.min')) exceeds pool.max=$($db.PoolMax) ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'pool.max'))."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }
        if ($null -ne $db.RequestTimeout -and $db.RequestTimeout -lt 0) {
            $message = "$($db.Name).requestTimeout cannot be negative ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'requestTimeout'))."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }
        if ($null -ne $db.PoolIdleTimeoutMillis -and $db.PoolIdleTimeoutMillis -lt 0) {
            $message = "$($db.Name).pool.idleTimeoutMillis cannot be negative ($(Get-ConfigSourceReference -DbConfig $db -PropertyName 'pool.idleTimeoutMillis'))."
            Add-Finding -Findings $findings -Level ERROR -Area 'DatabaseConfig' -Message $message
            Write-Result -Level ERROR -Message $message
        }

        if ($SkipDatabaseTests) {
            Add-Finding -Findings $findings -Level INFO -Area 'Database' -Message "Skipped database connection test for $($db.Name)."
            continue
        }

        $resolvedDbConnection = Resolve-DbConfigConnection -DbConfig $db -TimeoutSeconds $ConnectionTimeoutSeconds -PasswordRetryCache $databasePasswordRetryCache -NoPasswordPrompt:$NoDatabasePasswordPrompt
        $dbTest = $resolvedDbConnection.Test
        if ($dbTest.Status -eq 'OK') {
            Write-Result -Level OK -Message "$($db.Name): $($dbTest.Detail)"
            $validatedDatabaseConnections[$db.Name] = [pscustomobject]@{
                DbConfig = $resolvedDbConnection.DbConfig
                Test = $dbTest
            }
        }
        else {
            $sourceRefs = "server $(Get-ConfigSourceReference -DbConfig $db -PropertyName 'server'); port $(Get-ConfigSourceReference -DbConfig $db -PropertyName 'port'); database $(Get-ConfigSourceReference -DbConfig $db -PropertyName 'database'); user $(Get-ConfigSourceReference -DbConfig $db -PropertyName 'user'); password $(Get-ConfigSourceReference -DbConfig $db -PropertyName 'password')"
            Add-Finding -Findings $findings -Level ERROR -Area 'Database' -Message "$($db.Name): $($dbTest.Detail) Source: $sourceRefs."
            Write-Result -Level ERROR -Message "$($db.Name): $($dbTest.Detail) Source: $sourceRefs."
        }
    }
}

if ($RunUserTableSettingsProbe -and -not $SkipUserTableSettingsProbe -and -not $SkipDatabaseTests) {
    Write-Section 'User Table Settings Probe'
    Write-Result -Level INFO -Message 'Purpose: test the largest TableSettings JSON payload accepted by D4A_UpdateUserTableSettings using the application-style SQL call and this script''s SQL instance resolution.'

    $probeDb = $dbConfigs | Where-Object { $_.Name -eq $ProbeDbConfigName } | Select-Object -First 1
    if (-not $probeDb) {
        Add-Finding -Findings $findings -Level ERROR -Area 'UserTableSettingsProbe' -Message "Database config '$ProbeDbConfigName' was not found."
        Write-Result -Level ERROR -Message "Database config '$ProbeDbConfigName' was not found."
    }
    else {
        Write-Result -Level INFO -Message ("CONFIG name={0}; server={1} ({2}); database={3} ({4}); encrypt={5} ({6}); trustServerCertificate={7} ({8}); packetSize={9} ({10}); useColumnNames={11} ({12}); rowCollectionOnDone={13} ({14}); rowCollectionOnRequestCompletion={15} ({16})" -f
            $probeDb.Name,
            $probeDb.Server,
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'server'),
            $probeDb.Database,
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'database'),
            $(if ($null -ne $probeDb.Encrypt) { $probeDb.Encrypt } else { '<missing; driver path may default to false>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'encrypt'),
            $(if ($null -ne $probeDb.TrustServerCertificate) { $probeDb.TrustServerCertificate } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'trustServerCertificate'),
            $(if ($null -ne $probeDb.PacketSize) { $probeDb.PacketSize } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'packetSize'),
            $(if ($null -ne $probeDb.UseColumnNames) { $probeDb.UseColumnNames } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'useColumnNames'),
            $(if ($null -ne $probeDb.RowCollectionOnDone) { $probeDb.RowCollectionOnDone } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'rowCollectionOnDone'),
            $(if ($null -ne $probeDb.RowCollectionOnRequestCompletion) { $probeDb.RowCollectionOnRequestCompletion } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'rowCollectionOnRequestCompletion'))

        Write-Result -Level INFO -Message ("CONFIG runtime: requestTimeout={0} ({1}); stream={2} ({3}); parseJSON={4} ({5}); pool.min={6} ({7}); pool.max={8} ({9}); pool.idleTimeoutMillis={10} ({11}); pool.requestTimeout={12} ({13})" -f
            $(if ($null -ne $probeDb.RequestTimeout) { $probeDb.RequestTimeout } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'requestTimeout'),
            $(if ($null -ne $probeDb.Stream) { $probeDb.Stream } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'stream'),
            $(if ($null -ne $probeDb.ParseJSON) { $probeDb.ParseJSON } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'parseJSON'),
            $(if ($null -ne $probeDb.PoolMin) { $probeDb.PoolMin } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'pool.min'),
            $(if ($null -ne $probeDb.PoolMax) { $probeDb.PoolMax } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'pool.max'),
            $(if ($null -ne $probeDb.PoolIdleTimeoutMillis) { $probeDb.PoolIdleTimeoutMillis } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'pool.idleTimeoutMillis'),
            $(if ($null -ne $probeDb.PoolRequestTimeout) { $probeDb.PoolRequestTimeout } else { '<missing>' }),
            (Get-ConfigSourceReference -DbConfig $probeDb -PropertyName 'pool.requestTimeout'))

        if ($probeDb.Encrypt -ne $true) {
            Write-Result -Level WARN -Message 'dbConfigTampa.options.encrypt is false or missing. This is not declared the root cause by configuration alone; the probe will run a controlled encrypt=true comparison if the configured path resets.'
        }
        elseif ($AllowUnencryptedSqlDiagnostic) {
            Write-Result -Level WARN -Message 'The encrypted/unencrypted comparison is enabled. If the configured encrypted path resets, the probe will retry synthetic JSON with encrypt=false and verify the encryption state reported by SQL Server. Use -SkipUnencryptedSqlDiagnostic when this comparison is not approved for the network.'
        }

        $probeConnection = $null
        if ($validatedDatabaseConnections.ContainsKey($probeDb.Name)) {
            $probeConnection = $validatedDatabaseConnections[$probeDb.Name]
        }
        else {
            $resolvedProbeConnection = Resolve-DbConfigConnection -DbConfig $probeDb -TimeoutSeconds $ConnectionTimeoutSeconds -PasswordRetryCache $databasePasswordRetryCache -NoPasswordPrompt:$NoDatabasePasswordPrompt
            if ($resolvedProbeConnection.Test.Status -eq 'OK') {
                $probeConnection = [pscustomobject]@{
                    DbConfig = $resolvedProbeConnection.DbConfig
                    Test = $resolvedProbeConnection.Test
                }
                $validatedDatabaseConnections[$probeDb.Name] = $probeConnection
                Write-Result -Level OK -Message "$($probeDb.Name): $($resolvedProbeConnection.Test.Detail)"
            }
            else {
                Add-Finding -Findings $findings -Level ERROR -Area 'UserTableSettingsProbe' -Message "$($probeDb.Name): could not resolve a working SQL connection. $($resolvedProbeConnection.Test.Detail)"
                Write-Result -Level ERROR -Message "$($probeDb.Name): could not resolve a working SQL connection. $($resolvedProbeConnection.Test.Detail)"
            }
        }

        if ($probeConnection) {
            Write-Result -Level INFO -Message "Running probe against $($probeConnection.Test.Server) / $($probeConnection.DbConfig.Database)."
            try {
                $probeResult = Invoke-UserTableSettingsProbe -DbConfig $probeConnection.DbConfig -DataSource $probeConnection.Test.Server -ConfigPath $configPath -PayloadSizes $ProbePayloadSizes -TimeoutSeconds $ConnectionTimeoutSeconds -AllowUnencryptedDiagnostic ([bool]$AllowUnencryptedSqlDiagnostic) -RunExtendedConfigSimulations ([bool]$RunExtendedDbConfigSimulations)

                if ($probeResult.RuntimeConfig) {
                    $runtime = $probeResult.RuntimeConfig
                    Write-Result -Level INFO -Message ("RUNTIME node={0}; mssql={1}; encryptConfigured={2}; encryptEffective={3}; trustConfigured={4}; trustEffective={5}; packetSize={6}" -f
                        $runtime.nodeVersion,
                        $(if ($runtime.mssqlVersion) { $runtime.mssqlVersion } else { '<unknown>' }),
                        $(if ($null -ne $runtime.encryptConfigured) { $runtime.encryptConfigured } else { '<missing>' }),
                        $runtime.encryptEffective,
                        $(if ($null -ne $runtime.trustServerCertificateConfigured) { $runtime.trustServerCertificateConfigured } else { '<missing>' }),
                        $runtime.trustServerCertificateEffective,
                        $(if ($null -ne $runtime.packetSize) { $runtime.packetSize } else { '<driver default>' }))
                }

                foreach ($warning in $probeResult.StdErrWarnings) {
                    Add-Finding -Findings $findings -Level WARN -Area 'NodeRuntime' -Message $warning
                    Write-Result -Level WARN -Message $warning
                }
                foreach ($diagnostic in $probeResult.StdErrErrors) {
                    Add-Finding -Findings $findings -Level WARN -Area 'UserTableSettingsProbeStderr' -Message $diagnostic
                    Write-Result -Level WARN -Message "Node stderr diagnostic: $diagnostic"
                }

                $currentScenario = $null
                foreach ($row in $probeResult.Rows) {
                    if ($row.Scenario -ne $currentScenario) {
                        $currentScenario = $row.Scenario
                        $scenario = $probeResult.Scenarios | Where-Object { $_.scenario -eq $currentScenario } | Select-Object -Last 1
                        Write-Result -Level INFO -Message ("Scenario={0}; mode={1}; encrypt={2}; trustServerCertificate={3}; negotiatedEncryption={4}; negotiatedPacketSize={5}; stream={6}; parseJSON={7}; useColumnNames={8}; rowCollectionOnDone={9}; rowCollectionOnRequestCompletion={10}" -f
                            $currentScenario,
                            $scenario.mode,
                            $scenario.encrypt,
                            $scenario.trustServerCertificate,
                            $(if ($scenario.sessionInfo -and $scenario.sessionInfo.encryptOption) { $scenario.sessionInfo.encryptOption } else { '<unavailable>' }),
                            $(if ($scenario.sessionInfo -and $scenario.sessionInfo.negotiatedPacketSize) { $scenario.sessionInfo.negotiatedPacketSize } else { '<unavailable>' }),
                            $(if ($null -ne $scenario.stream) { $scenario.stream } else { '<missing>' }),
                            $(if ($null -ne $scenario.parseJSON) { $scenario.parseJSON } else { '<missing>' }),
                            $(if ($null -ne $scenario.useColumnNames) { $scenario.useColumnNames } else { '<missing>' }),
                            $(if ($null -ne $scenario.rowCollectionOnDone) { $scenario.rowCollectionOnDone } else { '<missing>' }),
                            $(if ($null -ne $scenario.rowCollectionOnRequestCompletion) { $scenario.rowCollectionOnRequestCompletion } else { '<missing>' }))
                    }
                    if ($row.Status -eq 'OK') {
                        Write-Result -Level OK -Message ("{0,6} requested bytes ({1} actual JSON bytes) OK" -f $row.PayloadBytes, $row.ActualBytes)
                    }
                    else {
                        $friendlyFailure = switch -Regex ($row.Detail) {
                            'category=TRANSPORT_RESET' { 'The SQL connection was forcibly reset while transmitting this payload.'; break }
                            'category=LOGIN_FAILED' { 'SQL rejected the configured login credentials.'; break }
                            'category=TIMEOUT' { 'The SQL operation exceeded the configured timeout.'; break }
                            'category=TLS_CERTIFICATE' { 'SQL TLS certificate validation failed.'; break }
                            'category=PROCEDURE_MISSING' { 'D4A_UpdateUserTableSettings is missing from the configured database.'; break }
                            default { 'The probe request failed.' }
                        }
                        Write-Result -Level ERROR -Message ("{0,6} requested bytes ({1} actual JSON bytes) FAIL - {2}" -f $row.PayloadBytes, $row.ActualBytes, $friendlyFailure)
                        Write-Result -Level INFO -Message ("Technical details: {0}" -f $row.Detail)
                        if ($row.SqlBatch) {
                            Write-Result -Level INFO -Message ("Failed SQL batch for SSMS trace: {0}" -f $row.SqlBatch)
                        }
                    }
                }

                if ($probeResult.FirstFailure) {
                    Write-Result -Level WARN -Message ("The configured application path first failed when the JSON grew from the previous accepted size to approximately {0} requested bytes ({1} actual JSON bytes)." -f
                        $probeResult.FirstFailure.PayloadBytes,
                        $probeResult.FirstFailure.ActualBytes)

                    if (-not $AllowUnencryptedSqlDiagnostic -and
                        $probeResult.RuntimeConfig -and
                        $probeResult.RuntimeConfig.encryptEffective -eq $true -and
                        $probeResult.FirstFailure.Category -eq 'TRANSPORT_RESET') {
                        Write-Result -Level INFO -Message 'The encrypted/unencrypted comparison was disabled. To prove or rule out the encrypt=true path, rerun without -SkipUnencryptedSqlDiagnostic. The comparison uses synthetic data and verifies SQL Server''s negotiated encryption state.'
                    }
                }

                $summaryLevel = if ($probeResult.Summary.severity -eq 'OK') { 'OK' } elseif ($probeResult.Summary.severity -eq 'WARN') { 'WARN' } else { 'ERROR' }
                Add-Finding -Findings $findings -Level $summaryLevel -Area 'UserTableSettingsProbe' -Message ("{0}: {1}" -f $probeResult.Summary.code, $probeResult.Summary.message)
                Write-Result -Level $summaryLevel -Message ("ROOT CAUSE [{0}]: {1}" -f $probeResult.Summary.code, $probeResult.Summary.message)

                if ($probeResult.UnparsedStdout.Count -gt 0) {
                    Write-Result -Level INFO -Message ("Node emitted {0} unstructured stdout line(s); they were retained as diagnostics but did not determine probe status." -f $probeResult.UnparsedStdout.Count)
                }
            }
            catch {
                $probeError = Get-RootExceptionMessage -Exception $_.Exception
                Add-Finding -Findings $findings -Level ERROR -Area 'UserTableSettingsProbe' -Message $probeError
                Write-Result -Level ERROR -Message $probeError
            }
        }
    }
}
elseif ($RunUserTableSettingsProbe -and -not $SkipUserTableSettingsProbe -and $SkipDatabaseTests) {
    Write-Section 'User Table Settings Probe'
    Write-Result -Level INFO -Message 'Skipped because -SkipDatabaseTests was specified.'
}

Write-Section 'SMTP Settings'
$smtp = Get-SmtpConfig -Text $content
if (-not $smtp) {
    Add-Finding -Findings $findings -Level WARN -Area 'SMTP' -Message 'No nodemailer.createTransport SMTP settings were found.'
    Write-Result -Level WARN -Message 'No nodemailer.createTransport SMTP settings were found.'
}
else {
    Write-Result -Level INFO -Message ("SMTP host={0}; port={1}; secure={2}; user={3}; password={4}" -f $smtp.Host, $smtp.Port, $smtp.Secure, $smtp.User, $(if ($smtp.HasPassword) { '<hidden>' } else { '<missing>' }))
    if ($smtp.Cipher -match '(?i)SSLv2|SSLv3|TLSv1(?:\.0)?$') {
        Add-Finding -Findings $findings -Level WARN -Area 'SMTP' -Message "SMTP TLS cipher setting may be weak or obsolete: $($smtp.Cipher)"
        Write-Result -Level WARN -Message "SMTP TLS cipher setting may be weak or obsolete: $($smtp.Cipher)"
    }

    if (-not $SkipSmtpTcpTest -and $smtp.Host -and $smtp.Port) {
        $smtpReachable = Test-TcpReachability -HostName $smtp.Host -Port ([int]$smtp.Port)
        if ($smtpReachable) {
            Write-Result -Level OK -Message "SMTP TCP connection to $($smtp.Host):$($smtp.Port) succeeded."
        }
        else {
            Add-Finding -Findings $findings -Level ERROR -Area 'SMTP' -Message "SMTP host $($smtp.Host):$($smtp.Port) was not reachable over TCP."
            Write-Result -Level ERROR -Message "SMTP host $($smtp.Host):$($smtp.Port) was not reachable over TCP."
        }
    }

    if (-not $SkipSmtpAuthTest) {
        $smtpAuth = Test-SmtpCredential -SmtpConfig $smtp -TimeoutSeconds $SmtpTimeoutSeconds
        if ($smtpAuth.Status -eq 'OK') {
            Write-Result -Level OK -Message $smtpAuth.Detail
        }
        else {
            Add-Finding -Findings $findings -Level ERROR -Area 'SMTP' -Message $smtpAuth.Detail
            Write-Result -Level ERROR -Message $smtpAuth.Detail
        }
    }
    else {
        Add-Finding -Findings $findings -Level INFO -Area 'SMTP' -Message 'Skipped SMTP AUTH LOGIN credential validation.'
        Write-Result -Level INFO -Message 'Skipped SMTP AUTH LOGIN credential validation.'
    }
}

Write-Section 'HTTP HTTPS TLS'
$tlsReject = [regex]::Match($content, 'process\.env\.NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*["'']?0["'']?')
if ($tlsReject.Success) {
    Add-Finding -Findings $findings -Level WARN -Area 'TLS' -Message 'NODE_TLS_REJECT_UNAUTHORIZED is set to 0, which disables TLS certificate validation.'
    Write-Result -Level WARN -Message 'NODE_TLS_REJECT_UNAUTHORIZED is set to 0, which disables TLS certificate validation.'
}
else {
    Write-Result -Level OK -Message 'NODE_TLS_REJECT_UNAUTHORIZED is not statically set to 0.'
}

foreach ($setting in @('UseHTTPS', 'UseHTTPS_Socket', 'APIEndpoint', 'Port', 'EnableAPISecurity', 'JWTExpirationPeriod')) {
    $value = Get-JsAssignedLiteral -Text $content -Name $setting
    if ($null -ne $value) {
        Write-Result -Level INFO -Message "$setting = $value"
    }
}

Write-Section 'Certificate Files'
$certRefs = @(Get-CertificateReferences -Declarations $declarations -ConfigDirectory $configDirectory)
if ($certRefs.Count -eq 0) {
    Write-Result -Level INFO -Message 'No certificate file references were found.'
}
else {
    foreach ($cert in $certRefs) {
        if ($cert.Exists) {
            Write-Result -Level OK -Message "$($cert.Name) exists: $($cert.ResolvedPath)"
        }
        else {
            Add-Finding -Findings $findings -Level ERROR -Area 'Certificates' -Message "$($cert.Name) references a missing file: $($cert.ResolvedPath)"
            Write-Result -Level ERROR -Message "$($cert.Name) references a missing file: $($cert.ResolvedPath)"
        }
    }
}

Write-Section 'Constants And Variables'
Write-Result -Level INFO -Message ("Found {0} top-level declaration(s)." -f $declarations.Count)
$declarations |
    Sort-Object Line, Name |
    Select-Object Line, Name, Kind |
    Format-Table -AutoSize

Write-Section 'Summary'
$errors = @($findings | Where-Object { $_.Level -eq 'ERROR' })
$warnings = @($findings | Where-Object { $_.Level -eq 'WARN' })

if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Result -Level OK -Message 'DBConfig scan completed without errors or warnings.'
}
else {
    Write-Result -Level INFO -Message ("Completed with {0} error(s) and {1} warning(s)." -f $errors.Count, $warnings.Count)
    foreach ($finding in ($findings | Where-Object { $_.Level -in @('ERROR', 'WARN') })) {
        Write-Result -Level $finding.Level -Message "$($finding.Area): $($finding.Message)"
    }
}

if ($SetExitCode -and $errors.Count -gt 0) {
    exit 1
}
