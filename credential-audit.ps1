<#
Credential Audit
Finds:
  - Services running under specific user accounts
  - Scheduled tasks configured to run as specific user accounts

Designed for Datto RMM deployment:
  - Supports component variable TargetAccountsCsv or TargetAccounts (CSV/semicolon/newline)
  - Optional TargetDomain to qualify accounts (e.g., ALLIANCE0)
  - Writes CSVs to ProgramData
  - Prints summary to StdOut
#>

[CmdletBinding()]
param(
    # Optional CSV/semicolon/newline list of target accounts.
    # If set, overrides TargetAccounts. Useful for Datto RMM component variables.
    [string]$TargetAccountsCsv = $null,

    # Optional domain to qualify unqualified accounts (e.g., ALLIANCE0).
    # If set, "administrator" becomes "ALLIANCE0\administrator".
    [string]$TargetDomain = $null,

    # Account names to search for (case-insensitive). Used when TargetAccountsCsv is empty.
    [string[]]$TargetAccounts = @("Administrator"),

    # Output folder (Datto-safe location)
    [string]$OutputRoot = "$env:ProgramData\DattoRMM\CredentialAudit"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Folder {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        throw "OutputRoot path points to a file: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Add-Error {
    param([Parameter(Mandatory)][string]$Message)
    $script:Errors += $Message
}

function New-RegexForAccounts {
    param([Parameter(Mandatory)][string[]]$Accounts)

    # Match:
    #  - exact username (Administrator)
    #  - .\Administrator
    #  - COMPUTERNAME\Administrator
    #  - DOMAIN\Administrator
    #  - case-insensitive
    $escaped = $Accounts | ForEach-Object { [Regex]::Escape($_) }
    $pat = "(?i)(^|\\|\.\\)("+ ($escaped -join "|") +")$"
    return [regex]$pat
}

function Normalize-RunAsUser {
    param([string]$RunAsUser)
    if ([string]::IsNullOrWhiteSpace($RunAsUser)) { return $null }
    return $RunAsUser.Trim()
}

function Matches-TargetAccount {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][regex]$AccountRegex,
        [Parameter(Mandatory)][string[]]$Accounts
    )

    $u = $User.Trim()

    # Common non-user identities to ignore
    if ($u -match '^(?i)(NT AUTHORITY\\SYSTEM|SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$') { return $false }
    if ($u -match '^(?i)S-1-5-') { return $false } # SID

    # If it ends with one of the target usernames, treat as match.
    # Example: DOMAIN\allservice -> matches.
    foreach ($a in $Accounts) {
        if ($u -match "(?i)(\\|\.\\)"+[Regex]::Escape($a)+"$") { return $true }
        if ($u -match "(?i)^"+[Regex]::Escape($a)+"$") { return $true }
    }

    # Fallback exact-regex check
    return $AccountRegex.IsMatch($u)
}

# ---- Main ----
$Errors = @()

$targetAccountsCsvCandidate = $null
if ($PSBoundParameters.ContainsKey("TargetAccountsCsv")) {
    $targetAccountsCsvCandidate = $TargetAccountsCsv
} elseif (-not [string]::IsNullOrWhiteSpace($env:TargetAccountsCsv)) {
    $targetAccountsCsvCandidate = $env:TargetAccountsCsv
} elseif (-not [string]::IsNullOrWhiteSpace($env:TargetAccounts)) {
    $targetAccountsCsvCandidate = $env:TargetAccounts
}

if (-not [string]::IsNullOrWhiteSpace($targetAccountsCsvCandidate)) {
    $TargetAccounts = $targetAccountsCsvCandidate -split '[,;\r\n]+' | ForEach-Object { $_.Trim() }
}

$targetDomainCandidate = $null
if ($PSBoundParameters.ContainsKey("TargetDomain")) {
    $targetDomainCandidate = $TargetDomain
} elseif (-not [string]::IsNullOrWhiteSpace($env:TargetDomain)) {
    $targetDomainCandidate = $env:TargetDomain
}

if (-not [string]::IsNullOrWhiteSpace($targetDomainCandidate)) {
    $TargetDomain = $targetDomainCandidate.Trim().TrimEnd("\")
} else {
    $TargetDomain = $null
}

$TargetAccounts = $TargetAccounts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($TargetDomain) {
    $TargetAccounts = $TargetAccounts | ForEach-Object {
        $a = $_.Trim()
        if ($a -match '\\') { return $a }
        return "$TargetDomain\$a"
    }
}

if (-not $TargetAccounts -or $TargetAccounts.Count -eq 0) {
    Write-Output "No target accounts configured. Exiting."
    exit 0
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
Ensure-Folder -Path $OutputRoot

$accountRegex = New-RegexForAccounts -Accounts $TargetAccounts

$svcOut = Join-Path $OutputRoot "Services_CredentialAudit_$timestamp.csv"
$taskOut = Join-Path $OutputRoot "ScheduledTasks_CredentialAudit_$timestamp.csv"
$metaOut = Join-Path $OutputRoot "AuditMeta_$timestamp.json"

# --- Services ---
$servicesAll = @()
$servicesMatched = @()
$serviceQueryOk = $false
try {
    $servicesAll = Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Type        = "Service"
            Name        = $_.Name
            DisplayName = $_.DisplayName
            StartName   = $_.StartName
            State       = $_.State
            StartMode   = $_.StartMode
            PathName    = $_.PathName
        }
    }
    $serviceQueryOk = $true
} catch {
    try {
        $servicesAll = Get-WmiObject Win32_Service -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                Type        = "Service"
                Name        = $_.Name
                DisplayName = $_.DisplayName
                StartName   = $_.StartName
                State       = $_.State
                StartMode   = $_.StartMode
                PathName    = $_.PathName
            }
        }
        $serviceQueryOk = $true
    } catch {
        Add-Error ("Services query failed: " + $_.Exception.Message)
        $servicesAll = @()
    }
}

