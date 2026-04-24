<#
    Find-AllianceAdminTasks.ps1
    Audits the local machine for Windows services and scheduled tasks
    configured to run as alliance0\administrator.

    Intended for Datto RMM component use. Run as SYSTEM or Administrator.
    Exit 0 = no findings. Exit 1 = findings present (device flagged in RMM).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$targetAccount = 'alliance0\administrator'

Write-Host "=== Alliance Admin Account Audit: $env:COMPUTERNAME ==="
Write-Host "Checking for services and tasks running as: $targetAccount"
Write-Host ""

# --- Services ---

Write-Host "---- Windows Services ----"
try {
    $services = @(
        Get-CimInstance Win32_Service |
            Where-Object { $_.StartName -and ($_.StartName -ieq $targetAccount) } |
            Select-Object Name, DisplayName, StartName, State, StartMode
    )
} catch {
    Write-Warning "Failed to query services: $($_.Exception.Message)"
    $services = @()
}

if ($services.Count -gt 0) {
    Write-Host ($services | Format-Table -AutoSize | Out-String)
} else {
    Write-Host "No services found running as $targetAccount."
}

# --- Scheduled Tasks ---

Write-Host "---- Scheduled Tasks ----"
try {
    $tasks = @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object { $_.Principal.UserId -and ($_.Principal.UserId -ieq $targetAccount) } |
            Select-Object TaskPath, TaskName,
                @{N='RunAs'; E={$_.Principal.UserId}},
                State
    )
} catch {
    Write-Warning "Failed to query scheduled tasks: $($_.Exception.Message)"
    $tasks = @()
}

if ($tasks.Count -gt 0) {
    Write-Host ($tasks | Format-Table -AutoSize | Out-String)
} else {
    Write-Host "No scheduled tasks found running as $targetAccount."
}

# --- Summary ---

Write-Host ""
Write-Host "FINDINGS: $($services.Count) service(s), $($tasks.Count) task(s) run as $targetAccount"

if ($services.Count -gt 0 -or $tasks.Count -gt 0) {
    exit 1
}

exit 0
