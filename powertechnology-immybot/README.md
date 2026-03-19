# Power Technology ImmyBot Assets

This folder is now organized for an Immy-friendly `single zip payload + thin wrapper` workflow.

The real PTI runtime scripts stay here in source control. You build one zip payload from them, upload that zip to an Immy `File` parameter, and paste only the small wrapper scripts into Immy.

## Layout

- `pti-*.ps1`
  Runtime scripts that execute on the endpoint after the payload zip is extracted.
- `build-pti-immy-payload.ps1`
  Creates the uploadable payload zip with the expected structure for Immy.
- `immy-wrappers\*.ps1`
  Thin scripts intended for the Immy script editor.
- `immy-wrappers\README.md`
  Quick wrapper usage notes.

## Payload Structure

`build-pti-immy-payload.ps1` produces a zip with this shape:

```text
PTI-Immy-Payload.zip
|- payload\
|  |- pti-common.ps1
|  |- pti-workstation-baseline.ps1
|  |- pti-install-printers.ps1
|  |- pti-stage-and-install-package.ps1
|  |- pti-install-office2007-standard.ps1
|  |- pti-install-office2007-professional.ps1
|  |- pti-install-sonicwall-vpn.ps1
|  |- pti-remove-unapproved-security.ps1
|  |- pti-install-goldmine92.ps1
|  |- pti-install-misys64.ps1
|  |- pti-install-accpac61a.ps1
|  |- pti-install-crystal.ps1
|  |- pti-install-sql-odbc.ps1
|  |- pti-blocked-package.ps1
|- dell-cleanup.ps1
|- Remove-LegacyAV.ps1
```

That top-level helper placement is intentional. The PTI runtime scripts already resolve `..\dell-cleanup.ps1` and `..\Remove-LegacyAV.ps1` from inside `payload`.

## Build The Payload

Run:

```powershell
.\build-pti-immy-payload.ps1 -Force
```

Default output:

- `powertechnology-immybot\dist\PTI-Immy-Payload.zip`

## How To Use In Immy

Use `System` execution context for these wrappers. Do not use `Metascript` for the endpoint-local PTI tasks.

Per the Immy scripting guide, if a `File` parameter is named `PTIPayloadZip`, Immy also exposes the extracted folder path as `PTIPayloadZipFolder`. The wrapper scripts are now written so the task parameter only needs to be named `PTIPayloadZip`.

Recommended pattern:

1. Build the zip with `build-pti-immy-payload.ps1`.
2. In Immy, create or edit the task/software configuration task.
3. Add a `File` parameter named `PTIPayloadZip`.
4. Upload the built zip.
5. For baseline and printers, choose `Use combined script` and paste the matching script from `immy-wrappers`.
6. For software wrappers, paste the wrapper into the software action or configuration task script.
7. Add the business parameters needed by that wrapper.

## Wrapper Map

- `immy-wrappers\pti-workstation-baseline-wrapper.ps1`
  Combined `Test`/`Set` task script for debloat, OneDrive, Cortana, Dell cleanup, guarded AV cleanup, and Remote Assistance.
- `immy-wrappers\pti-install-printers-wrapper.ps1`
  Combined `Test`/`Set` task script for driver staging and queue creation.
- `immy-wrappers\pti-collect-dell-diagnostics-wrapper.ps1`
  Thin task wrapper for collecting uninstall metadata and runtime state when Dell cleanup does not converge.
- `immy-wrappers\pti-collect-printer-driver-diagnostics-wrapper.ps1`
  Thin task wrapper for inventorying the printer-driver share and local driver state when you need exact INF and driver-name values.
- `immy-wrappers\pti-install-office2007-standard-wrapper.ps1`
  Uses the payload Office 2007 Standard installer wrapper.
- `immy-wrappers\pti-install-office2007-professional-wrapper.ps1`
  Uses the payload Office 2007 Professional installer wrapper.