$servicesMatched = $servicesAll | Where-Object {
    $sn = $_.StartName
    if ([string]::IsNullOrWhiteSpace($sn)) { return $false }
    Matches-TargetAccount -User $sn -AccountRegex $accountRegex -Accounts $TargetAccounts
}

$servicesMatched | Sort-Object StartName, Name | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $svcOut

# --- Scheduled Tasks (schtasks for broad compatibility) ---
# schtasks /query /v /fo csv returns localized column names on non-English systems.
# We still attempt best-effort parsing.

$tasksAll = @()
$tasksMatched = @()
$taskQueryOk = $false
$rawCsv = & schtasks.exe /query /v /fo csv 2>$null
$parsed = $null
if ($rawCsv -and $rawCsv.Count -ge 2) {
    try {
        $parsed = $rawCsv | ConvertFrom-Csv
    } catch {
        $parsed = $null
    }
}

$useSchtasks = $false
if ($parsed -and $parsed.Count -gt 0) {
    $props = $parsed[0].PSObject.Properties.Name
    if ($props -contains "TaskName" -and $props -contains "Run As User") {
        $useSchtasks = $true
    }
}

if ($useSchtasks) {
    $taskQueryOk = $true

    # Common column names in English output:
    # "TaskName","Run As User","Task To Run","Author","Start In","Comment","Scheduled Task State",...
    # TaskName often includes the full path like \Microsoft\Windows\...
    $tasksAll = $parsed | ForEach-Object {
        $tn = $_."TaskName"
        $ru = $_."Run As User"

        # Split task name into path+name if possible
        $taskPath = "\"
        $taskName = $tn
        if ($tn -like "\*") {
            $lastSlash = $tn.LastIndexOf("\")
            if ($lastSlash -gt 0) {
                $taskPath = $tn.Substring(0, $lastSlash + 1)
                $taskName = $tn.Substring($lastSlash + 1)
            }
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Type         = "ScheduledTask"
            TaskName     = $taskName
            TaskPath     = $taskPath
            RunAsUser    = (Normalize-RunAsUser $ru)
            TaskToRun    = $_."Task To Run"
            Author       = $_."Author"
            State        = $_."Scheduled Task State"
            LastRunTime  = $_."Last Run Time"
            NextRunTime  = $_."Next Run Time"
        }
    }
} else {
    # If schtasks is blocked or fails, fallback to Get-ScheduledTask
    try {
        $tasksAll = Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $p = $_.Principal
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                Type         = "ScheduledTask"
                TaskName     = $_.TaskName
                TaskPath     = $_.TaskPath
                RunAsUser    = $p.UserId
                LogonType    = $p.LogonType
                Author       = $_.Author
                Description  = $_.Description
            }
        }
        $taskQueryOk = $true
    } catch {
        Add-Error ("Scheduled tasks query failed: " + $_.Exception.Message)
        $tasksAll = @()
    }
}

$tasksMatched = $tasksAll | Where-Object {
    $ru = $_.RunAsUser
    if ([string]::IsNullOrWhiteSpace($ru)) { return $false }
    Matches-TargetAccount -User $ru -AccountRegex $accountRegex -Accounts $TargetAccounts
}

$tasksMatched | Sort-Object RunAsUser, TaskPath, TaskName | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $taskOut

# --- Metadata / Summary ---
$meta = [pscustomobject]@{
    ComputerName      = $env:COMPUTERNAME
    Timestamp         = (Get-Date).ToString("o")
    TargetAccounts    = $TargetAccounts
    TargetDomain      = $TargetDomain
    ServicesFound     = ($servicesMatched | Measure-Object).Count
    TasksFound        = ($tasksMatched | Measure-Object).Count
    ServiceQueryOk    = $serviceQueryOk
    TaskQueryOk       = $taskQueryOk
    ServicesCsv       = $svcOut
    TasksCsv          = $taskOut
    Errors            = $Errors
}

$meta | ConvertTo-Json -Depth 4 | Out-File -FilePath $metaOut -Encoding UTF8

# Print useful StdOut for Datto component output
Write-Output "Credential Audit - $($env:COMPUTERNAME)"
Write-Output "Targets: $($TargetAccounts -join ', ')"
if ($TargetDomain) {
    Write-Output "Target Domain: $TargetDomain"
}
Write-Output "Output Folder: $OutputRoot"
Write-Output "Services matched: $($meta.ServicesFound)"
Write-Output "Tasks matched:    $($meta.TasksFound)"
Write-Output "Services CSV:     $svcOut"
Write-Output "Tasks CSV:        $taskOut"
Write-Output "Meta JSON:        $metaOut"
if ($Errors.Count -gt 0) {
    Write-Output "Warnings:"
    $Errors | ForEach-Object { Write-Output ("- " + $_) }
}

if ($meta.ServicesFound -gt 0) {
    Write-Output "`nTop Services (first 10):"
    $servicesMatched | Select-Object -First 10 Name, DisplayName, StartName, State, StartMode |
        Format-Table -AutoSize | Out-String | Write-Output
}

if ($meta.TasksFound -gt 0) {
    Write-Output "`nTop Scheduled Tasks (first 10):"
    $tasksMatched | Select-Object -First 10 TaskPath, TaskName, RunAsUser, State, NextRunTime |
        Format-Table -AutoSize | Out-String | Write-Output
}

# Exit code: 0 = success. (Don't fail the job just because findings exist.)
if (-not $serviceQueryOk -and -not $taskQueryOk) {
    exit 1
}
exit 0
