<# 
    Disable-CEIP.ps1
    Disables the Windows Customer Experience Improvement Program (CEIP)
    by setting CEIP registry policy values and disabling CEIP-related
    scheduled tasks.

    Intended for Datto RMM scheduled use. Run as SYSTEM or Administrator.
#>

[CmdletBinding()]
param()

# region Admin check
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator (or Datto RMM SYSTEM). Re-run in an elevated context."
    exit 1
}
# endregion Admin check

$nonFatalIssues = New-Object System.Collections.Generic.List[string]

Write-Host "Disabling Windows Customer Experience Improvement Program (CEIP)..."


# region Registry: set CEIPEnable = 0 in relevant locations
# HKLM policy is authoritative; HKLM/SQM and HKCU paths are belt-and-suspenders.

$registryTargets = @(
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"; Name = "CEIPEnable"; Value = 0; Type = "DWord" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\SQMClient\Windows";          Name = "CEIPEnable"; Value = 0; Type = "DWord" },
    @{ Path = "HKCU:\SOFTWARE\Microsoft\SQMClient";                  Name = "CEIPEnable"; Value = 0; Type = "DWord" },
    @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"; Name = "CEIPEnable"; Value = 0; Type = "DWord" }
)

foreach ($target in $registryTargets) {
    try {
        if (-not (Test-Path -Path $target.Path)) {
            Write-Host "Creating registry key: $($target.Path)"
            New-Item -Path $target.Path -Force | Out-Null
        }

        Write-Host "Setting $($target.Name)=$($target.Value) at $($target.Path)"
        New-ItemProperty -Path $target.Path -Name $target.Name -Value $target.Value -PropertyType $target.Type -Force | Out-Null
    }
    catch {
        $msg = "Failed to set $($target.Name) at $($target.Path): $($_.Exception.Message)"
        Write-Warning $msg
        $nonFatalIssues.Add($msg) | Out-Null
    }
}
# endregion Registry


# region Scheduled Tasks: disable CEIP-related tasks (if present)

$ceipTasks = @(
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator"   },
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "KernelCeipTask" },
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip"        },
    @{ Path = "\Microsoft\Windows\Autochk\";                                 Name = "Proxy"          }  # Autochk CEIP proxy
)

foreach ($t in $ceipTasks) {
    try {
        $taskObj = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop
        if ($taskObj.State -ne "Disabled") {
            Write-Host "Disabling scheduled task: $($t.Path)$($t.Name)"
            Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
        }
        else {
            Write-Host "Task already disabled: $($t.Path)$($t.Name)"
        }
    }
    catch {
        # Many systems will not have every CEIP task; do not fail the job for absences.
        $msg = "Task not found or could not be queried: $($t.Path)$($t.Name) - $($_.Exception.Message)"
        Write-Host $msg
        $nonFatalIssues.Add($msg) | Out-Null
    }
}
# endregion Scheduled Tasks


Write-Host ""
Write-Host "CEIP disable routine completed."
if ($nonFatalIssues.Count -gt 0) {
    Write-Warning "Completed with non-fatal issues:"
    $nonFatalIssues | ForEach-Object { Write-Warning $_ }
} else {
    Write-Host "No issues detected."
}
Write-Host "A reboot is recommended for all changes to fully take effect."

exit 0
