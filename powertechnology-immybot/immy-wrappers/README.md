# PTI Immy Wrappers

These are the thin scripts intended to be pasted into Immy tasks or software action scripts. They assume you created a `File` parameter named `PTIPayloadZip`. Per Immy's scripting guide, uploading a zip file also creates the extracted folder variable `PTIPayloadZipFolder`.

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
4. Paste the relevant wrapper script into the Immy script editor.
5. Add the remaining business parameters to the task and map them to customer variables as needed.
