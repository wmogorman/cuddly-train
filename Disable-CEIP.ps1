<# 
    Disable-CEIP.ps1
    Disables the Windows Customer Experience Improvement Program (CEIP)
    by setting CEIP registry policy values and disabling CEIP-related
    scheduled tasks.

    Run this script as Administrator.
#>

# region Admin check
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Please re-run in an elevated PowerShell session."
    exit 1
}
# endregion Admin check


Write-Host "Disabling Windows Customer Experience Improvement Program (CEIP)..."


# region Registry: set CEIPEnable = 0 in relevant locations
# HKLM policy path is the main control; others are belt-and-suspenders.

$registryPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows",
    "HKCU:\SOFTWARE\Microsoft\SQMClient",
    "HKCU:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"
)

foreach ($path in $registryPaths) {
    try {
        if (-not (Test-Path -Path $path)) {
            Write-Host "Creating registry key: $path"
            New-Item -Path $path -Force | Out-Null
        }

        Write-Host "Setting CEIPEnable=0 at $path"
        New-ItemProperty -Path $path -Name "CEIPEnable" -Value 0 -PropertyType DWord -Force | Out-Null
    }
    catch {
        Write-Warning "Failed to set CEIPEnable at $path. Error: $($_.Exception.Message)"
    }
}
# endregion Registry


# region Scheduled Tasks: disable CEIP-related tasks (if present)

$ceipTasks = @(
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator"     },
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "KernelCeipTask"   },
    @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip"          },
    @{ Path = "\Microsoft\Windows\Autochk\";                                 Name = "Proxy"            }  # Autochk CEIP proxy
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
        # Many systems won’t have all of these tasks; that’s fine.
        Write-Host "Task not found or could not be queried: $($t.Path)$($t.Name) - $($_.Exception.Message)"
    }
}
# endregion Scheduled Tasks


Write-Host ""
Write-Host "CEIP has been disabled via registry policy and scheduled tasks where present."
Write-Host "A reboot is recommended for all changes to fully take effect."
