# Azure Automation Setup Guide for Global Admin Audit

This guide is for standing up the existing [`global-admin-audit.ps1`](C:/Users/wogorman.DATAMAX/cuddly-train/global-admin-audit.ps1) script in Azure Automation.

## What already exists

- Runbook script: [`global-admin-audit.ps1`](C:/Users/wogorman.DATAMAX/cuddly-train/global-admin-audit.ps1)
- App registration client ID already used by the script: `f45ddef0-f613-4c3d-92d1-6b80bf00e6cf`
- Certificate currently used by the script:
  - Subject: `CN=ActaMSP-GDAP-Automation`
  - Thumbprint: `D0278AED132F9C816A815A4BFFF0F48CE8FAECEF`
  - Found in: `Cert:\CurrentUser\My`
  - Expires: `2028-03-10`
- Default partner/discovery tenant ID found in the existing consent tracker summary: `9f50b569-9e79-47a5-bbe6-f362934d55a0`
- Default audit group name created and maintained by the script: `ActaMSP Global Administrators Audit`
- Required Microsoft Graph application permissions already expected by the onboarding verifier:
  - `Directory.Read.All`
  - `RoleManagement.Read.Directory`
  - `Group.ReadWrite.All`

## Important prereq before scheduling

The app is not fully onboarded in every target tenant yet. The current tracker shows these tenants still missing the enterprise app/service principal and will throw `AADSTS7000229` until they are onboarded or excluded:

- `Briarwood Animal Hospital` - `5295b796-b70b-40f7-a66c-e1ffc37fa7f4`
- `Pacific Coast Mgmt (ADC) (PP)` - `a60e43f7-7b19-4651-b0f9-25ec81306171`
- `Riverside Box Supply Co.` - `26815561-96af-449b-a666-3a5a97fb7018`
- `SJS and Company` - `43c4a3ab-b33e-426c-a351-7075d690934c`
- `SMA Architects` - `1abc61d2-bb21-4a54-8bbb-9481d3fd417e`

## What I need to hand my boss

Give him these items:

- The runbook file: [`global-admin-audit.ps1`](C:/Users/wogorman.DATAMAX/cuddly-train/global-admin-audit.ps1)
- The private-key certificate as a `.pfx` file for Azure Automation import
- The `.pfx` password
- The public certificate as a `.cer` file only if the app registration still needs the public cert uploaded or rotated
- Client ID: `f45ddef0-f613-4c3d-92d1-6b80bf00e6cf`
- Certificate thumbprint: `D0278AED132F9C816A815A4BFFF0F48CE8FAECEF`
- Discovery tenant ID: `9f50b569-9e79-47a5-bbe6-f362934d55a0`
- A note that five tenants are still not onboarded and will fail until fixed

If the `.pfx` and `.cer` files do not already exist, these are the export commands to run on the machine that currently has the cert:

```powershell
$thumb = 'D0278AED132F9C816A815A4BFFF0F48CE8FAECEF'
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $thumb

Export-Certificate -Cert $cert -FilePath .\ActaMSP-GDAP-Automation.cer

$pfxPassword = Read-Host 'Enter a password for the PFX file' -AsSecureString
Export-PfxCertificate -Cert $cert -FilePath .\ActaMSP-GDAP-Automation.pfx -Password $pfxPassword
```

If `Export-PfxCertificate` fails, the private key is not exportable and the certificate must be recreated.

## Azure portal build steps

### 1. Create the resource group

1. Sign in to `https://portal.azure.com`.
2. Open `Resource groups`.
3. Select `Create`.
4. Choose the subscription.
5. Create a resource group name.
   - Suggested: `rg-azure-automation-global-admin-audit`
6. Choose the Azure region.
   - Suggested: same region as the Automation account.
7. Select `Review + create`, then `Create`.

### 2. Create the Automation account

1. In Azure portal, select `Create a resource`.
2. Search for `Automation`.
3. Select the Microsoft `Automation` service and choose `Create`.
4. Enter:
   - Subscription: same as above
   - Resource group: the one from step 1
   - Automation account name:
     - Suggested: `aa-global-admin-audit`
   - Region: same as resource group unless there is a reason not to
5. Finish creation.
6. Open the new Automation account.

### 3. Upload the certificate to Azure Automation

