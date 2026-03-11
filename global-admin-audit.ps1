param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",

    [Parameter(Mandatory = $false)]
    [string]$Thumbprint = "D0278AED132F9C816A815A4BFFF0F48CE8FAECEF",

    [Parameter(Mandatory = $false)]
    [string]$GroupDisplayName = "ActaMSP Global Administrators Audit",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveStaleMembers
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Get-DirectoryObjectId {
    param($Object)

    if ($null -ne $Object.Id) {
        return $Object.Id
    }

    if ($null -ne $Object.AdditionalProperties -and $Object.AdditionalProperties.ContainsKey("id")) {
        return $Object.AdditionalProperties["id"]
    }

    return $null
}

function Get-DirectoryObjectDisplay {
    param($Object)

    if ($null -ne $Object.AdditionalProperties) {
        if ($Object.AdditionalProperties.ContainsKey("displayName")) {
            return [string]$Object.AdditionalProperties["displayName"]
        }
        if ($Object.AdditionalProperties.ContainsKey("userPrincipalName")) {
            return [string]$Object.AdditionalProperties["userPrincipalName"]
        }
    }

    if ($null -ne $Object.DisplayName) {
        return [string]$Object.DisplayName
    }

    return "<unknown>"
}

Write-Log "Connecting to tenant $TenantId"
Connect-MgGraph `
    -ClientId $ClientId `
    -TenantId $TenantId `
    -CertificateThumbprint $Thumbprint `
    -NoWelcome

$ctx = Get-MgContext
Write-Log "Connected. Tenant: $($ctx.TenantId) AppId: $($ctx.ClientId) AuthType: $($ctx.AuthType)"

# Resolve the built-in Global Administrator role
# Role template ID for Global Administrator / Company Administrator
$globalAdminTemplateId = "62e90394-69f5-4237-9190-012177145e10"

$role = Get-MgDirectoryRole -All | Where-Object {
    $_.RoleTemplateId -eq $globalAdminTemplateId -or $_.DisplayName -eq "Global Administrator"
}

if (-not $role) {
    throw "Could not find the Global Administrator directory role in tenant $TenantId."
}

Write-Log "Resolved role: $($role.DisplayName) [$($role.Id)]"

$globalAdmins = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All
$globalAdminIds = @{}
foreach ($admin in $globalAdmins) {
    $id = Get-DirectoryObjectId -Object $admin
    if ($id) {
        $globalAdminIds[$id] = $admin
    }
}

Write-Log "Found $($globalAdminIds.Count) Global Administrator member(s)."
foreach ($admin in $globalAdmins) {
    Write-Log ("  GA: {0} [{1}]" -f (Get-DirectoryObjectDisplay -Object $admin), (Get-DirectoryObjectId -Object $admin))
}

# Find or create the audit group
$escapedName = $GroupDisplayName.Replace("'", "''")
$group = Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual

if (-not $group) {
    Write-Log "Audit group not found: $GroupDisplayName"

    if ($DryRun) {
        Write-Log "DRY RUN: would create group '$GroupDisplayName'"
        $group = [pscustomobject]@{
            Id = "<dry-run-group>"
            DisplayName = $GroupDisplayName
        }
    }
    else {
        $mailNickname = (
            ($GroupDisplayName -replace '[^a-zA-Z0-9]', '').ToLower() +
            (Get-Random -Minimum 1000 -Maximum 9999)
        )

        $group = New-MgGroup `
            -DisplayName $GroupDisplayName `
            -Description "Maintained by ActaMSP automation. Mirrors current Global Administrator role membership." `
            -MailEnabled:$false `
            -MailNickname $mailNickname `
            -SecurityEnabled:$true

        Write-Log "Created group '$($group.DisplayName)' [$($group.Id)]"
    }
}
else {
    Write-Log "Using existing group '$($group.DisplayName)' [$($group.Id)]"
}

# Read current group members
$currentMembers = @()
if ($group.Id -ne "<dry-run-group>") {
    $currentMembers = Get-MgGroupMember -GroupId $group.Id -All
}

$currentMemberIds = @{}
foreach ($member in $currentMembers) {
    $id = Get-DirectoryObjectId -Object $member
    if ($id) {
        $currentMemberIds[$id] = $member
    }
}

Write-Log "Current audit group member count: $($currentMemberIds.Count)"

# Add missing Global Admins
$idsToAdd = $globalAdminIds.Keys | Where-Object { -not $currentMemberIds.ContainsKey($_) }

foreach ($id in $idsToAdd) {
    $display = Get-DirectoryObjectDisplay -Object $globalAdminIds[$id]

    if ($DryRun) {
        Write-Log "DRY RUN: would add '$display' [$id] to audit group"
    }
    else {
        New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$id"
        }
        Write-Log "Added '$display' [$id] to audit group"
    }
}

# Optionally remove members who are no longer Global Admins
if ($RemoveStaleMembers) {
    $idsToRemove = $currentMemberIds.Keys | Where-Object { -not $globalAdminIds.ContainsKey($_) }

    foreach ($id in $idsToRemove) {
        $display = Get-DirectoryObjectDisplay -Object $currentMemberIds[$id]

        if ($DryRun) {
            Write-Log "DRY RUN: would remove '$display' [$id] from audit group"
        }
        else {
            Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $id
            Write-Log "Removed '$display' [$id] from audit group"
        }
    }
}

Write-Log "Complete."
Disconnect-MgGraph | Out-Null