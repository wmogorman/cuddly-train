<# 
    dell-cleanup.ps1
    Safe removal of Dell Optimizer, TechHub, SupportAssist, and related bloat.
#>

Write-Host "=== Killing Dell services / processes ==="

# Services commonly responsible for memory leaks
$badServiceNames = @(
    'Dell.TechHub.ServiceShell',
    'Dell.TechHub.ServiceShellHost',
    'DellOptimizer',
    'DellOptimizerService',
    'SupportAssistAgent',
    'Dell SupportAssist',
    'DellClientManagementService',
    'DellDataVault',
    'DellDataVaultSvcApi',
    'DellDataVaultWiz',
    'Dell SupportAssist Remediation',
    'DellTechHub',
    'DellTechHubUpdateService'
)

foreach ($svcName in $badServiceNames) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Stopping service: $svcName"
        try {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "Failed to stop/disable $svcName : $_"
        }
    }
}

# Kill processes
Write-Host "`n=== Killing Dell processes ==="

$badProcessNames = @(
    'ServiceShell',
    'DellOptimizer',
    'DellTechHub',
    'SupportAssistAgent',
    'DellSupportAssistRemediation',
    'DellDataVault',
    'DellDataVaultWiz',
    'DellDataVaultSvcApi'
)

foreach ($pName in $badProcessNames) {
    Get-Process -Name $pName -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Killing process: $($_.ProcessName) (PID $($_.Id))"
        $_ | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Uninstalling Dell applications ==="

# Dell things we allow to remain
$keepNames = @(
    'Dell Command | Configure',
    'Dell Command | Monitor',
    'Dell Command | Update',
    'Dell Command | PowerShell Provider'
)

# High-priority bloat to remove
$explicitRemoveNames = @(
    'Dell Optimizer',
    'Dell Optimizer Service',
    'Dell SupportAssist',
    'Dell SupportAssist OS Recovery',
    'Dell SupportAssist Remediation',
    'Dell Digital Delivery',
    'Dell Customer Connect',
    'Dell Update',
    'Dell Update for Windows',
    'My Dell',
    'Dell TechHub',
    'Dell Power Manager',
    'Alienware Command Center',
    'Alienware Update'
)

# Grab installed programs from registry
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$installed = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object PSChildName, DisplayName, Publisher, UninstallString

$dellApps = $installed | Where-Object {
    ($_.DisplayName -like '*Dell*' -or $_.Publisher -like '*Dell*' -or
     $explicitRemoveNames -contains $_.DisplayName) -and
    -not ($keepNames -contains $_.DisplayName)
}

if ($dellApps) {
    foreach ($app in $dellApps) {
        Write-Host "`n--- Uninstalling: $($app.DisplayName) ---"

        if (-not $app.UninstallString) {
            Write-Warning "No uninstall string found for $($app.DisplayName). Skipping."
            continue
        }

        $uninstallCmd = $app.UninstallString

        # Normalize MSI commands
        if ($uninstallCmd -match 'MsiExec\.exe') {
            $uninstallCmd = $uninstallCmd -replace '/I', '/X'
            if ($uninstallCmd -notmatch '/X') { $uninstallCmd += ' /X' }
            if ($uninstallCmd -notmatch '/qn') { $uninstallCmd += ' /qn /norestart' }
        }

        Write-Host "Running: $uninstallCmd"
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $uninstallCmd" -Wait -WindowStyle Hidden
        } catch {
            Write-Warning "Uninstall failed for $($app.DisplayName): $_"
        }
    }
} else {
    Write-Host "No Dell applications found to uninstall."
}

Write-Host "`n=== Removing Dell Store apps ==="

$appxPackages = Get-AppxPackage -AllUsers *dell* -ErrorAction SilentlyContinue

if ($appxPackages) {
    foreach ($pkg in $appxPackages) {
        Write-Host "Removing Appx: $($pkg.Name)"
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            Write-Warning "Failed to remove Appx package $($pkg.Name): $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "No Dell Appx packages found for any user."
}

# Remove provisioned Dell packages so they do not come back for new profiles
$provDell = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*Dell*' }
if ($provDell) {
    foreach ($prov in $provDell) {
        Write-Host "De-provisioning Appx: $($prov.DisplayName)"
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Failed to remove provisioned package $($prov.DisplayName): $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "No provisioned Dell Appx packages remain."
}

Write-Host "`nDell cleanup complete."
