<# Standalone D4A diagnostic. Installed watchdogs are parsed, never dot-sourced.
    Source policies are imported only after a restricted syntax/capability audit.
    Unknown formats are reported as unsupported, never guessed or run wholesale. #>
[CmdletBinding()]
param(
    [string]$WatchdogPath,
    [string]$ConfigPath,
    [string]$StateFilePath,
    [ValidateSet('Auto','Plain','Encrypted')][string]$PasswordMode='Auto',
    [switch]$ShowTechnicalDetails,
    [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
$script:UDVersion='2026.09.16.4'

function ConvertTo-UDHash($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result=@{}; foreach($key in $Value.Keys) { $result[$key]=ConvertTo-UDHash $Value[$key] }; return $result
    }
    if ($Value -is [pscustomobject]) {
        $result=@{}; foreach($p in $Value.PSObject.Properties) { $result[$p.Name]=ConvertTo-UDHash $p.Value }; return $result
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object {ConvertTo-UDHash $_}) }
    return $Value
}
function Get-UDDigest([string]$Text) {
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n","`n").Trim())))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Protect-UDText([object]$Value) {
    $text=[string]$Value
    foreach($secret in @($script:UDSecrets)) {
        if ($secret -and $secret.Length -ge 3) { $text=$text.Replace($secret,'[REDACTED]') }
    }
    return ($text -replace '(?i)(password|pwd)\s*=\s*[^;\r\n]+','$1=[REDACTED]')
}
function Get-UDParseFailureReport([string]$Path,$ParseErrors) {
    # Parse only. Never execute the source or silently change its encoding.
    [pscustomobject]@{Color='Red';Text='SOURCE PARSE FAILED - watchdog checks and restart decisions were not evaluated.'}
    [pscustomobject]@{Color='Yellow';Text="Selected watchdog: $Path"}
    [pscustomobject]@{Color='Yellow';Text="Diagnostic: $script:UDVersion; PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"}
    [pscustomobject]@{Color='Yellow';Text='Locations below refer to the selected watchdog, not the diagnostic. Later errors may be consequences of the first error.'}
    foreach($problem in @($ParseErrors | Select-Object -First 10)) {
        # Parser messages can quote source literals, including credentials.
        $message=Protect-UDText ([regex]::Replace($problem.Message,"'[^']*'|`"[^`"]*`"",'[source text omitted]'))
        $location="Line $($problem.Extent.StartLineNumber), column $($problem.Extent.StartColumnNumber)"
        [pscustomobject]@{Color='Red';Text="$location [$($problem.ErrorId)]: $message"}
        if($problem.ErrorId -eq 'UnrecognizedToken' -and $problem.Extent.Text.Length -gt 0) {
            $code=[int][char]$problem.Extent.Text[0]
            [pscustomobject]@{Color='Yellow';Text=('  First character at this location: U+{0:X4}. Inspect this location in an editor for pasted formatting or damaged characters.' -f $code)}
        }
    }
    if($ParseErrors.Count -gt 10) {
        [pscustomobject]@{Color='Yellow';Text="Showing the first 10 of $($ParseErrors.Count) parser errors. Correct the first error and check again."}
    }
    try {
        $bytes=[IO.File]::ReadAllBytes($Path)
        $hasBom=($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -or
            ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255)))
        if(-not $hasBom) {
            $utf8=New-Object System.Text.UTF8Encoding($false,$true)
            try {
                $decoded=$utf8.GetString($bytes)
                $alternateTokens=$null;$alternateErrors=$null
                $null=[System.Management.Automation.Language.Parser]::ParseInput($decoded,[ref]$alternateTokens,[ref]$alternateErrors)
                if($alternateErrors.Count -eq 0) {
                    [pscustomobject]@{Color='Yellow';Text='LIKELY ENCODING MISMATCH: the file fails normal parsing but parses successfully when read as UTF-8. Review a backup in an editor and save as UTF-8 with BOM for Windows PowerShell compatibility, then rerun. No encoding changes were made.'}
                } else {
                    [pscustomobject]@{Color='Yellow';Text='Reading explicitly as UTF-8 also produces syntax errors. An encoding-only fix has not been established.'}
                }
            } catch [System.Text.DecoderFallbackException] {
                [pscustomobject]@{Color='Yellow';Text='The file has no recognized encoding marker and is not valid UTF-8. Verify its original encoding in an editor; do not blindly convert it.'}
            }
        } else {
            [pscustomobject]@{Color='Yellow';Text='The file has an encoding marker. Inspect the reported source locations and required PowerShell version.'}
        }
    } catch {
        [pscustomobject]@{Color='Yellow';Text='The optional encoding comparison could not be completed. The source parser errors above still apply.'}
    }
    [pscustomobject]@{Color='Yellow';Text='Possible causes: invalid or pasted source characters, incomplete code, or syntax requiring another PowerShell version. This report alone does not identify which cause applies.'}
    [pscustomobject]@{Color='Yellow';Text='Compare this PowerShell version with the watchdog scheduled task executable. Inspect the first reported location and preceding lines. Source lines are omitted to avoid exposing embedded credentials.'}
    [pscustomobject]@{Color='Yellow';Text='Restart outcome: NOT EVALUATED. This is not evidence of a service failure or proof that the scheduled watchdog fails in its own runtime.'}
}
function Get-UDMessageKind([string]$Title,[string]$Details) {
    # A log can describe an error *check* that passed. Never classify a message
    # as failed just because it contains the noun "error".
    $text="$Title $Details"
    if($Title -match '(?i)(?:^|\s)Restart deferred$' -or $text -match '(?i)\brestart\b[^\r\n]*\bdeferred for\b') { return 'Deferred' }
    if($Title -match '(?i)(?:^|\s)(?:SCAN ERROR|error|exception)$' -or
       $text -match '(?i)\b(?:unable to|failed to|could not|cannot|not found|unavailable|exception)\b|\bERROR\s*:|\berror(?:s| events?)?\s+(?:detected|found|occurred|present)\b|\berror events\s*:\s*[1-9]\d*\b') { return 'Error' }
    if($text -match '(?i)\bUnknown\b|skipped|skips this check|not configured|no MQTT|no [^\r\n.;]*(?:records|entry|rows)\b|placeholder|disabled|did not contain|unsupported') { return 'Warning' }
    if($Title -match '(?i)Restart succeeded|Daily restart' -and $text -match '(?i)restart|start') { return 'Action' }
    if($text -match '(?i)\bHealthy\b|HTTP 200\b|is running|\bno (?:matching )?error(?:s| events?)?\b|\b0 errors\b') { return 'Healthy' }
    return 'Info'
}
function Add-UDMessage {
    param([string]$Title,[string]$Details,
          [ValidateSet('Auto','Info','Healthy','Warning','Error','Deferred','Action')][string]$Kind='Auto')
    if($Kind -eq 'Auto') { $Kind=Get-UDMessageKind $Title $Details }
    $script:UDMessages.Add([pscustomobject]@{Title=(Protect-UDText $Title);Details=(Protect-UDText $Details);Kind=$Kind})
}
function Add-UDTrace([string]$Function,[string]$Condition) {
    $script:UDTrace.Add("$Function : $(Protect-UDText $Condition)")
    if($Function -eq 'Invoke-DailyServiceRestart' -and $Condition -match '^TRUE:\s*-not\s+\$monitoringConfig\.DailyRestart\.Enabled\s*$') {
        Add-UDMessage 'Schedule disabled' 'Daily restart is disabled in the installed watchdog.' -Kind Warning
    }
    elseif($Function -eq 'Invoke-DailyServiceRestart' -and $Condition -eq 'TRUE: $lastRun -and $lastRun.Date -eq $now.Date') {
        Add-UDMessage 'Schedule already completed' 'The saved restart history shows that the daily restart already ran today.' -Kind Info
    }
    elseif($Function -eq 'Invoke-DailyServiceRestart' -and $Condition -eq 'TRUE: $now.TimeOfDay -lt $monitoringConfig.DailyRestart.TimeOfDay') {
        Add-UDMessage 'Schedule not due' "The current time is before the configured daily restart time: $($monitoringConfig.DailyRestart.TimeOfDay)." -Kind Info
    }
}
function Add-UDVariables([string]$Function,$Variables,[string[]]$AllowedNames) {
    foreach($v in $Variables) {
        if($AllowedNames -and $v.Name -notin $AllowedNames) { continue }
        if($v.Name -match '^Maximum(?:Alias|Drive|Error|Function|Variable)Count$') { continue }
        if ($v.Name -notmatch '(?i)age|loss|count|stale|missing|observed|expected|threshold|frequency|seconds|minutes|healthy|alive|delay|remaining|interval|lastRestart|nextAllowed|reason|summary|detail') { continue }
        if ($v.Name -match '(?i)password|secret|credential|connectionstring|token|key|payload|query') { continue }
        $value=$v.Value
        if ($null -eq $value -or $value -is [ValueType] -or $value -is [string]) {
            $script:UDVariables["$Function.$($v.Name)"]=Protect-UDText $value
        }
    }
}

# These replace mutation/log functions regardless of their implementation in the source.
function Write-LogMessage { param([string]$Message) Add-UDMessage 'Observation' $Message }
function Write-ServiceLog {
    param($ServiceKey,$Title,$Details,$RestartEntry,$MonitorKey)
    Add-UDMessage $Title $Details
    if ($RestartEntry) {
        Add-UDMessage 'Restart history' "service=$ServiceKey; monitor=$MonitorKey; interval index=$($RestartEntry.IntervalIndex); last attempt=$($RestartEntry.LastRestart); healthy since=$($RestartEntry.HealthySince); next check=$($RestartEntry.NextAllowedCheck)"
    }
}
function Write-MonitorLog {
    param($State,$MonitorKey,$Title,$Details)
    Add-UDMessage "$MonitorKey - $Title" $Details
}
function Set-HealthCheckStatus {
    param([string]$CheckKey,[string]$Status)
    $script:HealthChecks[$CheckKey]=$Status
    $kind=switch($Status){'Healthy'{'Healthy'} 'Unhealthy'{'Error'} default{'Warning'}}
    Add-UDMessage 'Source health result' "$CheckKey = $Status" -Kind $kind
}
function Initialize-MonitoringState {param($Path) return $State}
function Get-ServiceLogFilePath {param($ServiceKey) throw 'Log-file access is disabled in diagnostics.'}
function DecryptString {
    param([string]$CipherText,[byte[]]$Key,[byte[]]$IV)
    $aes=[Security.Cryptography.Aes]::Create()
    try{
        $aes.Key=$Key;$aes.IV=$IV;$decryptor=$aes.CreateDecryptor()
        try{$bytes=[Convert]::FromBase64String($CipherText);$value=[Text.Encoding]::UTF8.GetString($decryptor.TransformFinalBlock($bytes,0,$bytes.Length));$script:UDSecrets+=@($value);return $value}
        finally{$decryptor.Dispose()}
    }finally{$aes.Dispose()}
}
function Write-Host { param($Object,$ForegroundColor,[switch]$NoNewline,$Separator) Add-UDMessage 'Source output' ($Object -join ' ') }
function Start-Service {
    [CmdletBinding()] param([string[]]$Name,$InputObject,[string[]]$DisplayName)
    $target=if($Name){$Name -join ', '}elseif($DisplayName){$DisplayName -join ', '}else{[string]$InputObject.Name}
    $script:UDActions.Add([pscustomobject]@{Action='Start';Service=$target;Evidence=@($script:UDTrace.ToArray())})
}
function Restart-Service {
    [CmdletBinding()] param([string[]]$Name,$InputObject,[string[]]$DisplayName,[switch]$Force)
    $target=if($Name){$Name -join ', '}elseif($DisplayName){$DisplayName -join ', '}else{[string]$InputObject.Name}
    $script:UDActions.Add([pscustomobject]@{Action='Restart';Service=$target;Evidence=@($script:UDTrace.ToArray())})
}
function Invoke-WatchdogServiceAction { param($Name,$Action) if($Action -eq 'Start'){Start-Service -Name $Name}else{Restart-Service -Name $Name} }
function Save-MonitoringState { param($Path,$State) Add-UDMessage 'Suppressed output' 'State save is disabled in diagnostics.' }
function Invoke-HealthDataPublish { param($State,$TargetApiBaseUrl) Add-UDMessage 'Suppressed output' 'Health publication is disabled in diagnostics.' }
function EnsureMqttCertificate {
    param([string]$Content)
    if ($Content -and (Test-Path -LiteralPath $Content -ErrorAction SilentlyContinue)) { return $Content }
    $path=$monitoringConfig.Mqtt.CertificatePath
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    throw 'TLS certificate file unavailable. Diagnostic mode never writes certificates.'
}
function Invoke-WebRequest {
    [CmdletBinding()] param($Uri,[string]$Method='Get',[switch]$UseBasicParsing,[int]$TimeoutSec=8,$Headers)
    if ($Method -ne 'Get') { throw "Diagnostic HTTP method blocked: $Method" }
    $p=@{Uri=$Uri;Method='Get';UseBasicParsing=$true;TimeoutSec=$TimeoutSec;ErrorAction='Stop'}
    if($Headers){$p.Headers=$Headers}
    try { $response=Invoke-UDHttpGet @p }
    catch {
        $primaryError=$_
        Invoke-UDHttpsComparison -OriginalUri $Uri -TimeoutSec $TimeoutSec -Headers $Headers
        throw $primaryError
    }
    Add-UDMessage 'HTTP probe' "$Uri -> HTTP $($response.StatusCode)"
    if($response.StatusCode -ne 200){Invoke-UDHttpsComparison -OriginalUri $Uri -TimeoutSec $TimeoutSec -Headers $Headers}
    return $response
}
function Invoke-UDHttpGet {
    [CmdletBinding()] param($Uri,[string]$Method='Get',[switch]$UseBasicParsing,[int]$TimeoutSec=8,$Headers)
    $request=@{Uri=$Uri;Method='Get';UseBasicParsing=$true;TimeoutSec=$TimeoutSec;ErrorAction='Stop'}
    if($Headers){$request.Headers=$Headers}
    $previousProtocol=$null;$changedProtocol=$false
    try {
        # Windows PowerShell uses .NET Framework WebRequest. PS7 uses its own
        # modern HTTP stack. Zero means OS defaults: preserve that negotiation.
        if($PSVersionTable.PSVersion.Major -le 5) {
            $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
            if([int]$previousProtocol -ne 0 -and ([int]$previousProtocol -band 3072) -ne 3072) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]([int]$previousProtocol -bor 3072)
                    $changedProtocol=$true
                    # Successful transport setup is not an inconclusive health
                    # observation. Keep it silent so it cannot override healthy probes.
                } catch {
                    Add-UDMessage 'TLS compatibility unavailable' "Unable to enable TLS 1.2 in this runtime: $($_.Exception.Message). The request will use its existing protocols." -Kind Warning
                }
            }
        }
        Invoke-UDNativeHttpGet @request
    } finally {
        if($changedProtocol){[Net.ServicePointManager]::SecurityProtocol=$previousProtocol}
    }
}
function Invoke-UDNativeHttpGet {
    [CmdletBinding()] param($Uri,[string]$Method='Get',[switch]$UseBasicParsing,[int]$TimeoutSec=8,$Headers)
    $request=@{Uri=$Uri;Method='Get';UseBasicParsing=$true;TimeoutSec=$TimeoutSec;ErrorAction='Stop'}
    if($Headers){$request.Headers=$Headers}
    Microsoft.PowerShell.Utility\Invoke-WebRequest @request
}
function Invoke-UDHttpsComparison {
    param($OriginalUri,[int]$TimeoutSec=8,$Headers)
    $parsed=$null
    if(-not [uri]::TryCreate([string]$OriginalUri,[UriKind]::Absolute,[ref]$parsed) -or $parsed.Scheme -ne 'http'){return}
    try {
        $builder=New-Object System.UriBuilder $parsed
        $builder.Scheme='https'
        if($parsed.IsDefaultPort){$builder.Port=-1}
        $alternative=$builder.Uri.AbsoluteUri
        Microsoft.PowerShell.Utility\Write-Host "  Comparing HTTPS endpoint: $alternative" -ForegroundColor Cyan
        $request=@{Uri=$alternative;TimeoutSec=$TimeoutSec}
        if($Headers){$request.Headers=$Headers}
        $result=Invoke-UDHttpGet @request
        if($result.StatusCode -eq 200){
            Add-UDMessage 'HTTPS comparison succeeded' "$alternative returned HTTP 200. The HTTP-only failure suggests a protocol configuration mismatch for this endpoint." -Kind Healthy
            $target=if($ConfigPath){[string]$ConfigPath}else{Join-Path (Split-Path $WatchdogPath -Parent) 'config.json'}
            Add-UDMessage 'Recommended configuration change' "Force HTTPS checks: add or update this property inside $target : `"apiProtocol`": `"https`", (use a comma only when another property follows). Re-run the diagnostic to confirm all API endpoints." -Kind Warning
            if($script:UDProtocolOverridePath){Add-UDMessage 'Local protocol override' "A local protocol override was found in $script:UDProtocolOverridePath . Update or remove a conflicting override there as well." -Kind Warning}
        }else{
            Add-UDMessage 'HTTPS comparison did not pass' "$alternative returned HTTP $($result.StatusCode). Verify this HTTPS endpoint before changing apiProtocol; HTTPS has not been confirmed healthy." -Kind Warning
        }
    }catch{
        Add-UDMessage 'HTTPS comparison could not be confirmed' "$alternative : $($_.Exception.Message). Test the HTTPS endpoint manually; set apiProtocol to https only if it works. Configuration file: $ConfigPath" -Kind Warning
    }
    Add-UDMessage 'Original watchdog decision preserved' 'The comparison is diagnostic only. Restart predictions still use the installed HTTP configuration; no configuration was changed.' -Kind Info
}
function Get-UDServiceInventory { Microsoft.PowerShell.Management\Get-Service -ErrorAction Stop }
function Add-UDServiceSuggestions {
    # Take a snapshot: adding advice must not change the collection being scanned.
    $missingNames=New-Object 'System.Collections.Generic.List[string]'
    foreach($message in @($script:UDMessages.ToArray())){
        $text="$($message.Title) $($message.Details)"
        if($text -match "(?i)Cannot find any service with service name '([^']+)'" -or
           $text -match "(?i)Service '([^']+)' (?:is )?not found"){
            if(-not $missingNames.Contains($matches[1])){$missingNames.Add($matches[1])}
        }
    }
    if(-not $missingNames.Count){return}
    try{$inventory=@(Get-UDServiceInventory)}catch{
        Add-UDMessage 'Service discovery unavailable' "The diagnostic could not list similar installed services: $($_.Exception.Message)" -Kind Warning
        return
    }
    foreach($missing in $missingNames){
        $family=$missing -replace '(?i)-v\d+$',''
        $candidates=@($inventory | Where-Object {
            ([string]$_.Name).IndexOf($family,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$_.DisplayName).IndexOf($family,[StringComparison]::OrdinalIgnoreCase) -ge 0
        } | Sort-Object Name -Unique)
        if($candidates.Count){
            Add-UDMessage 'Similar installed services' "The configured service '$missing' was not found. Possible matches for this service family:" -Kind Warning
            foreach($candidate in $candidates){
                Add-UDMessage 'Service candidate' "Name='$($candidate.Name)'; display name='$($candidate.DisplayName)'; state=$($candidate.Status)." -Kind Warning
            }
            Add-UDMessage 'Recommended watchdog change' "In $WatchdogPath replace the incorrect service name '$missing' with the exact Name of the candidate belonging to this site (for example, its -v2 or -v3 service). The diagnostic does not select or start a candidate automatically." -Kind Warning
        }else{
            Add-UDMessage 'No matching service candidates' "No installed service name or display name contains '$family'. Verify service installation and the configured name in $WatchdogPath ." -Kind Warning
        }
    }
}
function Assert-UDReadQuery([string]$Query) {
    # Restrict diagnostics to a single SELECT. Do not permit EXEC, SELECT INTO,
    # linked-server execution, stacked statements, or other SQL side effects.
    $scan=[regex]::Replace($Query,"'(?:''|[^'])*'", "''")
    $scan=[regex]::Replace($scan,'(?s)/\*.*?\*/|(?m)--[^\r\n]*',' ')
    $scan=$scan.Trim().TrimEnd(';').Trim()
    if ($scan -notmatch '(?is)^SELECT\b' -or $scan -match '(?i);|\b(INTO|INSERT|UPDATE|DELETE|MERGE|EXEC|EXECUTE|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE|DENY|BACKUP|RESTORE|DBCC|OPENROWSET|OPENQUERY|OPENDATASOURCE|NEXT\s+VALUE)\b') {
        throw 'Unsupported SQL for read-only diagnostics: only a single SELECT without side effects is allowed.'
    }
}
function Invoke-UDSql {
    param([string]$Query,$Parameters,[switch]$Scalar)
    Assert-UDReadQuery $Query
    if (-not $script:SqlConnectionString) { throw "SQL unavailable: $script:UDSqlProblem" }
    $connection=New-Object System.Data.SqlClient.SqlConnection $script:SqlConnectionString
    $command=$connection.CreateCommand();$command.CommandText=$Query;$command.CommandTimeout=30
    if($Parameters){foreach($key in $Parameters.Keys){$value=$Parameters[$key];if($null -eq $value){$value=[DBNull]::Value};[void]$command.Parameters.AddWithValue($key,$value)}}
    try {
        if($Scalar){$connection.Open();$value=$command.ExecuteScalar();Add-UDMessage 'SQL scalar result' "$value";return $value}
        $adapter=New-Object System.Data.SqlClient.SqlDataAdapter $command
        $table=New-Object System.Data.DataTable
        [void]$adapter.Fill($table)
        Add-UDMessage 'SQL rows returned' "$($table.Rows.Count)"
        return ,$table
    } finally { $command.Dispose();$connection.Dispose() }
}
function Invoke-SqlQuery {param($Query,$Parameters) Invoke-UDSql -Query $Query -Parameters $Parameters}
function Invoke-SqlScalar {param($Query,$Parameters) Invoke-UDSql -Query $Query -Parameters $Parameters -Scalar}