1. In the Automation account, open `Certificates`.
2. Select `Add a certificate`.
3. Upload the `.pfx` file for `CN=ActaMSP-GDAP-Automation`.
4. Enter the `.pfx` password.
5. Save it.
6. Confirm the thumbprint in Azure matches `D0278AED132F9C816A815A4BFFF0F48CE8FAECEF`.
7. Record the expiration date so it can be rotated before `2028-03-10`.

### 4. Add the required Microsoft Graph modules

The script requires these Graph cmdlets/modules:

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Identity.DirectoryManagement`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Identity.Partner`

If the Automation account is using the newer Runtime Environment experience:

1. Open `Runtime Environments`.
2. Create a runtime environment for `PowerShell 7.4`.
3. Add the Graph modules from gallery.
4. Wait for all imports to finish before moving on.

If the Automation account is using the older module view:

1. Open `Modules`.
2. Select `Browse gallery`.
3. Import the four modules above.
4. Wait for all imports to finish before moving on.

Importing the entire `Microsoft.Graph` rollup module is also acceptable, but it is larger than needed.

### 5. Import the runbook

1. Open `Runbooks`.
2. Select `Import a runbook`.
3. Browse to [`global-admin-audit.ps1`](C:/Users/wogorman.DATAMAX/cuddly-train/global-admin-audit.ps1).
4. Keep the runbook type as `PowerShell`.
5. Choose the runtime version that matches the Graph module setup.
   - Recommended: `PowerShell 7.4`
6. Import the runbook.

### 6. First test run in Azure Automation

Run a dry run first.

1. Open the imported runbook.
2. Open the `Test` pane or start a job manually from the draft.
3. Supply these parameters:
   - `DiscoveryTenantId`: `9f50b569-9e79-47a5-bbe6-f362934d55a0`
   - `DiscoveryMode`: `GDAPAndContracts`
   - Check `DryRun`
   - `IncludeMspTenant`: only set this if you also want the MSP tenant audited
   - Leave `StopOnError` unset so one tenant failure does not stop the rest
4. Start the test.
5. Review output for:
   - successful Graph connection
   - successful tenant discovery
   - add/remove actions that would occur
   - any `AADSTS7000229` failures for the five not-yet-onboarded tenants

### 7. Publish the runbook

1. If the dry run looks correct, select `Publish`.
2. Confirm the publish action.

### 8. Create the production schedule

1. In the published runbook, open `Schedules`.
2. Select `Add a schedule`.
3. Select `Link a schedule to your runbook`.
4. Create a new schedule.
5. Pick the cadence.
   - Recommended starting point: once daily in an off-hours window
6. Set runbook parameters:
   - `DiscoveryTenantId`: `9f50b569-9e79-47a5-bbe6-f362934d55a0`
   - `DiscoveryMode`: `GDAPAndContracts`
   - Leave `DryRun` unset
   - Leave `StopOnError` unset
7. Save the schedule link.

## Recommended rollout order

1. Dry run in Azure Automation first.
2. Fix or onboard the five tenants still missing the enterprise app.
3. Publish and schedule the live run.
4. Review the first live job output before leaving it unattended.

## Caveat about `RemoveStaleMembers`

The script currently uses `RemoveStaleMembers` as a PowerShell `switch` but treats the default as enabled when the parameter is omitted. That is fine for normal scheduled production runs, but it means Azure Automation portal input is not a clean way to pass `-RemoveStaleMembers:$false` for a cautious first live run.

Practical result:

- `DryRun` is the correct first validation step in Azure Automation.
- If you want a live add-only run before allowing removals, either run the script from PowerShell with `-RemoveStaleMembers:$false` or revise the parameter model before handing it off.

## What success looks like

For each healthy tenant, the runbook should:

1. Connect to Microsoft Graph with app-only certificate auth.
2. Resolve the `Global Administrator` role.
3. Create or find the `ActaMSP Global Administrators Audit` group.
4. Add missing members.
5. Remove stale members when running live with removals enabled.

## Sources

Official Microsoft docs used for the Azure steps:

- Resource group creation: https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal
- Azure Automation with Microsoft Graph and certificate auth: https://learn.microsoft.com/en-us/entra/id-governance/identity-governance-automation
- Runtime environments in Azure Automation: https://learn.microsoft.com/en-us/azure/automation/manage-runtime-environment
- Runbook import, publish, and schedule: https://learn.microsoft.com/en-us/azure/automation/manage-runbooks
- Azure Automation certificate assets: https://learn.microsoft.com/en-us/azure/automation/shared-resources/certificates
