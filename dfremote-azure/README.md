# DF Remote Helper Assets

This directory holds the provisioning scripts and DFHack assets that get staged
onto the DF Remote VM.

## Contents

| File | Purpose |
| --- | --- |
| `dfremote.ps1` | Provision the Azure VM and supporting resources. If the VM already exists, the script reuses it instead of failing. |
| `write-dfremote-password.ps1` | Generates the DPAPI-protected `dfremote-password.txt` on a workstation (current user scope). |
| `my-deploy-dfremote-vm.ps1` | Personal deployment shortcut that calls `dfremote.ps1` with local defaults. |
| `dreamfort_stages.lua` | DFHack script that orchestrates staged Dreamfort quickfort runs. Copy to `/opt/dfremote/hack/scripts/dreamfort_stages.lua`. |
| `tree.csv` | Optional quickfort helper blueprint for tree-clearing. Copy to `/opt/dfremote/hack/data/blueprints/tree.csv`. |
| `dfhack_lib.lua`, `dfhack.lua.ref` | Snapshot of DFHack Lua helpers for offline reference. |
| `fortress-workorders.json` | Saved work orders for DF Remote. |
| `grazer_autopen.lua`, `grazer_autopen_state.lua`, `list_blocked_practice.lua`, `rotate_training.lua` | DFHack automation scripts. Place in `/opt/dfremote/hack/scripts/`. |

## Copying To The VM

```bash
# Example commands from the repository root
scp dfremote-azure/dreamfort_stages.lua william@dfremote-vm:/opt/dfremote/hack/scripts/dreamfort_stages.lua
scp dfremote-azure/tree.csv william@dfremote-vm:/opt/dfremote/hack/data/blueprints/tree.csv
scp dfremote-azure/grazer_autopen.lua william@dfremote-vm:/opt/dfremote/hack/scripts/
scp dfremote-azure/grazer_autopen_state.lua william@dfremote-vm:/opt/dfremote/hack/scripts/

# Optional if you keep a local Dreamfort workbook outside this repo
scp path/to/dreamfort.csv william@dfremote-vm:/opt/dfremote/hack/data/blueprints/dreamfort.csv
```

`dreamfort_stages.lua` will use Quickfort's bundled `library/dreamfort.csv`
when available. Upload a standalone `dreamfort.csv` only if you want to
override that library copy on the VM.

Restart DFHack (or run `script reload`) after uploading scripts so the new
commands become available.