function Get-UDAuditIssue($Node,[string[]]$FunctionNames,[switch]$Configuration) {
    # Nested helpers remain inside their enclosing function. Audit their bodies
    # recursively, while permitting calls to their locally declared names.
    $nestedFunctionNames=@($Node.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object {$_.Name})
    $callableFunctionNames=@($FunctionNames)+$nestedFunctionNames
    $allowed=@('Get-Date','Join-Path','Split-Path','Test-Path','ConvertFrom-Json','ConvertTo-Json',
        'Where-Object','ForEach-Object','Select-Object','Sort-Object','Group-Object','Measure-Object','Out-Null',
        'Get-Service','Get-Process','Get-CimInstance','Get-WinEvent','Get-Random','Start-Sleep',
        'Write-LogMessage','Write-ServiceLog','Write-MonitorLog','Write-Host','Start-Service','Restart-Service',
        'Invoke-WatchdogServiceAction','Invoke-SqlQuery','Invoke-SqlScalar','Invoke-WebRequest',
        'EnsureMqttCertificate','Save-MonitoringState','Invoke-HealthDataPublish')
    if($Configuration){$allowed=@('Get-Date','Join-Path','Split-Path','Test-Path','ConvertFrom-Json','ConvertTo-Json')}
    foreach($command in $Node.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true)) {
        $name=$command.GetCommandName()
        if(-not $name -or $command.InvocationOperator -ne 'Unknown' -or ($name -notin $allowed -and $name -notin $callableFunctionNames)) {return "Unsupported command: $($command.Extent.Text)"}
    }
    $types=@('string','bool','boolean','int','int32','long','double','decimal','byte','byte[]','object','object[]','string[]','hashtable','pscustomobject','psobject','switch','CmdletBinding','Parameter','ValidateSet','ValidateRange','ValidateNotNullOrEmpty','AllowNull','datetime','timespan','math','regex','ref','array',
        'System.Collections.IEnumerable','System.Collections.IDictionary','System.Globalization.CultureInfo','System.Globalization.DateTimeStyles','DBNull','System.DateTime','System.TimeSpan','System.Math','System.String','Uri','UriKind')
    foreach($type in $Node.FindAll({param($n)$n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst]},$true)) {
        if($type.TypeName.FullName -notin $types){return "Unsupported type: $($type.TypeName.FullName)"}
    }
    $methods=@('ToString','Trim','TrimEnd','TrimStart','ToLowerInvariant','ToUpperInvariant','ContainsKey','GetEnumerator','Substring','Replace','ToUniversalTime','ToLocalTime','AddMinutes','AddSeconds','AddDays','AddHours','TryParse','Parse','IsNullOrWhiteSpace','IsNullOrEmpty','Match','Matches','Min','Max','Round','Floor','Ceiling','FromHours','FromMinutes','FromSeconds','TryCreate','Contains','StartsWith','EndsWith')
    foreach($call in $Node.FindAll({param($n)$n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]},$true)) {
        if($call.Static -and $call.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
           $call.Expression.TypeName.FullName -in @('string','System.String') -and
           $call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $call.Member.Value -eq 'Format'){continue}
        if($call.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $call.Member.Value -notin $methods){return "Unsupported method: $($call.Extent.Text)"}
    }
    foreach($assignmentNode in $Node.FindAll({param($n)$n -is [System.Management.Automation.Language.AssignmentStatementAst]},$true)) {
        if($assignmentNode.Left.Extent.Text -match '(?i)\$(global:|env:|function:|alias:|executioncontext|psdefaultparametervalues|erroractionpreference|(?:script:)?UD)'){return 'Unsupported assignment outside monitor state.'}
    }
    if($Node.FindAll({param($n)$n -is [System.Management.Automation.Language.TrapStatementAst] -or $n -is [System.Management.Automation.Language.ExitStatementAst]},$true).Count){return 'Exit/trap statements cannot be imported.'}
    return $null
}
function Get-UDInstrumentedFunction($Function,[switch]$Trace) {
    $text=$Function.Extent.Text;$base=$Function.Extent.StartOffset
    if(-not $Trace -or -not $Function.Body.EndBlock.Statements.Count){return $text}
    $edits=New-Object 'System.Collections.Generic.List[object]'
    foreach($branch in $Function.Body.FindAll({param($n)$n -is [System.Management.Automation.Language.IfStatementAst]},$true)) {
        foreach($clause in $branch.Clauses){
            $condition=$clause.Item1.Extent.Text.Replace("'","''")
            $edits.Add(@{At=$clause.Item2.Extent.StartOffset-$base+1;Text="`nAdd-UDTrace '$($Function.Name)' 'TRUE: $condition'`n"})
        }
        if($branch.ElseClause){
            $condition=(($branch.Clauses | ForEach-Object {$_.Item1.Extent.Text}) -join ' OR ').Replace("'","''")
            $edits.Add(@{At=$branch.ElseClause.Extent.StartOffset-$base+1;Text="`nAdd-UDTrace '$($Function.Name)' 'ELSE: none true: $condition'`n"})
        }
    }
    $edits.Add(@{At=$Function.Body.EndBlock.Statements[0].Extent.StartOffset-$base;Text="try {`n"})
    $sourceNames=@($Function.Body.FindAll({param($n)$n -is [System.Management.Automation.Language.VariableExpressionAst]},$true) |
        ForEach-Object { $_.VariablePath.UserPath -replace '^(?:local|script|private):','' } | Sort-Object -Unique)
    $nameLiteral=(@($sourceNames | ForEach-Object {"'"+$_.Replace("'","''")+"'"}) -join ',')
    $edits.Add(@{At=$Function.Body.Extent.EndOffset-$base-1;Text="`n} finally { Add-UDVariables '$($Function.Name)' (Get-Variable -Scope Local) -AllowedNames @($nameLiteral) }`n"})
    foreach($edit in ($edits | Sort-Object -Property { [int]$_.At } -Descending)){$text=$text.Insert($edit.At,$edit.Text)}
    return $text
}
function Get-UDRoot([string]$Directory,$Config) {
    $current=Get-Item -LiteralPath $Directory
    while($current){if($current.Name -eq 'Decide4Action'){return $current.FullName};$current=$current.Parent}
    if($Config.serverPath -match '^(.*?)\\ServerExternalActions(?:\\|$)'){return $matches[1]}
    if((Split-Path $Directory -Leaf) -match '^(Configuration|Config)$'){return Split-Path $Directory -Parent}
    return $Directory
}
function Initialize-UDSql($Config,[string]$Mode,[string]$KeyText,[string]$IVText) {
    $script:SqlConnectionString=$null;$script:UDSqlProblem=$null
    try {
        $builder=New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $builder['Data Source']=$Config.serverName;$builder['Initial Catalog']=$Config.dataDatabaseName
        $builder['Connect Timeout']=8
        $auth=$false;if($Config.windowsAuth -is [bool]){$auth=$Config.windowsAuth}elseif($Config.windowsAuth){$auth=[bool]::Parse([string]$Config.windowsAuth)}
        $builder['Integrated Security']=$auth
        if(-not $auth){
            $password=[string]$Config.password
            if(-not $KeyText){$KeyText=[Environment]::GetEnvironmentVariable('D4AKEY','Machine')}
            if(-not $IVText){$IVText=[Environment]::GetEnvironmentVariable('D4AIV','Machine')}
            $cipher=$null;try{$cipher=[Convert]::FromBase64String($password)}catch{}
            $looksEncrypted=$cipher -and $cipher.Length -ge 16 -and ($cipher.Length % 16 -eq 0)
            if($Mode -eq 'Encrypted' -or ($Mode -eq 'Auto' -and $looksEncrypted)){
                if(-not $keyText -or -not $ivText){throw 'Possible encrypted password; D4AKEY/D4AIV machine variables are unavailable. Use -PasswordMode Plain only if the stored password is plain text.'}
                $aes=[Security.Cryptography.Aes]::Create()
                try {
                    $aes.Key=[Convert]::FromBase64String($keyText);$aes.IV=[Convert]::FromBase64String($ivText)
                    $decryptor=$aes.CreateDecryptor()
                    try{$bytes=$decryptor.TransformFinalBlock($cipher,0,$cipher.Length);$password=(New-Object Text.UTF8Encoding $false,$true).GetString($bytes)}finally{$decryptor.Dispose()}
                }catch{throw 'Password decryption failed. Verify D4AKEY/D4AIV and encryption format; use -PasswordMode Plain if this is actually a plain-text password.'}finally{$aes.Dispose()}
            }
            $script:UDSecrets+=@($password,[string]$Config.password,$keyText,$ivText)
            $builder['User ID']=$Config.userName;$builder['Password']=$password
        }
        $script:SqlConnectionString=$builder.ConnectionString
    }catch{$script:UDSqlProblem=$_.Exception.Message}
}
function New-UDState {
    return @{RestartPlan=@{};Counters=@{Unprocessed=@{LastCount=0;ConsecutiveIncrease=0};MqttBroker=@{LastEventCheckUtc=$null}};DailyRestart=@{LastRunDate=$null};ForcedRestarts=@{}}
}
function Get-UDCallGuard($Call) {
    $parent=$Call.Parent
    while($parent){
        if($parent -is [System.Management.Automation.Language.ForEachStatementAst]){
            return @{Allowed=$false;Reason='Unsupported function call inside a source foreach loop; loop bindings require an adapter.'}
        }
        if($parent -is [System.Management.Automation.Language.IfStatementAst]){
            $selected=$null;$branchConditions=New-Object 'System.Collections.Generic.List[object]'
            foreach($clause in $parent.Clauses){
                $condition=$clause.Item1
                $issue=Get-UDAuditIssue $condition @() -Configuration
                if($issue){return @{Allowed=$false;Reason="Unsupported outer guard: $issue"}}
                foreach($variable in $condition.FindAll({param($n)$n -is [System.Management.Automation.Language.VariableExpressionAst]},$true)){
                    $name=$variable.VariablePath.UserPath
                    if($name -notin @('true','false','null') -and -not (Get-Variable -Name $name -ErrorAction SilentlyContinue)){
                        return @{Allowed=$false;Reason="Unsupported outer guard variable: $name"}
                    }
                }
                $truth=[bool](& ([scriptblock]::Create($condition.Extent.Text)))
                if($truth){$selected=$clause.Item2;break}
            }
            if(-not $selected){$selected=$parent.ElseClause}
            if(-not $selected -or $Call.Extent.StartOffset -lt $selected.Extent.StartOffset -or $Call.Extent.EndOffset -gt $selected.Extent.EndOffset){
                return @{Allowed=$false;Reason="Source outer condition skips this check: $($parent.Clauses[0].Item1.Extent.Text)"}
            }
        }
        $parent=$parent.Parent
    }
    return @{Allowed=$true;Reason=$null}
}
function Reset-UDCapture {
    $script:UDMessages=New-Object 'System.Collections.Generic.List[object]'
    $script:UDActions=New-Object 'System.Collections.Generic.List[object]'
    $script:UDTrace=New-Object 'System.Collections.Generic.List[string]'
    $script:UDVariables=@{}
}
# Do not name this parameter $Name: PowerShell's dynamic scope would shadow
# the caller's $name (the executable function) with the human-readable label.
function Show-UDSection([string]$SectionLabel,[scriptblock]$Scan,[string[]]$Rules) {
    Reset-UDCapture
    Microsoft.PowerShell.Utility\Write-Host "`n================================================================" -ForegroundColor Cyan
    Microsoft.PowerShell.Utility\Write-Host (Get-UDCheckCaption $SectionLabel) -ForegroundColor Cyan
    $failure=$null
    try{& $Scan | Out-Null}catch{$failure=Protect-UDText $_.Exception.Message;Add-UDMessage 'SCAN ERROR' $failure -Kind Error}
    Add-UDServiceSuggestions
    $info=Get-UDDecisionInfo $failure;$decision=$info.Decision;$color=$info.Color
    $readableRules=@(Get-UDReadableRules $Rules $SectionLabel)
    if($readableRules.Count){
        Microsoft.PowerShell.Utility\Write-Host 'Conditions evaluated by the installed watchdog:'
        foreach($description in $readableRules){Microsoft.PowerShell.Utility\Write-Host "  - Check whether: $description"}
    }elseif($Rules.Count){Microsoft.PowerShell.Utility\Write-Host 'This check uses additional source-specific conditions; use -ShowTechnicalDetails to inspect them.'}
    Microsoft.PowerShell.Utility\Write-Host "Decision: $decision" -ForegroundColor $color
    if($decision -like 'MET -*'){
        $triggerDescriptions=@(Get-UDTriggerDescriptions)
        foreach($reason in $triggerDescriptions){Microsoft.PowerShell.Utility\Write-Host "  Trigger condition: $reason" -ForegroundColor $color}
        if(-not $triggerDescriptions.Count){Microsoft.PowerShell.Utility\Write-Host '  The source requested this action without recording a descriptive reason; inspect -ShowTechnicalDetails.' -ForegroundColor Yellow}
        foreach($message in ($script:UDMessages | Where-Object Kind -eq 'Deferred')){
            $explanation=$message.Details -replace '(?i)\s*(Original trigger|Reason):.*$',''
            Microsoft.PowerShell.Utility\Write-Host "  Why deferred: $explanation" -ForegroundColor Yellow
        }
    }
    if($info.Cause){Microsoft.PowerShell.Utility\Write-Host "  Explanation: $($info.Cause)" -ForegroundColor $color}
    if($info.NextStep){Microsoft.PowerShell.Utility\Write-Host "  Next step: $($info.NextStep)" -ForegroundColor $color}
    Show-UDDcStalenessExplanation
    Show-UDReadableMeasurements
    foreach($message in $script:UDMessages){
        if(-not $ShowTechnicalDetails -and $message.Title -eq 'Restart history'){continue}
        if($decision -like 'NOT ASSESSABLE*' -and $message.Title -eq 'Source health result'){
            Microsoft.PowerShell.Utility\Write-Host '  The watchdog reported Healthy from this query; actual workflow health remains unverified.' -ForegroundColor Yellow
            continue
        }
        $line="$($message.Title): $($message.Details)" -replace 'Restart succeeded','Restart would be attempted' -replace 'Restarted service','Would restart/start service' -replace 'restarted successfully','would be restarted' -replace 'Restart triggered;','Restart evaluated;' -replace ': restarted', ': would restart' -replace ': started', ': would start' -replace ' started\.', ' would be started.'
        $lineColor=switch($message.Kind){'Error'{'Red'} 'Action'{'Red'} 'Warning'{'Yellow'} 'Deferred'{'Yellow'} 'Healthy'{'Green'} default{$color}}
        Microsoft.PowerShell.Utility\Write-Host "  $line" -ForegroundColor $lineColor
    }
    if($ShowTechnicalDetails){
        Microsoft.PowerShell.Utility\Write-Host '  Technical details from the source:' -ForegroundColor Cyan
        foreach($rule in $Rules){Microsoft.PowerShell.Utility\Write-Host "    Source condition: $(Protect-UDText $rule)"}
        foreach($key in ($script:UDVariables.Keys | Sort-Object)){Microsoft.PowerShell.Utility\Write-Host "    $key = $($script:UDVariables[$key])"}
        foreach($trace in ($script:UDTrace | Select-Object -Unique)){Microsoft.PowerShell.Utility\Write-Host "    Branch taken: $trace"}
    }
    foreach($action in $script:UDActions){Microsoft.PowerShell.Utility\Write-Host "  WOULD $($action.Action.ToUpperInvariant()): $($action.Service)" -ForegroundColor Red}
    $script:UDSummary.Add([pscustomobject]@{Check=$SectionLabel;Decision=$decision;Color=$color})
}

