# Bicep: DF Remote on Azure Container Instances with Azure File Share

## Prereqs
- Azure CLI logged in: `az login`
- A resource group exists (or create one): `az group create -n <rg> -l <region>`
- Bicep installed (bundled with latest `az`)

## Deploy
1. Pick a globally-unique storage account name (lowercase letters & numbers, 3-24 chars).
2. Edit `parameters.example.json` and set `"storageAccountName": {"value": "YOURUNIQUESTNAME"}`.
3. Deploy:
```bash
az deployment group create -g <rg>   --template-file main.bicep   --parameters @parameters.example.json
```
4. Outputs will show:
   - `publicIP` of the ACI
   - `fileShareUNC` to access saves

## Notes
- Default mount path is `/df/data/save` which matches classic DF save location for DF Remote.
- To change region, use the resource group's location or pass `-p location=<azure-region>`.
