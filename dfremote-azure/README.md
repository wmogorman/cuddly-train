# DF Remote on Azure (ACI + Azure Files)

This package contains ready-to-deploy **Bicep** and **Terraform** templates that run the `mifki/dfremote` container on **Azure Container Instances (ACI)** and persist saves to an **Azure File Share** mounted at `/df/data/save` (the classic Dwarf Fortress save folder).

## Contents
- `bicep/` → `main.bicep` + `parameters.example.json` + README
- `terraform/` → `main.tf` + README

## Quick Start (Terraform)
```bash
cd terraform
terraform init
terraform apply -auto-approve -var 'resource_group_name=dfremote-rg' -var 'location=eastus'
```
Grab the `public_ip` output and connect to DF Remote on UDP 1235.

## Quick Start (Bicep)
```bash
az group create -n dfremote-rg -l eastus
az deployment group create -g dfremote-rg   --template-file bicep/main.bicep   --parameters @bicep/parameters.example.json
```

## Change the mount path
If your container reveals a different save path, update:
- Terraform: `-var 'mount_path=/your/path'`
- Bicep: set `mountPath` parameter.