function Get-UDCheckCaption([string]$Label) {
    $captions=@{
        'Test-APIEndpoint'='API endpoint availability'; 'Invoke-DailyServiceRestart'='Daily scheduled restart'
        'Test-MqttBrokerStateAndErrors'='MQTT broker health'; 'Test-MdcHealth'='MDC communication heartbeat'
        'Test-PLCConnections'='PLC connection freshness'; 'Test-DcLastEvent'='Data Collector activity'
        'Test-UnprocessedQueue'='Unprocessed event queue'; 'Test-WorkflowLog'='Workflow processing'
        'Test-ProcessKpis'='KPI processing'; 'Test-ScheduledCommands'='Scheduled command execution'
    }
    if($captions.ContainsKey($Label)){return $captions[$Label]}
    if($Label -match '^EnsureServiceRunning \[(.+)\]$'){return "Windows service: $($matches[1])"}
    return $Label
}
function Get-UDTermLabel([string]$Token) {
    $labels=@{
        'lossRatio'='proportion of missing or stale connections';'thresholdRatio'='restart loss threshold'
        'lossPercent'='connection loss';'thresholdPercent'='restart loss threshold'
        'expectedCount'='expected equipment rows';'observedCount'='observed connection topics'
        'missingCount'='missing topics by the source count calculation';'staleCount'='stale connection topics'
        'totalLoss'='total missing or stale connections';'lossBasis'='connections used as the loss denominator'
        'thresholdSeconds'='maximum permitted age';'ageSeconds'='age of the evaluated sample'
        'observedAgeSeconds'='observed age';'ageMinutes'='elapsed age';'count'='queued event count'
        'maxCount'='maximum queued event count';'maxAge'='maximum age of queued events'
        'globalAge'='global heartbeat age';'freshestAge'='freshest device heartbeat age'
        'globalAlive'='the global heartbeat is fresh';'aliveDevices'='number of devices with fresh heartbeats'
        'totalDevices'='number of discovered devices';'frequency'='command execution interval'
        'secondsSinceExecution'='time since the command last ran';'requiredDelay'='required restart cooldown'
        'timeSinceLastRestart'='time since the last restart attempt';'remaining'='remaining restart wait'
        'lastRestartTime'='last restart attempt';'RequiredHealthySeconds'='required continuous recovery period'
        'requiredSeconds'='required continuous recovery period';'healthySeconds'='observed recovery duration'
        'healthySince'='start of the recovery period';'LastHealthy'='last healthy observation'
        'messageCount'='maximum MQTT messages sampled';'next'='next permitted check time'
        'lastDate'='last recorded processing time';'firstDate'='oldest queued event time'
        'query'='database query';'countQuery'='queue-count query';'oldestQuery'='oldest-event query'
        'globalTopic'='global heartbeat topic';'plcServiceName'='PLC service name'
        'service'='Windows service';'cfg'='monitor configuration';'PLCConfig'='PLC monitor configuration'
        'samples'='valid MQTT samples';'timestamp'='sample timestamp';'lastRun'='last scheduled restart date'
        'MaxObservationGapSeconds'='maximum gap between health observations'
        'RestartThresholdPercent'='restart loss threshold';'StaleSeconds'='maximum contact age'
        'WorkflowLogMinutes'='workflow inactivity limit';'ProcessKpiMinutes'='KPI inactivity limit'
        'DcLastEventSeconds'='Data Collector inactivity limit';'MdcGlobalTopicSeconds'='global heartbeat age limit'
        'MdcDeviceTopicSeconds'='device heartbeat age limit';'UnprocessedMaxCount'='queue size limit'
        'UnprocessedMaxAgeMinutes'='queue age limit';'ScheduledCommandGraceSeconds'='allowed command grace period'
        'ErrorLookbackMinutes'='event-log lookback window';'MaxEventSamples'='maximum event samples'
        'Enabled'='monitor enabled setting';'TimeOfDay'='configured daily restart time'
    }
    $name=($Token.TrimStart('$') -split '\.')[-1]
    if($labels.ContainsKey($name)){return $labels[$name]}
    return (($name -creplace '([a-z0-9])([A-Z])','$1 $2') -replace '_',' ').ToLowerInvariant()
}
function Get-UDRecordedValue([string]$Variable,[string]$FunctionName) {
    $key="$FunctionName.$Variable"
    if($script:UDVariables.ContainsKey($key)){return $script:UDVariables[$key]}
    $keys=@($script:UDVariables.Keys | Where-Object {$_ -like "*.$Variable"})
    if($keys.Count -eq 1){return $script:UDVariables[$keys[0]]}
    return $null
}
function Format-UDValue([string]$Variable,$Value) {
    if($null -eq $Value -or [string]$Value -eq ''){return 'not recorded'}
    $leaf=($Variable -split '\.')[-1]
    if($leaf -match '(?i)Ratio$|^RestartThresholdPercent$'){
        $number=0.0
        if([double]::TryParse([string]$Value,[ref]$number)){return ('{0:0.##}%' -f ($number*100))}
    }
    if($leaf -match 'Percent$'){return "$Value%"}
    if($leaf -match '(?i)Seconds$|^(globalAge|freshestAge|observedAgeSeconds)$'){return "$Value seconds"}
    if($leaf -match '(?i)Minutes$'){return "$Value minutes"}
    return [string]$Value
}
function ConvertTo-UDTerm([string]$Expression,[string]$FunctionName) {
    $token=$Expression.Trim()
    if($token -match '^(\d+(?:\.\d+)?|''[^'']*''|"[^"]*")$'){return $token.Trim("'").Trim('"')}
    $special=@{
        '$table.Rows.Count'='number of returned database rows';'$staleSources.Count'='number of stale data sources'
        '$events.Count'='number of matching broker error events';'$samples.Count'='number of valid MQTT samples'
        '$latestPerTopic.Count'='number of valid connection topics';'$deviceStatus.Count'='number of measured devices'
        '$service.Status'='Windows service state';'$service.StartType'='Windows service startup mode'
        '$response.StatusCode'='HTTP response status';'$now.TimeOfDay'='current time of day'
    }
    if($special.ContainsKey($token)){return $special[$token]}
    if($token -match '^\$monitoringConfig(?:\.[A-Za-z_][A-Za-z0-9_]*)+$'){
        $value=$monitoringConfig
        foreach($part in ($token -split '\.' | Select-Object -Skip 1)){$value=$value[$part]}
        return "$(Get-UDTermLabel $token) ($(Format-UDValue $token $value))"
    }
    if($token -match '^\$[A-Za-z_][A-Za-z0-9_]*$'){
        $variable=$token.TrimStart('$');$label=Get-UDTermLabel $variable
        $value=Get-UDRecordedValue $variable $FunctionName
        if($null -ne $value -and [string]$value -ne ''){return "$label ($(Format-UDValue $variable $value))"}
        return $label
    }
    if($token -match '^\$[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$'){return Get-UDTermLabel $token}
    return $null
}
function ConvertTo-UDCondition([string]$Expression,[string]$FunctionName) {
    $text=$Expression.Trim()
    $known=@{
        '-not $monitoringConfig.DailyRestart.Enabled'='Daily scheduled restarts are turned off.'
        '$lastRun -and $lastRun.Date -eq $now.Date'='The daily restart already ran today.'
        '-not $cfg -or -not (ConvertTo-D4ABool $cfg.Enabled)'='This monitor is disabled or has no configuration.'
        '-not $PLCConfig -or -not (ConvertTo-D4ABool $PLCConfig.Enabled)'='The PLC monitor is disabled or has no configuration.'
        '-not $lastDate -or $lastDate -is [DBNull]'='No processing timestamp was returned by the database.'
        '-not $lastDate'='No processing timestamp was returned by the database.'
        '$globalAlive -and $aliveDevices -gt 0'='The global heartbeat is fresh AND at least one device has a fresh heartbeat.'
        '$count -eq 0 -or -not $firstDate'='The queue is empty OR no oldest-event timestamp was returned.'
        '-not $samples -or $samples.Count -eq 0'='No valid MQTT samples were available in the observation window.'
        '$service.Status -eq ''Running'''='The Windows service is running.'
        '$service.Status -eq "Running"'='The Windows service is running.'
        '$service.Status -ne "Running"'='The Windows service is not running.'
        '$service.StartType -eq ''Disabled'''='The Windows service is disabled.'
        '$service.StartType -eq "Disabled"'='The Windows service is disabled.'
        '-not $service'='The configured Windows service could not be found.'
        '$entry.IntervalIndex -eq 0'='The restart plan is already at its initial step.'
    }
    if($known.ContainsKey($text)){return $known[$text]}
    if($text -match '^-not \(IsCheckAllowed\b'){return 'The installed watchdog is postponing this check until its next permitted time.'}
    if($text -eq '$frequency -gt 0 -and $secondsSinceExecution -gt ($frequency + $monitoringConfig.Thresholds.ScheduledCommandGraceSeconds)'){
        return "The command has a positive execution interval AND its elapsed time exceeds that interval plus the allowed grace period ($($monitoringConfig.Thresholds.ScheduledCommandGraceSeconds) seconds)."
    }
    if($text -match '^\[string\]::IsNullOrWhiteSpace\((\$[\w.]+)\)$'){return "$(ConvertTo-UDTerm $matches[1] $FunctionName) is missing or blank."}
    if($text -match '^(\$[\w.]+)\s+-(ge|gt|le|lt|eq|ne)\s+(.+)$'){
        $leftToken=$matches[1];$operator=$matches[2];$rightToken=$matches[3]
        $left=ConvertTo-UDTerm $leftToken $FunctionName;$right=ConvertTo-UDTerm $rightToken $FunctionName
        $operators=@{ge='is at least';gt='exceeds';le='is at most';lt='is less than';eq='equals';ne='does not equal'}
        if($left -and $right){return "$left $($operators[$operator]) $right."}
    }
    return $null
}
function Get-UDReadableRules([string[]]$Rules,[string]$FunctionName) {
    $result=New-Object 'System.Collections.Generic.List[string]'
    # Select operational checks rather than array-building/parsing branches.
    foreach($rule in $Rules){
        if($rule -notmatch '(?i)lossRatio|ageMinutes|globalAlive.*aliveDevices|count -le \$maxCount|ageMinutes -le \$maxAge|staleSources.Count|frequency -gt 0|service\.(Status|StartType)|response.StatusCode|DailyRestart.Enabled|now.TimeOfDay|lastRun.Date|IsCheckAllowed|\-not \$lastDate|\-not \$samples|\-not \$service$'){continue}
        $description=ConvertTo-UDCondition $rule $FunctionName
        if($description -and -not $result.Contains($description)){$result.Add($description)}
    }
    if(-not $result.Count){
        foreach($rule in $Rules){$description=ConvertTo-UDCondition $rule $FunctionName;if($description -and -not $result.Contains($description)){$result.Add($description)}}
    }
    return $result.ToArray()
}
function Get-UDDecisionInfo($Failure) {
    $messages=@($script:UDMessages.ToArray());$kinds=@($messages | ForEach-Object {$_.Kind})
    $text=($messages | ForEach-Object {"$($_.Title) $($_.Details)"}) -join "`n"
    $result=@{Decision='SUCCESS - no restart requested by source logic';Color='Green';Cause=$null;NextStep=$null}
    if($script:UDActions.Count){$result.Decision='MET - ACTION WOULD BE TRIGGERED';$result.Color='Red'}
    elseif($kinds -contains 'Deferred'){$result.Decision='MET - RESTART DEFERRED';$result.Color='Yellow'}
    elseif($text -match '(?i)unsupported'){
        $result.Decision='UNSUPPORTED CHECK - diagnostic cannot evaluate this watchdog logic';$result.Color='Yellow'
        $result.Cause='The diagnostic does not support part of this check. This does not establish a service failure.'
    }
    elseif($Failure -or $kinds -contains 'Error'){$result.Decision='FAILED / ERROR - decision incomplete';$result.Color='Red'}
    elseif($text -match 'Placeholder query'){
        $result.Decision='NOT ASSESSABLE - workflow query does not measure workflow activity';$result.Color='Yellow'
        $result.Cause='The configured query returns the current SQL server time. An age of zero does not prove that workflow processing is running.'
        $result.NextStep='Configure a query that returns the timestamp of the last real workflow execution. This result does not establish a workflow service failure.'
    }
    elseif($text -match 'Schedule disabled'){
        $result.Decision='DISABLED BY CONFIGURATION - no daily restart scheduled';$result.Color='Yellow'
        $result.Cause='Daily scheduled restarts are turned off in the installed watchdog. This is a configuration choice, not a failed service check.'
    }
    elseif($text -match 'Schedule already completed'){
        $result.Decision='NOT DUE - daily restart already completed today'
        $result.Cause='The saved restart history prevents a second daily restart on the same date.'
    }
    elseif($text -match 'Schedule not due'){
        $result.Decision='NOT DUE - daily restart time has not been reached'
        $result.Cause='The installed watchdog is waiting for the configured time of day.'
    }
    elseif($text -match '(?i)check skipped until|check.*deferred until'){
        $result.Decision='CHECK DEFERRED - waiting for the next permitted check time';$result.Color='Yellow'
        $result.Cause='The installed watchdog pauses this check during its check cooldown. Current health has not been assessed by this check.'
    }
    elseif($text -match '(?i)disabled'){
        $result.Decision='DISABLED - automatic action is not enabled';$result.Color='Yellow'
        $result.Cause='The source monitor or Windows service is disabled. See the recorded configuration or service message below.'
    }
    elseif($text -match '(?i)no MQTT|no valid MQTT|no .*samples|did not contain.*topics'){
        $result.Decision='NO VALID DATA - MQTT freshness could not be assessed';$result.Color='Yellow'
        $result.Cause='No usable samples were available. The output alone does not distinguish missing publications, topic mismatch, connection problems, or invalid timestamps.'
    }
    elseif($kinds -contains 'Warning' -or ($messages.Count -eq 0 -and $script:UDVariables.Count -eq 0)){
        $result.Decision='NOT ASSESSED - source did not provide a conclusive health result';$result.Color='Yellow'
        $warning=$messages | Where-Object Kind -eq 'Warning' | Select-Object -First 1
        if($warning){$result.Cause=$warning.Details}
    }
    if($Failure -and $script:UDActions.Count){$result.Decision+='; later scan error'}
    return $result
}
function ConvertTo-UDStaleSourceDescription([string]$Text) {
    return [regex]::Replace($Text,'(?i)\b(LineStatus|EquipmentStatus)\s+(\d+)\s+s\b',{
        param($match)
        $label=if($match.Groups[1].Value -eq 'LineStatus'){'Line status data'}else{'Equipment status data'}
        $seconds=[double]$match.Groups[2].Value
        $duration=if($seconds -ge 86400){'{0:N1} days' -f ($seconds/86400)}elseif($seconds -ge 3600){'{0:N1} hours' -f ($seconds/3600)}elseif($seconds -ge 60){'{0:N1} minutes' -f ($seconds/60)}else{"$seconds seconds"}
        "$label has a reported event age of $duration ($($match.Groups[2].Value) seconds)"
    }) -replace 'LastEventTime stale:', 'Database event timestamps exceed the allowed age:'
}
function Show-UDDcStalenessExplanation {
    $evidence=@($script:UDMessages | Where-Object {$_.Details -match 'LastEventTime stale:'})
    if(-not $evidence.Count){return}
    Microsoft.PowerShell.Utility\Write-Host '  Potential cause: An inactive line or equipment record may still be included in the stale-data check.' -ForegroundColor Yellow
    Microsoft.PowerShell.Utility\Write-Host '  To confirm, run in the watchdog database: SELECT * FROM P4A_LineMonitoringStatus;' -ForegroundColor Yellow
    Microsoft.PowerShell.Utility\Write-Host '  Check for old RunStartTime values, then compare LastEventTime and verify whether those lines are still active.' -ForegroundColor Yellow
}
function Get-UDTriggerDescriptions {
    $reasons=New-Object 'System.Collections.Generic.List[string]'
    foreach($message in $script:UDMessages){
        if($message.Details -match '(?i)(?:Original trigger|Reason|Conditions met):\s*(.+)$'){$reasons.Add($matches[1])}
        elseif($message.Details -match '(?i)Service .+ is not running'){$reasons.Add(($message.Details -replace '\s*Attempting to start\.?',''))}
    }
    if(-not $reasons.Count){
        foreach($key in $script:UDVariables.Keys){if($key -match '\.reason$' -and $script:UDVariables[$key]){$reasons.Add($script:UDVariables[$key])}}
    }
    if(-not $reasons.Count){
        foreach($trace in $script:UDTrace){
            if($trace -match '^(.+?) : TRUE: (.+)$'){
                $description=ConvertTo-UDCondition $matches[2] $matches[1]
                if($description){$reasons.Add($description)}
            }
        }
    }
    return @($reasons.ToArray() | Select-Object -Unique | ForEach-Object {
        $reason=$_
        if($reason -match 'GlobalAlive=(True|False), AliveDevices=(\d+), DevicesDiscovered=(\d+)'){
            $parts=New-Object 'System.Collections.Generic.List[string]'
            if($matches[1] -eq 'False'){$parts.Add('The global heartbeat is missing or older than its allowed age.')}
            if([int]$matches[2] -eq 0){$parts.Add('No device heartbeat is fresh enough.')}
            $parts.Add("Devices discovered: $($matches[3]).")
            $reason=$parts -join ' '
        }
        ConvertTo-UDStaleSourceDescription ($reason -replace 'MDC-LastContact loss','PLC connection loss')
    })
}
function Show-UDReadableMeasurements {
    $printed=New-Object 'System.Collections.Generic.List[string]'
    foreach($key in ($script:UDVariables.Keys | Sort-Object)){
        $variable=($key -split '\.')[-1]
        if($variable -notmatch '^(expectedCount|observedCount|missingCount|staleCount|totalLoss|lossBasis|lossPercent|thresholdPercent|thresholdSeconds|observedAgeSeconds|ageMinutes|count|maxCount|maxAge|globalAge|freshestAge|aliveDevices|totalDevices|frequency|secondsSinceExecution|requiredDelay|timeSinceLastRestart|remaining|lastRestartTime|RequiredHealthySeconds|requiredSeconds|healthySeconds)$'){continue}
        $value=$script:UDVariables[$key]
        if($null -eq $value -or $value -eq ''){continue}
        if($variable -match '^(RequiredHealthySeconds|requiredSeconds)$' -and $value -eq '0'){continue}
        $line="$(Get-UDTermLabel $variable): $(Format-UDValue $variable $value)"
        if(-not $printed.Contains($line)){$printed.Add($line);Microsoft.PowerShell.Utility\Write-Host "  $line"}
    }
}

