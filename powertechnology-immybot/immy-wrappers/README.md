# PTI Immy Wrappers

These are the scripts intended to be pasted into Immy tasks or software action scripts. They assume you created a `File` parameter named `PTIPayloadZip`. At runtime the wrappers look for Immy's extracted-folder companion variable `PTIPayloadZipFolder` and, during local testing, can also accept either an extracted folder path or the zip file path itself.

The combined task wrappers also accept common Immy maintenance-task variables such as `TenantName`, `TenantSlug`, `ComputerName`, and `ComputerSlug`, and they include a hidden catch-all parameter for additional Immy runtime arguments so they do not fail when Immy injects extra context values at runtime.

All wrappers should run in the `System` execution context because they target the endpoint directly.

The one exception is `pti-install-lexmark-allprinters-package-wrapper.ps1`, which is a standalone combined task wrapper for a generated Lexmark package and therefore expects a `File` parameter named `LexmarkPackageZip` instead of `PTIPayloadZip`.

## Files

- `pti-workstation-baseline-wrapper.ps1`
- `pti-install-printers-wrapper.ps1`
- `pti-install-lexmark-allprinters-package-wrapper.ps1`
- `pti-install-office2007-standard-wrapper.ps1`
- `pti-install-office2007-professional-wrapper.ps1`
- `pti-collect-dell-diagnostics-wrapper.ps1`
- `pti-collect-printer-driver-diagnostics-wrapper.ps1`

`pti-collect-dell-diagnostics-wrapper.ps1` is a thin task wrapper you can run on a problem endpoint to export Dell uninstall metadata, services, processes, AppX packages, and relevant baseline log lines to `C:\ProgramData\PTI\Diagnostics\Dell`.
- `pti-collect-printer-driver-diagnostics-wrapper.ps1` is a thin task wrapper you can run on a test endpoint to inventory the PTI printer-driver share, local printer queues, local printer drivers, and likely INF candidates to `C:\ProgramData\PTI\Diagnostics\Printers`.
- `pti-install-sonicwall-vpn-wrapper.ps1`

`pti-install-lexmark-allprinters-package-wrapper.ps1` is a standalone combined task wrapper for a generated Lexmark package bundle. Upload a zip of the full generated package folder so the archive contains `LexmarkPkgInstaller.exe`, `InstallationPackage.zip`, and `PackageSummary.html` together.
`pti-install-office2007-standard-wrapper.ps1` and `pti-install-office2007-professional-wrapper.ps1` are combined task wrappers. They return `True` or `False` during `Test` by checking for the expected Office 12 executables and they call the payload installer during `Set`.

## Usage

1. Build the payload zip with `..\build-pti-immy-payload.ps1`.
2. Add a `File` parameter named `PTIPayloadZip` to the Immy task or configuration task.
3. Upload the generated zip to that file parameter.
4. For baseline, printers, Lexmark package deployment, and Office 2007, select `Use combined script` and paste the relevant wrapper script into the combined editor.
5. For the remaining software wrappers, paste the wrapper into the appropriate software action script.
6. Add the remaining business parameters to the task and map them to customer variables as needed.