- `immy-wrappers\pti-install-sonicwall-vpn-wrapper.ps1`
  Uses the payload SonicWall VPN installer wrapper.

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
- `PTI_LexmarkCopierDriverSourcePath`
- `PTI_LexmarkCopierInfRelativePath`
- `PTI_LexmarkCopierInstallArguments`
- `PTI_LexmarkCopierDriverName`
- `PTI_LexmarkMonoDriverSourcePath`
- `PTI_LexmarkMonoInfRelativePath`
- `PTI_LexmarkMonoInstallArguments`
- `PTI_LexmarkMonoDriverName`
- `PTI_HpDriverSourcePath`
- `PTI_HpInfRelativePath`
- `PTI_HpInstallArguments`
- `PTI_HpDriverName`

`PTI_ApprovedSecurityProducts` is evaluated as a semicolon-delimited regex list. If a tenant uses multiple Datto products, use a broader value such as `Datto` or list each product explicitly, for example `Datto EDR;Datto AV`.

The PTI baseline is reboot-aware for Dell cleanup. If the only remaining verify findings are Dell products that commonly unregister after restart, the baseline writes a reboot marker during `Set`, and the combined wrapper treats that state as a reboot checkpoint instead of a hard verify failure until the next boot clears the marker.
- The printer task now supports separate Lexmark driver families for the `XS658de` copiers and the `MS810dn` printers. The older `PTI_LexmarkDriver*` variables are still accepted as a fallback but should be treated as legacy compatibility settings.
- Printer driver source paths may point to an extracted driver folder, a `.zip` package, a direct `.msi`, or a direct `.exe` installer package. If a `.zip` is supplied, the payload expands it into the PTI staging cache automatically. `*InfRelativePath` may point to an `.inf`, `.msi`, or `.exe` inside that folder/zip, and it may be left blank when the source path itself points directly to an `.msi` or `.exe`.
- `*InstallArguments` is required when the selected driver package is an `.exe` installer.
- `PTI_Office2007StandardSourcePath`
- `PTI_Office2007StandardInstallerRelativePath`
- `PTI_Office2007StandardInstallArguments`
- `PTI_Office2007ProfessionalSourcePath`
- `PTI_Office2007ProfessionalInstallerRelativePath`
- `PTI_Office2007ProfessionalInstallArguments`
- `PTI_SonicWallVpnSourcePath`
- `PTI_SonicWallVpnInstallerRelativePath`
- `PTI_SonicWallVpnInstallArguments`

## Recommended Immy Shape

Sequence Immy built-ins for domain join to `ad.powertechnology.com`, Adobe Reader, Chrome, and any reboot handling before the PTI baseline wrapper.

Suggested usage:

- `PTI Workstation Baseline`
  Task script: `immy-wrappers\pti-workstation-baseline-wrapper.ps1`
- `PTI Printer Driver Stage`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Printer - Shared Copiers`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Printer - Scheduling`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Printer - Sales`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Printer - Accounting`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Printer - HP5000`
  Task script: `immy-wrappers\pti-install-printers-wrapper.ps1`
- `PTI Collect Printer Driver Diagnostics`
  Task script: `immy-wrappers\pti-collect-printer-driver-diagnostics-wrapper.ps1`
- `PTI Office 2007 Standard`
  Software action or configuration task script: `immy-wrappers\pti-install-office2007-standard-wrapper.ps1`
- `PTI Office 2007 Professional`
  Software action or configuration task script: `immy-wrappers\pti-install-office2007-professional-wrapper.ps1`
- `PTI SonicWall VPN`
  Software action or configuration task script: `immy-wrappers\pti-install-sonicwall-vpn-wrapper.ps1`

## Blocked Packages

Do not deploy these until William's notes and validated install commands are available:

- GoldMine 9.2
- MISys 6.4
- ACCPAC 6.1A
- Crystal Runtime or Editor
- SQL ODBC drivers and DSN configuration

The placeholder payload scripts are intentional guard rails. If one of those packages runs now, it should fail with a clear message instead of making unsupported assumptions about silent install switches or post-install configuration.