# APPROVED_FUNCTION_DIGESTS is populated when the standalone file is built.
$script:UDApproved=@{
    '03B60020DED743801B66EA50E7393454249ACEDA6A32DF44FE09017487E91F51' = 'Invoke-DiagnosticCheck'
    '06C77DA289F13574F550BDDA21F366721362B0EEE9EEC473FA9E4F5463368341' = 'Get-ServiceStartTime'
    '0B1B6EDBEC882381FCFA604AD2B2D31240ED235601789213902FC8218B985EE4' = 'Test-WorkflowLog'
    '0F736DC00F0E7B50534B12D63AD974D164FB5C295B33A50B1839A91B37500F12' = 'Get-MqttTopicTimestamp'
    '1098FA8BC0FEB7C70879957EE15D483353079B6D69713F02790C481378D85F26' = 'Write-LogMessage'
    '14F055F72168AC6B59C5E6CC9EC023EFF26A051CD42F8E0F8A629757AF159EE4' = 'ParseMqttPublishPayload'
    '209F8E5D1F10C45E13F12FA31A79F063C1DA47D41D17EF335295FDBD79515162' = 'Invoke-SqlScalar'
    '2399C5F61F37761B13C86B1521F63C6A3361A9BFF2D19CF4983691952AF8652B' = 'Invoke-ProgressiveRestart'
    '2606CA8FE9E76367D4BD526F63CEFA6AAD04BFFAC0515ABD07BB4A13D1F8F6FA' = 'Initialize-MonitoringState'
    '2AFAA7F1ED1907332599FCD4BA4C42C5470C414CC79FF47D18DF8F4C90F3E4CB' = 'Read-MqttExact'
    '3151DD1D00510D745B923B1536983ED1AC55381E19DBBAE7F541D96E0FC06D3E' = 'Test-ScheduledCommands'
    '338F1024DE6D31411905EDEAEB1718627B2E219D6548A8C5A0654E0E06C6ACCC' = 'Write-DiagnosticLog'
    '37EC37FBE1361960A6E393A76E4A9E2D30E42D06E16762CB30782FA5DDF4F70D' = 'Test-ScheduledCommands'
    '3DDCD25690703A42D24CB644DC841E518EA46334307B62D9D910A74DE2798398' = 'Get-MqttConnectionInfo'
    '3EAC90863988C120956B9F44400098FEA2DC3E5E47EE5B98A76F2398B1BB5E4D' = 'Set-HealthCheckStatus'
    '4189689BC73219D47E56203E5305687E8FF127A94442E012A635C6F16F9C40D8' = 'Get-MdcDeviceSnapshot'
    '443CEF57676426400AF290809AAC68B1CBCF0124F8DD4A1B270A6ECD4AE197E1' = 'Invoke-MqttSubscription'
    '52438C4935D21C26832EA2CE7E7516177D7579B6C201D643B347A3587C78F07A' = 'Invoke-DailyServiceRestart'
    '5836AB16955B0E9066A18F8BC077789268D8B61F849FF5C58EAD1D046E7D3D7C' = 'Get-MqttBrokerErrorEvents'
    '59811713368130C8C8AB4834D65E803D3583BDBF95A38736D40AF18E9CBF3F35' = 'Test-APIEndpoint'
    '5B23A1DEED842EB656452105233EB1E5176F18FC19E8E4FB62206D44FD0E05F6' = 'Get-MqttSamples'
    '5E58044B258B755D74D6246C9A3FE487448A58A569E7D3CF4B8AD74596439CAF' = 'Test-APIEndpoint'
    '600F4EB05B1E1F8AB9F7AE93789460B85DE68FF6662C27EF1931DD7EA3099CFA' = 'Read-MqttRemainingLength'
    '62B2CE2B9E34B0C48838B93504D1A6B1926EBAF25D369446C17B481D7D124476' = 'Receive-MqttPacket'
    '6642FF5918E3EFC26BC99357E0E9CF76680A3DA96F373E44E45A668DF15C738D' = 'Reset-RestartPlan'
    '678343E0D6BD1883B3846078D5760BA720588737DE919FCF259830DCE3867E52' = 'EnsureMqttCertificate'
    '6C187F1CDC0F78E2FD15999920EAF0CDFF1D3A696C786E02D95D9EC82603731F' = 'EnsureMqttCertificate'
    '6C4BEDECE0FEF90DDCBE2C4017609F35809FCBE31362D8A319924B579AAC1392' = 'Invoke-MqttTandemRestart'
    '6CCFACF1554BBFEFCB78A0E0C7BFE6DD9DE46E59DAEA1A217CA732535EE421B0' = 'Resolve-MosquittoService'
    '70FCA890E048114DD04D95304B9AB81D919C11B5C321542C180EDED453373079' = 'Invoke-SqlQuery'
    '7179F7D65DB2E224E6BC4E2252B137DAEE7FE036D1D11E241528E641872EB785' = 'Get-AggregatedHealthStatus'
    '79D0246581A990768EAA747DC5F98D3CB23D44105CFF822A39F1816787AD6883' = 'Write-LogMessage'
    '7F8198F547CABC44971AB49E96D19D80E6821360DBDAB3DE8D7C068A4EEF6F20' = 'Get-MqttSamples'
    '84E76915BCF7679B80C345273B6699FE1752818F72F160898C72EDCC703BFB6D' = 'Invoke-MdcMqttCoupledRestart'
    '863A356F78A4948688A8A4F1CFF6E51551F22EFE40F6EEE8645D4570FA0CC411' = 'ConvertTo-MonitoringHashtable'
    '8B6CAA77473B2063E0B2851CDEA8B8FBA284BE4C337F75594B59F881E64FDEF8' = 'ParseMqttPayloadTimestamp'
    '8C2E1370761EBFB53E679FFD6048888F61D9E347DE93990D448AD98FF9A6C7C0' = 'Test-UnprocessedQueue'
    '92620C834BFC8C4A41D2DCEC41A55E23F9D86539D6EB7B48E48C6EF31FAC6322' = 'Get-RestartPlanEntry'
    '9A5FBC93CAD7FC3B044A9C5D1BC9A95DE3C679C6D4A353E398D29B64FC64C480' = 'ConvertTo-MqttStringBytes'
    '9BD209C1B6716C05E851B912197836E23DB0AE94221E1B05709C827C4EB0DAFD' = 'Save-MonitoringState'
    '9C3F6E8981CA4E0ECC4B315D11F96D476904DF17F143910DEC37D9CF1231B3AF' = 'Get-ServiceKeyFromName'
    'A41E95FCA9DD2E0092FB6236AAB332E1CC36EC4F8B893EA750E559231F107128' = 'Test-WorkflowLog'
    'A7F1889A239A873D660D30D7346062B69895E21ED4FC3D5B573F8C9CB94F7B3B' = 'Invoke-ProgressiveRestart'
    'AA8F48AC810D1E783B6B958BE3A876A5FD60AFFF515581F1A68A541646D9F892' = 'Write-MonitorLog'
    'AC9BCFAF6EE00A1BFF8F6E7A41894DFA654CEDB3AF182EFA625D509570B73139' = 'IsCheckAllowed'
    'AD280359B381E7F1C0399F9EC74896CB9713647D6FBF33F300CB81376910D2EB' = 'Test-ProcessKpis'
    'ADEC35C7B1367E90D0A6AD0E6F76916E83F1C5A9D9C188ACB67C4B5BC3E07141' = 'Get-LastForcedRestartTimestamp'
    'B0CEE443EA8A527D2110B246FDD59DDDF8E800FB74B5E8A0E1C916A019A75BB6' = 'Write-ServiceLog'
    'B15287070F4B698AFAAFBAD051B97F4DFF9E309D5B582A1D12D4FEAA75C0E863' = 'Get-RestartPlanMinutes'
    'B19CD10C5893B5CE88CA6356E53CBBB1B849DC4ED4629C80021DEA02A19B1475' = 'Invoke-MdcMqttCoupledRestart'
    'B454FAF9680D0F5D0FB6FF4498597C779D9F72A28E6C137F1B0A9D85B0A3BFCC' = 'EncodeMqttRemainingLength'
    'BBF3B89BC432BCDFB2831686BCA82BA7DB5EC3A0E4BA3A9A97686150706CF904' = 'EnsureServiceRunning'
    'BCE72C8AEB17939F41DA5C8FE790F8FD6B864C5785BA3C73F1AA3E2F342D37B9' = 'Get-HealthCheckStatus'
    'BDDBC1B70C264B74D10E84ACD3569DE10A2377B3D3D87F97B4F6245BFDFC271C' = 'Invoke-WatchdogServiceAction'
    'C04FA57924C2FCBA7E6C1849C479353109DB8954F6BD4A84677FEDDA46FCB889' = 'Test-PLCConnections'
    'C1415725C407E991D03DC291A1E9944C2CD959B8FA47C4B745522CBEFAA54B2D' = 'Test-MqttBrokerStateAndErrors'
    'C1D5753527CFFBFFC26DE9E25EE7ABF3B70512786A81BD98D119CCB8DD3669F4' = 'Invoke-DailyServiceRestart'
    'C4EA4A4E3160BFCEE1202AA4ACBAB4224C025C6C8329F458E9A9AE5462B05312' = 'Get-LogServiceKeyFromPrefix'
    'D4601C1A79FDD53460A2563D180AA59E96411DE09F5615423FF9361A990BF5FF' = 'Test-PLCConnections'
    'D6DB723675A6E5824EBCE15008407D8D624086E4D11F362AC3A55F9FEBFAFCF0' = 'Test-PLCConnections'
    'DA52BCCB4B765FDC24A61335CBE8693467077FDC0CC0086CDB2079730F095B59' = 'Test-MdcHealth'
    'DC06079792E095976EE664C5396B5C6ADDB5BAF08107C84C49AFC360D4F4DF2C' = 'Update-PlcRestartPolicy'
    'DD7B31F907C1AD15796E632FA5A0AE31088101DC0E029D8215A68C368C335D42' = 'ConvertTo-D4ABool'
    'DF5A0398D9CB702207B047171A4013D397DA97D6E3318CD2B410FC1B908DCA81' = 'EnsureServiceRunning'
    'DFCA6FD774E51D7E91E9AA1259D7F3F4FD64F60B49FDFB5F33E3BD371B74267B' = 'Test-UnprocessedQueue'
    'E8D0272211260147E59C1F15F683A779FAAB044D01E4A0F90C465011D53BB3AD' = 'Invoke-HealthDataPublish'
    'E9899B652CC0EDB45319E0325E25BDE42ADD3E98C2311839BE6977E091A4FAA2' = 'Test-DcLastEvent'
    'EA64C20294ABFB23F42268E574C0E75F514BE4D805A59413A72A27B9A43326B7' = 'Initialize-MonitoringState'
    'EB4B64CC2E1FA611DDF58E916CDB3C33CBD516A212AC8A03F425C7400C8C247D' = 'Get-ServiceLogFilePath'
    'ED5FF70F2A47363F125541F9A0B3F6CF3FC86E09C98D48B706DA5C6F046BDE0B' = 'Get-NormalizedApiBaseEndpoint'
    'F137E793F822B993E15E43618DA2C6526305C70FEF499EF20215D2448F00C783' = 'DecryptString'
    'F15CB1B397AC5C73DFD6564CD9F1DE201E2F6A4339924BA85930577148E5D3AC' = 'Get-MonitorServiceKey'
    'F6C0B5A8EC5F3E30358D14080625A442EA0276BAA9E915343CA63BBD0FFCBEFE' = 'Invoke-WatchdogDiagnostics'
    'F88A4A28BDA7655C1968288C9D9BDB995B944E29A846506A07D38988EC74D012' = 'Get-ServiceHealthLabel'
    'FCE39DFF282F8F883160A84322098835995503FBDCDB5EDAB3938B5813695EC9' = 'Write-ServiceLog'
}
# APPROVED_FUNCTION_DIGESTS_END

