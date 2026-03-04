<#
.SYNOPSIS
Idempotently creates/maintains a "Global Admins" security group in each GDAP partner tenant
and synchronizes its membership to the effective Global Administrator users.

.REQUIREMENTS
Install-Module Microsoft.Graph -Scope AllUsers

AUTH MODEL
- GDAP + this app is present in each customer tenant.
- Uses certificate auth (recommended).

PERMISSIONS (App)
- Group.ReadWrite.All
- Directory.Read.All
- RoleManagement.Read.Directory (recommended for role membership reads)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ClientId,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$HomeTenantId,  # Managing tenant (where you run the script from)

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$CertificateThumbprint,

  [string]$TargetGroupDisplayName = "Global Admins",

  # If $true, removes users from the group who are no longer effective Global Admins.
  [bool]$PruneNonAdmins = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Global Administrator role template id
$GlobalAdminRoleTemplateId = "62e90394-69f5-4237-9190-012177145e10"

function Assert-RequiredMgCommands {
  $requiredCommands = @(
    "Connect-MgGraph",
    "Disconnect-MgGraph",
    "Get-MgTenantRelationshipDelegatedAdminRelationship",
    "Get-MgGroup",
    "New-MgGroup",
    "Get-MgDirectoryRole",
    "Get-MgDirectoryRoleMember",
    "Get-MgGroupTransitiveMember",
    "Get-MgGroupMember",
    "New-MgGroupMemberByRef",
    "Remove-MgGroupMemberByRef"
  )

  $missing = foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
      $cmd
    }
  }

  if ($missing) {
    $missingList = $missing -join ", "
    throw "Missing Microsoft Graph command(s): $missingList. Install/import Microsoft.Graph before running."
  }
}

function Escape-ODataStringLiteral {
  param([Parameter(Mandatory=$true)][string]$Value)
  return $Value.Replace("'", "''")
}

function Get-GraphObjectType {
  param([Parameter(Mandatory=$true)]$Object)

  if ($null -ne $Object.AdditionalProperties -and $Object.AdditionalProperties.ContainsKey("@odata.type")) {
    return [string]$Object.AdditionalProperties["@odata.type"]
  }

  $odataTypeProperty = $Object.PSObject.Properties["OdataType"]
  if ($null -ne $odataTypeProperty -and $null -ne $odataTypeProperty.Value -and $odataTypeProperty.Value -ne "") {
    return [string]$odataTypeProperty.Value
  }

  return $null
}

function Connect-GraphTenant {
  param([Parameter(Mandatory=$true)][string]$TenantId)

  Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

  Connect-MgGraph `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -CertificateThumbprint $CertificateThumbprint `
    -NoWelcome | Out-Null
}

function Get-PartnerTenantIdsFromGdap {
  # Requires connection to home tenant context.
  $tenantIds = New-Object System.Collections.Generic.HashSet[string]

  $rels = Get-MgTenantRelationshipDelegatedAdminRelationship -All
  foreach ($r in $rels) {
    if ($null -ne $r.Customer -and $null -ne $r.Customer.TenantId) {
      [void]$tenantIds.Add($r.Customer.TenantId)
    }
  }

  return $tenantIds.ToArray()
}

function Ensure-SecurityGroup {
  param(
    [Parameter(Mandatory=$true)][string]$DisplayName,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCmdlet]$CmdletContext
  )

  # Try to find an existing non-mail-enabled security group with that displayName
  $safeDisplayName = Escape-ODataStringLiteral -Value $DisplayName
  $existing = Get-MgGroup -All -Filter "displayName eq '$safeDisplayName'" -ConsistencyLevel eventual `
    | Where-Object { $_.SecurityEnabled -eq $true -and $_.MailEnabled -eq $false } `
    | Select-Object -First 1

  if ($existing) { return $existing }

  $body = @{
    displayName     = $DisplayName
    description     = "Managed by MSP script. Membership synchronized to effective Global Admin users."
    mailEnabled     = $false
    mailNickname    = ("globaladmins-" + ([guid]::NewGuid().ToString("N").Substring(0, 12)))
    securityEnabled = $true
    groupTypes      = @()
  }

  if (-not $CmdletContext.ShouldProcess("Group '$DisplayName'", "Create security group")) {
    return $null
  }

  return New-MgGroup -BodyParameter $body
}

