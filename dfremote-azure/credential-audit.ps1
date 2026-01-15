<#
Alliance Rubber - Credential Audit
Finds:
  - Services running under specific user accounts
  - Scheduled tasks configured to run as specific user accounts

Designed for Datto RMM deployment:
  - Writes CSVs to ProgramData
  - Prints summary to StdOut
#>

[CmdletBinding()]
param(
    # Account names to search for (case-insensitive). You can add/remove as needed.
    [string[]]$TargetAccounts = @("Administrator", "allservice", "sonicwall_service"),

    # Output folder (Datto-safe location)
    [string]$OutputRoot = "$env:ProgramData\DattoRMM\AllianceCredentialAudit"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Folder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
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
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
Ensure-Folder -Path $OutputRoot

$accountRegex = New-RegexForAccounts -Accounts $TargetAccounts

$svcOut = Join-Path $OutputRoot "Services_CredentialAudit_$timestamp.csv"
$taskOut = Join-Path $OutputRoot "ScheduledTasks_CredentialAudit_$timestamp.csv"
$metaOut = Join-Path $OutputRoot "AuditMeta_$timestamp.json"

# --- Services ---
$servicesAll = Get-CimInstance Win32_Service | ForEach-Object {
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

$servicesMatched = $servicesAll | Where-Object {
    $sn = $_.StartName
    if ([string]::IsNullOrWhiteSpace($sn)) { return $false }
    Matches-TargetAccount -User $sn -AccountRegex $accountRegex -Accounts $TargetAccounts
}

$servicesMatched | Sort-Object StartName, Name | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $svcOut

# --- Scheduled Tasks (schtasks for broad compatibility) ---
# schtasks /query /v /fo csv returns localized column names on non-English systems,
# but Alliance endpoints are almost certainly English. If not, we still attempt best-effort parsing.

$rawCsv = & schtasks.exe /query /v /fo csv 2>$null
if (-not $rawCsv -or $rawCsv.Count -lt 2) {
    # If schtasks is blocked or fails, fallback to Get-ScheduledTask
    $tasksAll = @()
    try {
        $tasksAll = Get-ScheduledTask | ForEach-Object {
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
    } catch {
        $tasksAll = @()
    }
} else {
    $parsed = $rawCsv | ConvertFrom-Csv

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
    ServicesFound     = ($servicesMatched | Measure-Object).Count
    TasksFound        = ($tasksMatched | Measure-Object).Count
    ServicesCsv       = $svcOut
    TasksCsv          = $taskOut
}

$meta | ConvertTo-Json -Depth 4 | Out-File -FilePath $metaOut -Encoding UTF8

# Print useful StdOut for Datto component output
Write-Host "Alliance Credential Audit - $($env:COMPUTERNAME)"
Write-Host "Targets: $($TargetAccounts -join ', ')"
Write-Host "Output Folder: $OutputRoot"
Write-Host "Services matched: $($meta.ServicesFound)"
Write-Host "Tasks matched:    $($meta.TasksFound)"
Write-Host "Services CSV:     $svcOut"
Write-Host "Tasks CSV:        $taskOut"
Write-Host "Meta JSON:        $metaOut"

if ($meta.ServicesFound -gt 0) {
    Write-Host "`nTop Services (first 10):"
    $servicesMatched | Select-Object -First 10 Name, DisplayName, StartName, State, StartMode |
        Format-Table -AutoSize | Out-String | Write-Host
}

if ($meta.TasksFound -gt 0) {
    Write-Host "`nTop Scheduled Tasks (first 10):"
    $tasksMatched | Select-Object -First 10 TaskPath, TaskName, RunAsUser, State, NextRunTime |
        Format-Table -AutoSize | Out-String | Write-Host
}

# Exit code: 0 = success. (Don’t fail the job just because findings exist.)
exit 0