if($LibraryOnly){return}
Reset-UDCapture
$script:UDSecrets=@();$script:UDSummary=New-Object 'System.Collections.Generic.List[object]'
if(-not $WatchdogPath){$WatchdogPath=Read-Host 'Enter the full path to D4AWatchdog.ps1'}
$WatchdogPath=$WatchdogPath.Trim().Trim('"').Trim("'")
if(-not (Test-Path -LiteralPath $WatchdogPath -PathType Leaf)){throw "Watchdog not found: $WatchdogPath"}
$WatchdogPath=(Resolve-Path -LiteralPath $WatchdogPath).Path
$sourceDirectory=Split-Path $WatchdogPath -Parent
if(-not $ConfigPath){$ConfigPath=Join-Path $sourceDirectory 'config.json'}
if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw "config.json not found at $ConfigPath. Supply -ConfigPath with its location."}
$ConfigPath=(Resolve-Path -LiteralPath $ConfigPath).Path
$json=Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$script:UDProtocolOverridePath=$null
$localPath=Join-Path (Split-Path $ConfigPath -Parent) 'config.local.json'
if(Test-Path -LiteralPath $localPath){
    $local=Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
    if($local.PSObject.Properties.Name -contains 'apiProtocol'){$script:UDProtocolOverridePath=$localPath}
    foreach($p in $local.PSObject.Properties){$json | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force}
}
$script:UDSecrets+=@([string]$json.password)
$serverPath=$json.serverPath;$serverName=$json.serverName;$databaseName=$json.dataDatabaseName
$monitoringRoot=Get-UDRoot $sourceDirectory $json
$logPath=Join-Path $monitoringRoot 'Log\TaskSchedulerOutput';$logDate=Get-Date -Format yyyyMMdd
$apiProtocol=if($json.apiProtocol){[string]$json.apiProtocol}else{'http'}
$tokens=$null;$parseErrors=$null
$sourceAst=[System.Management.Automation.Language.Parser]::ParseFile($WatchdogPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){
    foreach($entry in @(Get-UDParseFailureReport $WatchdogPath $parseErrors)) {
        Microsoft.PowerShell.Utility\Write-Host $entry.Text -ForegroundColor $entry.Color
    }
    return
}
$functions=@($sourceAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object {$_.Parent -is [System.Management.Automation.Language.NamedBlockAst]})
$functionNames=@($functions.Name)
$overrides=@('Write-Host','Write-LogMessage','Write-ServiceLog','Write-MonitorLog','Set-HealthCheckStatus','Get-ServiceLogFilePath','Start-Service','Restart-Service','Invoke-WatchdogServiceAction','Initialize-MonitoringState','Save-MonitoringState','Invoke-HealthDataPublish','EnsureMqttCertificate','Invoke-WebRequest','Invoke-SqlQuery','Invoke-SqlScalar','DecryptString')
$skip=@('Invoke-WatchdogDiagnostics','Invoke-DiagnosticCheck','Write-DiagnosticLog')
$blocked=@{};$imported=@{}
foreach($function in $functions){
    if($function.Name -in $overrides -or $function.Name -in $skip){continue}
    if($function.Name -match '^(UD|.*-UD)'){throw 'Source function conflicts with diagnostic internals.'}
    $digest=Get-UDDigest $function.Extent.Text
    $issue=if($script:UDApproved.ContainsKey($digest)){$null}else{Get-UDAuditIssue $function $functionNames}
    if($issue){
        $blocked[$function.Name]=$issue
        $literal="Unsupported source function $($function.Name): $issue".Replace("'","''")
        . ([scriptblock]::Create("function $($function.Name) { throw '$literal' }"))
    }else{
        $trace=$function.Name -match '^(Test-|EnsureService|Invoke-.*Restart|Reset-RestartPlan|IsCheckAllowed|Update-PlcRestartPolicy)'
        try{
            . ([scriptblock]::Create((Get-UDInstrumentedFunction $function -Trace:$trace)))
            $imported[$function.Name]=$true
        }catch{
            $blocked[$function.Name]=$_.Exception.Message
            $literal="Unsupported instrumentation for $($function.Name): $($_.Exception.Message)".Replace("'","''")
            . ([scriptblock]::Create("function $($function.Name) { throw '$literal' }"))
        }
    }
}
# Evaluate only safe top-level configuration assignments, never the entry point.
$configurationProblems=New-Object 'System.Collections.Generic.List[string]'
foreach($statement in $sourceAst.EndBlock.Statements){
    if($statement -isnot [System.Management.Automation.Language.AssignmentStatementAst]){continue}
    $name=$statement.Left.Extent.Text.TrimStart('$')
    $isCorePolicy=$name -match '(?i)^(script:)?(monitoringConfig|thresholds|restartPlanMinutes|services|mqttConfig|PLCConfig|monitoringRoot|logPath|logDate|apiProtocol)$'
    $isPolicyScalar=$name -match '(?i)threshold|timeout|grace|interval|cooldown|retry|stale|seconds|minutes|^max|^min|^serviceName|^mqttHost|^mqttPort'
    if($isCorePolicy -or ($isPolicyScalar -and $name -notmatch ':')){
        $issue=Get-UDAuditIssue $statement.Right @() -Configuration
        if($issue){if($isCorePolicy){$configurationProblems.Add("$name : $issue")};continue}
        try{
            # Resolve the source's PSScriptRoot without changing this tool's scope.
            $expression=$statement.Right.Extent.Text.Replace('$PSScriptRoot',("'"+$sourceDirectory.Replace("'","''")+"'"))
            $value=& ([scriptblock]::Create($expression))
            Set-Variable -Name ($name -replace '^script:','') -Value $value
        }catch{$configurationProblems.Add("$name : $($_.Exception.Message)")}
    }
}
if(-not (Get-Variable monitoringConfig -ErrorAction SilentlyContinue)){$monitoringConfig=@{}}
$script:HealthChecks=@{}
$script:UDSecrets+=@([string]$monitoringConfig.Mqtt.MqttPassword,[string]$monitoringConfig.Mqtt.Password)
$State=New-UDState
$history='No saved state. Predictions use empty history; no file will be created.'
if(-not $StateFilePath){
    if($monitoringConfig.StateFilePath){$StateFilePath=[string]$monitoringConfig.StateFilePath}
    else{$StateFilePath=Join-Path $monitoringRoot 'Log\TaskSchedulerOutput\monitoring-state.json'}
}
if(Test-Path -LiteralPath $StateFilePath){
    try{
        $loaded=ConvertTo-UDHash (Get-Content -LiteralPath $StateFilePath -Raw | ConvertFrom-Json)
        foreach($key in $loaded.Keys){$State[$key]=$loaded[$key]}
        $history="Loaded: $StateFilePath"
    }catch{$history="INVALID STATE: $($_.Exception.Message). Predictions use empty history."}
}
Initialize-UDSql $json $PasswordMode
$decryptedPassword=if($script:SqlConnectionString){'-'}else{$null}
Microsoft.PowerShell.Utility\Write-Host "`nD4A WATCHDOG DIAGNOSTIC - installed policy, simulated actions" -ForegroundColor Cyan
Microsoft.PowerShell.Utility\Write-Host "Diagnostic version: $script:UDVersion"
Microsoft.PowerShell.Utility\Write-Host "Watchdog: $WatchdogPath"
Microsoft.PowerShell.Utility\Write-Host "Config: $ConfigPath"
Microsoft.PowerShell.Utility\Write-Host "Root: $monitoringRoot"
Microsoft.PowerShell.Utility\Write-Host "Time: $(Get-Date -Format o)"
Microsoft.PowerShell.Utility\Write-Host $history -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host 'No source entry point, service actions, file writes, or publication will be executed.' -ForegroundColor Yellow
if($script:UDSqlProblem){Microsoft.PowerShell.Utility\Write-Host "SQL setup: $script:UDSqlProblem" -ForegroundColor Red}
foreach($problem in $configurationProblems){Microsoft.PowerShell.Utility\Write-Host "UNSUPPORTED configuration: $problem" -ForegroundColor Red}
function Show-UDPolicy($Value,[string]$Prefix='') {
    if($Value -is [System.Collections.IDictionary]){
        foreach($key in ($Value.Keys | Sort-Object)){
            if($key -match '(?i)password|secret|token|credential|apikey|user|certificate|query|queries'){continue}
            Show-UDPolicy $Value[$key] "$Prefix$key."
        }
    }elseif($Value -is [array]){Microsoft.PowerShell.Utility\Write-Host "  $($Prefix.TrimEnd('.')) = $($Value -join ', ')"}
    else{Microsoft.PowerShell.Utility\Write-Host "  $($Prefix.TrimEnd('.')) = $(Protect-UDText $Value)"}
}
if($ShowTechnicalDetails){
    Microsoft.PowerShell.Utility\Write-Host "`nTHRESHOLDS / POLICY FROM THE INSTALLED FILE" -ForegroundColor Cyan
    Show-UDPolicy $monitoringConfig
}else{Microsoft.PowerShell.Utility\Write-Host 'Conditions and limits below come from the installed watchdog. Add -ShowTechnicalDetails for raw policy values and source expressions.'}
# Discover source calls outside function definitions; execute known call shapes only.
$calls=@($sourceAst.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst]},$true) | Where-Object {
    $parent=$_.Parent;$inFunction=$false
    while($parent){if($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]){$inFunction=$true;break};$parent=$parent.Parent}
    -not $inFunction -and $_.GetCommandName() -in $functionNames -and $_.GetCommandName() -match '^(Test[-A-Z]|Check[-A-Z]|Monitor[-A-Z]|Validate[-A-Z]|EnsureService|Invoke-DailyServiceRestart)'
} | Sort-Object {$_.Extent.StartOffset})
$seen=@{}
foreach($call in $calls){
    $name=$call.GetCommandName()
    $definition=$functions | Where-Object Name -eq $name | Select-Object -First 1
    $rules=@($definition.Body.FindAll({param($n)$n -is [System.Management.Automation.Language.IfStatementAst]},$true) | ForEach-Object {$_.Clauses | ForEach-Object {$_.Item1.Extent.Text}})
    if($name -eq 'Test-APIEndpoint'){
        if($seen[$name]){continue};$seen[$name]=$true
        Show-UDSection $name {
            $raw=Invoke-SqlScalar -Query $monitoringConfig.SqlQueries.ApiEndpoint -Parameters @{}
            if(-not $raw){throw 'No API base endpoint returned.'}
            $base=Get-NormalizedApiBaseEndpoint -ApiEndpoint $raw -Protocol $apiProtocol
            $all=$true
            foreach($endpoint in $monitoringConfig.ApiEndpoints){if(-not (Test-APIEndpoint -State $State -ApiEndpoint $base -Endpoint $endpoint)){$all=$false}}
            if($all -and $monitoringConfig.ApiEndpoints.Count -gt 0 -and $imported.ContainsKey('Reset-RestartPlan')){Reset-RestartPlan -State $State -MonitorKey 'api-endpoint'}
        } $rules
        continue
    }
    $arguments=@{};$issue=$null
    for($i=1;$i -lt $call.CommandElements.Count;$i++){
        $element=$call.CommandElements[$i]
        if($element -isnot [System.Management.Automation.Language.CommandParameterAst]){$issue='Unsupported positional or dynamic call arguments.';break}
        $parameter=$element.ParameterName
        if($element.Argument){$valueAst=$element.Argument}else{$i++;if($i -ge $call.CommandElements.Count){$issue='Unsupported switch argument.';break};$valueAst=$call.CommandElements[$i]}
        $expression=$valueAst.Extent.Text
        if($expression -eq '$State'){$arguments[$parameter]=$State}
        elseif($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst]){$arguments[$parameter]=$valueAst.Value}
        elseif($expression -match '^\$monitoringConfig(?:\.[A-Za-z_][A-Za-z0-9_]*)+$'){
            $value=$monitoringConfig;foreach($part in ($expression -split '\.' | Select-Object -Skip 1)){$value=$value[$part]};$arguments[$parameter]=$value
        }else{$issue="Unsupported call expression: $expression";break}
    }
    $label="$name $(if($arguments.ServiceName){'['+$arguments.ServiceName+']'})".Trim()
    Show-UDSection $label {
        if($issue){throw $issue}
        if($configurationProblems.Count){throw 'Source configuration could not be evaluated completely; inspect unsupported configuration above.'}
        $guard=Get-UDCallGuard $call
        if(-not $guard.Allowed){Add-UDMessage 'SKIPPED' $guard.Reason;return}
        & $name @arguments
        if($name -eq 'Test-WorkflowLog' -and $monitoringConfig.SqlQueries.WorkflowLogLastDate -match '^\s*SELECT\s+GETDATE\(\)\s*;?\s*$'){
            Add-UDMessage 'Placeholder query' 'The source checks SQL clock time, not workflow activity.'
        }
    } $rules
}
$topActions=@($sourceAst.FindAll({param($n)$n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Restart-Service|Start-Service|Stop-Service|sc.exe|net.exe)$'},$true) | Where-Object {
    $p=$_.Parent;$inside=$false;while($p){if($p -is [System.Management.Automation.Language.FunctionDefinitionAst]){$inside=$true;break};$p=$p.Parent};-not $inside
})
$handledInline=@{}
if(-not $calls.Count -and $topActions.Count){
    foreach($statement in $sourceAst.EndBlock.Statements){
        if($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]){continue}
        $actions=@($topActions | Where-Object {$_.Extent.StartOffset -ge $statement.Extent.StartOffset -and $_.Extent.EndOffset -le $statement.Extent.EndOffset})
        if(-not $actions.Count){continue}
        foreach($action in $actions){$handledInline[$action.Extent.StartOffset]=$true}
        Show-UDSection "Legacy inline scan (line $($statement.Extent.StartLineNumber))" {
            $issue=Get-UDAuditIssue $statement $functionNames
            if($issue){throw "Unsupported inline scan: $issue"}
            # Replay only audited, preceding scalar/read assignments needed by old
            # procedural versions. The original script entry point never runs.
            $preamble=New-Object 'System.Collections.Generic.List[string]'
            foreach($prior in $sourceAst.EndBlock.Statements){
                if($prior.Extent.StartOffset -ge $statement.Extent.StartOffset){break}
                if($prior -isnot [System.Management.Automation.Language.AssignmentStatementAst]){continue}
                $variableName=$prior.Left.Extent.Text.TrimStart('$')
                if($variableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or $variableName -match '(?i)^(json|State|monitoringConfig|decryptedPassword|configFile|localConfigFile|UD|PS|ExecutionContext|ErrorActionPreference)'){continue}
                if(-not (Get-UDAuditIssue $prior $functionNames)){$preamble.Add($prior.Extent.Text)}
            }
            $body='function Invoke-LegacyScan { '+($preamble -join "`n")+"`n"+$statement.Extent.Text+"`n}"
            $tmpTokens=$null;$tmpErrors=$null
            $tmpAst=[System.Management.Automation.Language.Parser]::ParseInput($body,[ref]$tmpTokens,[ref]$tmpErrors)
            if($tmpErrors.Count){throw 'Unable to instrument legacy scan.'}
            $legacy=$tmpAst.EndBlock.Statements[0]
            . ([scriptblock]::Create((Get-UDInstrumentedFunction $legacy -Trace)))
            Invoke-LegacyScan
        } @($statement.FindAll({param($n)$n -is [System.Management.Automation.Language.IfStatementAst]},$true) | ForEach-Object {$_.Clauses | ForEach-Object {$_.Item1.Extent.Text}})
    }
}
foreach($action in $topActions){if(-not $handledInline.ContainsKey($action.Extent.StartOffset)){Show-UDSection 'Unsupported inline service logic' {throw "Inline action at source line $($action.Extent.StartLineNumber): $($action.Extent.Text). This mixed version needs an adapter."} @()}}
if(-not $calls.Count -and -not $topActions.Count){
    Show-UDSection 'Source compatibility' {throw 'No supported scan calls or inline service checks discovered. This format requires an adapter; it was not executed.'} @()
}
Microsoft.PowerShell.Utility\Write-Host "`n===================== SUMMARY =====================" -ForegroundColor Cyan
foreach($row in $script:UDSummary){
    $caption=if($ShowTechnicalDetails){$row.Check}else{Get-UDCheckCaption $row.Check}
    Microsoft.PowerShell.Utility\Write-Host "$caption`: $($row.Decision)" -ForegroundColor $row.Color
}
Microsoft.PowerShell.Utility\Write-Host 'Predicted attempts update only in-memory history. Actual restart success and subsequent health changes cannot be predicted.' -ForegroundColor Yellow
Microsoft.PowerShell.Utility\Write-Host 'Source check cooldowns are honored: skipped probes are UNKNOWN, not successful. No history is fabricated.'
