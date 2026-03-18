# Power Technology ImmyBot Assets

This folder contains the customer-specific PowerShell assets for the Power Technology onboarding plan. It is structured around one workstation baseline, one shared printer script, one generic staged-installer wrapper, and explicit placeholders for blocked legacy packages.

## Files

- `pti-workstation-baseline.ps1`: debloat, OneDrive removal, Cortana disablement, Dell cleanup hook, optional security cleanup hook, and Remote Assistance enablement.
- `pti-install-printers.ps1`: stages printer drivers from UNC, imports them, and creates the required TCP/IP queues.
- `pti-stage-and-install-package.ps1`: copies a package from UNC to local cache and runs a validated installer command.
- `pti-remove-unapproved-security.ps1`: wraps `..\Remove-LegacyAV.ps1` and only removes products that do not match the approved allowlist.
- `pti-install-office2007-standard.ps1`, `pti-install-office2007-professional.ps1`, `pti-install-sonicwall-vpn.ps1`: thin wrappers over the staged-installer helper.
- `pti-install-goldmine92.ps1`, `pti-install-misys64.ps1`, `pti-install-accpac61a.ps1`, `pti-install-crystal.ps1`, `pti-install-sql-odbc.ps1`: blocked placeholders that should fail fast until William's missing notes arrive.

## Immy Fields And Variables

Create one customer device field:

- `PTI_PrimaryDepartment`: `Sales`, `Marketing`, `Scheduling`, `Production`, `Procurement`, `Quality`, `Engineering`, `Accounting`, `Management`

Create the customer exception flags:

- `PTI_NeedsAccess`
- `PTI_NeedsAccountingPrinter`
- `PTI_NeedsHp5000`
- `PTI_NeedsGoldMine`
- `PTI_NeedsMISys`
- `PTI_NeedsACCPAC`
- `PTI_NeedsCrystal`
- `PTI_NeedsSqlOdbc`
- `PTI_NeedsSonicWallVpn`

Recommended secure Immy variables:

- `PTI_ShareUserName`
- `PTI_SharePassword`
- `PTI_ApprovedSecurityProducts`
- `PTI_LexmarkDriverSourcePath`
- `PTI_LexmarkInfRelativePath`
- `PTI_LexmarkDriverName`
- `PTI_HpDriverSourcePath`
- `PTI_HpInfRelativePath`
- `PTI_HpDriverName`
- `PTI_Office2007StandardSourcePath`
- `PTI_Office2007StandardInstallerRelativePath`
- `PTI_Office2007StandardInstallArguments`
- `PTI_Office2007ProfessionalSourcePath`
- `PTI_Office2007ProfessionalInstallerRelativePath`
- `PTI_Office2007ProfessionalInstallArguments`
- `PTI_SonicWallVpnSourcePath`
- `PTI_SonicWallVpnInstallerRelativePath`
- `PTI_SonicWallVpnInstallArguments`

## Package Map

Sequence the built-in Immy packages for domain join to `ad.powertechnology.com`, Adobe Reader, Chrome, and any reboot handling before the custom PTI scripts below.

`PTI Workstation Baseline`

```powershell
.\pti-workstation-baseline.ps1 `
  -ApprovedSecurityProducts $env:PTI_ApprovedSecurityProducts.Split(';') `
  -EnableUnauthorizedSecurityRemoval
```

Upload `..\dell-cleanup.ps1` and `..\Remove-LegacyAV.ps1` with this package, or keep the package contents arranged so those relative paths still exist.

`PTI Printer Driver Stage`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet DriverStage `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -HpDriverSourcePath $env:PTI_HpDriverSourcePath `
  -HpInfRelativePath $env:PTI_HpInfRelativePath `
  -HpDriverName $env:PTI_HpDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Printer - Shared Copiers`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet SharedCopiers `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Printer - Scheduling`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet Scheduling `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Printer - Sales`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet Sales `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Printer - Accounting`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet Accounting `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Printer - HP5000`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet Hp5000 `
  -HpDriverSourcePath $env:PTI_HpDriverSourcePath `
  -HpInfRelativePath $env:PTI_HpInfRelativePath `
  -HpDriverName $env:PTI_HpDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Department Printer Bundle`

```powershell
.\pti-install-printers.ps1 `
  -InstallSet DepartmentBundle `
  -PrimaryDepartment $env:PTI_PrimaryDepartment `
  -NeedsAccountingPrinter:$([System.Convert]::ToBoolean($env:PTI_NeedsAccountingPrinter)) `
  -NeedsHp5000:$([System.Convert]::ToBoolean($env:PTI_NeedsHp5000)) `
  -LexmarkDriverSourcePath $env:PTI_LexmarkDriverSourcePath `
  -LexmarkInfRelativePath $env:PTI_LexmarkInfRelativePath `
  -LexmarkDriverName $env:PTI_LexmarkDriverName `
  -HpDriverSourcePath $env:PTI_HpDriverSourcePath `
  -HpInfRelativePath $env:PTI_HpInfRelativePath `
  -HpDriverName $env:PTI_HpDriverName `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Office 2007 Standard`

Target this where Office 2007 Standard is still required and no Access exception is needed.

```powershell
.\pti-install-office2007-standard.ps1 `
  -SourcePath $env:PTI_Office2007StandardSourcePath `
  -InstallerRelativePath $env:PTI_Office2007StandardInstallerRelativePath `
  -InstallArguments $env:PTI_Office2007StandardInstallArguments `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI Office 2007 Professional`

Target this for `Production` or any device with `PTI_NeedsAccess`.

```powershell
.\pti-install-office2007-professional.ps1 `
  -SourcePath $env:PTI_Office2007ProfessionalSourcePath `
  -InstallerRelativePath $env:PTI_Office2007ProfessionalInstallerRelativePath `
  -InstallArguments $env:PTI_Office2007ProfessionalInstallArguments `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

`PTI SonicWall VPN`

Target this for `Sales`, `Management`, or any device with `PTI_NeedsSonicWallVpn`.

```powershell
.\pti-install-sonicwall-vpn.ps1 `
  -SourcePath $env:PTI_SonicWallVpnSourcePath `
  -InstallerRelativePath $env:PTI_SonicWallVpnInstallerRelativePath `
  -InstallArguments $env:PTI_SonicWallVpnInstallArguments `
  -ShareUserName $env:PTI_ShareUserName `
  -SharePassword $env:PTI_SharePassword
```

## Blocked Packages

Do not deploy these until William's notes and validated install commands are available:

- GoldMine 9.2
- MISys 6.4
- ACCPAC 6.1A
- Crystal Runtime or Editor
- SQL ODBC drivers and DSN configuration

The placeholder scripts are intentional guard rails. If one of those packages runs now, it should fail with a clear message instead of making unsupported assumptions about silent install switches or post-install configuration.
