# Terraform: DF Remote on Azure Container Instances with Azure File Share

## Prereqs
- Terraform >= 1.6
- Azure CLI logged in (`az login`)
- `az account set -s <subscription-id>` to ensure correct subscription

## Deploy
```bash
cd terraform
terraform init
terraform apply -auto-approve   -var 'prefix=dfremote'   -var 'location=eastus'   -var 'resource_group_name=dfremote-rg'   -var 'mount_path=/df/data/save'   -var 'udp_port=1235'
```
When complete, Terraform outputs:
- `public_ip` of the ACI
- `file_share_unc` where saves are stored

## Notes
- The storage account name is auto-generated and globally unique.
- Adjust `quota` for the file share in `main.tf` if you expect large worlds.
- If you later change the image tag, just `terraform apply` again—your saves persist.
