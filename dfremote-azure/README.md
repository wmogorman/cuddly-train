# DF Remote Helper Assets

This directory holds all of the tooling and reference material we stage before
copying to the DF Remote VM. The files were previously located in the repo root;
moving them here keeps the main PowerShell automation clean while keeping the
Dreamfort resources together.

## Contents

| File | Purpose |
| --- | --- |
| `dfremote.ps1` | Common PowerShell wrapper for provisioning the Azure VM. Run as `.\dfremote-azure\dfremote.ps1`. |
| `my-deploy-dfremote-vm.ps1` | Personal deployment shortcut that imports `dfremote.ps1`. |
| `dreamfort_stages.lua` | DFHack script that orchestrates Dreamfort quickfort blueprints. Copy to `/opt/dfremote/hack/scripts/dreamfort-stages.lua`. |
| `dreamfort.csv` | Dreamfort blueprint workbook. Copy to `/opt/dfremote/hack/data/blueprints/dreamfort.csv`. |
| `tree.csv` | Quickfort helper blueprint for tree-clearing (optional). Copy next to `dreamfort.csv` if needed. |
| `dfhack_lib.lua` | Snapshot of DFHack Lua helpers for offline reference. |
| `quickfort_doc.html` | Offline copy of the Quickfort documentation. |
| `fortress-workorders.json` | Saved work orders for DF Remote. |
| `grazer_autopen.lua`, `list_blocked_practice.lua`, `rotate_training.lua` | DFHack automation scripts. Place in `/opt/dfremote/hack/scripts/`. |

## Copying To The VM

```bash
# Example commands from the repository root
scp dfremote-azure/dreamfort_stages.lua william@dfremote-vm:/opt/dfremote/hack/scripts/dreamfort-stages.lua
scp dfremote-azure/dreamfort.csv william@dfremote-vm:/opt/dfremote/hack/data/blueprints/dreamfort.csv
scp dfremote-azure/tree.csv william@dfremote-vm:/opt/dfremote/hack/data/blueprints/tree.csv
```

Restart DFHack (or run `script reload`) after uploading scripts so the new
commands become available.