function Get-EffectiveGlobalAdminUserIds {
  # Find activated directoryRole instance for Global Administrator
  $gaRole = Get-MgDirectoryRole -All |
    Where-Object { $_.RoleTemplateId -eq $GlobalAdminRoleTemplateId } |
    Select-Object -First 1

  if (-not $gaRole) {
    # If no activated instance exists (rare), return empty.
    return @()
  }

  $desiredUserIds = New-Object System.Collections.Generic.HashSet[string]

  # Role members can be users, groups, service principals.
  $members = Get-MgDirectoryRoleMember -DirectoryRoleId $gaRole.Id -All

  foreach ($m in $members) {
    $odataType = Get-GraphObjectType -Object $m
    $id = $m.Id

    switch ($odataType) {
      "#microsoft.graph.user" {
        [void]$desiredUserIds.Add($id)
      }
      "#microsoft.graph.group" {
        # Expand effective user members if the GA role is assigned to a group
        try {
          $tm = Get-MgGroupTransitiveMember -GroupId $id -All
          foreach ($t in $tm) {
            if ((Get-GraphObjectType -Object $t) -eq "#microsoft.graph.user") {
              [void]$desiredUserIds.Add($t.Id)
            }
          }
        }
        catch {
          Write-Warning "Failed expanding transitive members for GA-assigned group ${id}: $($_.Exception.Message)"
        }
      }
      default {
        # ignore service principals / other objects
      }
    }
  }

  return $desiredUserIds.ToArray()
}

function Sync-GroupMembersToUsers {
  param(
    [Parameter(Mandatory=$true)][string]$GroupId,
    [Parameter(Mandatory=$true)][string[]]$DesiredUserIds,
    [Parameter(Mandatory=$true)][bool]$Prune,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCmdlet]$CmdletContext
  )

  $current = Get-MgGroupMember -GroupId $GroupId -All
  $currentUserIds = New-Object System.Collections.Generic.HashSet[string]
  foreach ($c in $current) {
    if ((Get-GraphObjectType -Object $c) -eq "#microsoft.graph.user") {
      [void]$currentUserIds.Add($c.Id)
    }
  }

  $desiredSet = New-Object System.Collections.Generic.HashSet[string]
  foreach ($u in $DesiredUserIds) { [void]$desiredSet.Add($u) }

  # Add missing
  foreach ($u in $desiredSet) {
    if (-not $currentUserIds.Contains($u)) {
      try {
        if ($CmdletContext.ShouldProcess("Group '${GroupId}'", "Add user ${u}")) {
          New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$u"
          } | Out-Null
        }
      }
      catch {
        Write-Warning "Failed adding user ${u} to group ${GroupId}: $($_.Exception.Message)"
      }
    }
  }

  # Remove extras
  if ($Prune) {
    foreach ($u in $currentUserIds) {
      if (-not $desiredSet.Contains($u)) {
        try {
          if ($CmdletContext.ShouldProcess("Group '${GroupId}'", "Remove user ${u}")) {
            Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $u | Out-Null
          }
        }
        catch {
          Write-Warning "Failed removing user ${u} from group ${GroupId}: $($_.Exception.Message)"
        }
      }
    }
  }
}

# ------------------- MAIN -------------------

try {
  Assert-RequiredMgCommands
  Connect-GraphTenant -TenantId $HomeTenantId

  Write-Host "Enumerating GDAP partner tenants from home tenant $HomeTenantId ..."
  $partnerTenantIds = Get-PartnerTenantIdsFromGdap | Sort-Object

  if (-not $partnerTenantIds -or $partnerTenantIds.Count -eq 0) {
    Write-Host "No partner tenants found via delegatedAdminRelationships."
    return
  }

  Write-Host "Found $($partnerTenantIds.Count) partner tenants."

  foreach ($pt in $partnerTenantIds) {
    Write-Host "`n--- Partner tenant: $pt ---"

    try {
      Connect-GraphTenant -TenantId $pt

      $grp = Ensure-SecurityGroup -DisplayName $TargetGroupDisplayName -CmdletContext $PSCmdlet
      if (-not $grp) {
        Write-Host "Group '$TargetGroupDisplayName' does not exist and creation was skipped."
        continue
      }
      Write-Host "Group ensured: $($grp.DisplayName) ($($grp.Id))"

      $desiredUsers = Get-EffectiveGlobalAdminUserIds
      Write-Host "Effective GA users found: $($desiredUsers.Count)"

      Sync-GroupMembersToUsers -GroupId $grp.Id -DesiredUserIds $desiredUsers -Prune:$PruneNonAdmins -CmdletContext $PSCmdlet
      Write-Host "Sync complete."
    }
    catch {
      Write-Warning "Tenant $pt failed: $($_.Exception.Message)"
      continue
    }
  }

  Write-Host "`nDone."
}
finally {
  Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
