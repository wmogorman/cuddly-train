# PTI Immy Wrappers

These are the scripts intended to be pasted into Immy tasks or software action scripts. They assume you created a `File` parameter named `PTIPayloadZip`. At runtime the wrappers look for Immy's extracted-folder companion variable `PTIPayloadZipFolder` and, during local testing, can also accept either an extracted folder path or the zip file path itself.

The combined task wrappers also accept common Immy maintenance-task variables such as `TenantName`, `TenantSlug`, `ComputerName`, and `ComputerSlug`, and they include a hidden catch-all parameter for additional Immy runtime arguments so they do not fail when Immy injects extra context values at runtime.

All wrappers should run in the `System` execution context because they target the endpoint directly.

## Files

- `pti-workstation-baseline-wrapper.ps1`
- `pti-install-printers-wrapper.ps1`
- `pti-install-office2007-standard-wrapper.ps1`
- `pti-install-office2007-professional-wrapper.ps1`
- `pti-install-sonicwall-vpn-wrapper.ps1`

## Usage

1. Build the payload zip with `..\build-pti-immy-payload.ps1`.
2. Add a `File` parameter named `PTIPayloadZip` to the Immy task or configuration task.
3. Upload the generated zip to that file parameter.
4. For baseline and printers, select `Use combined script` and paste the relevant wrapper script into the combined editor.
5. For software wrappers, paste the wrapper into the appropriate software action script.
6. Add the remaining business parameters to the task and map them to customer variables as needed.
