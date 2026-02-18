[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
  [Parameter(Mandatory)] [string] $ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[actamsp-bootstrap] $Message"
}

function New-PlaceholderObject {
  param([hashtable] $Data)
  return [pscustomobject]$Data
}

function Get-SingleOrThrow {
  param(
    [AllowNull()] [object[]] $Items,
    [string] $Description
  )

  if (-not $Items) { return $null }
  if ($Items.Count -gt 1) {
    $ids = ($Items | ForEach-Object { $_.Id }) -join ", "
    throw "Multiple $Description objects found. Resolve duplicates first. IDs: $ids"
  }
  return $Items[0]
}

function Get-ConfigValue {
  param(
    [object] $Config,
    [string] $Name
  )

  $value = $Config.$Name
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required config value: $Name"
  }
  return $value
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
  throw "Config file not found: $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$tenantId = Get-ConfigValue -Config $config -Name "TenantId"
$resolvedConfigPath = (Resolve-Path -Path $ConfigPath).Path
$configDirectory = Split-Path -Path $resolvedConfigPath -Parent

$requiredConfigKeys = @("IntegrationGroupName", "PilotGroupName", "AppDisplayName")
foreach ($key in $requiredConfigKeys) {
  [void](Get-ConfigValue -Config $config -Name $key)
}

$requiredGraphConnectionScopes = @(
  "Application.ReadWrite.All",
  "Directory.ReadWrite.All",
  "Group.ReadWrite.All"
)

Write-Step "Connecting to Microsoft Graph tenant $tenantId"
Connect-MgGraph -TenantId $tenantId -Scopes $requiredGraphConnectionScopes | Out-Null
Select-MgProfile -Name "v1.0" | Out-Null

$graphContext = Get-MgContext
if ($graphContext.TenantId -ne $tenantId) {
  throw "Connected Graph tenant ($($graphContext.TenantId)) does not match requested tenant ($tenantId)."
}

$graphResourceAppId = "00000003-0000-0000-c000-000000000000"
$dynamicMembershipRule = '(user.accountEnabled -eq true) and (user.assignedLicenses -any (assignedLicense.skuId -ne Guid("00000000-0000-0000-0000-000000000000")))'

function Ensure-Group {
  param(
    [string] $DisplayName,
    [ValidateSet("Assigned","Dynamic")] [string] $Type
  )

  $groups = @(Get-MgGroup -Filter "displayName eq '$($DisplayName.Replace("'","''"))'" -ConsistencyLevel eventual -CountVariable ignore -All `
    -Property "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled")
  $existing = Get-SingleOrThrow -Items $groups -Description "group named $DisplayName"

  if (-not $existing) {
    Write-Step "Creating $Type group: $DisplayName"
    if ($Type -eq "Assigned") {
      if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create assigned security group")) {
        return New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -SecurityEnabled:$true -MailNickname ([Guid]::NewGuid().ToString("N"))
      }
      return New-PlaceholderObject -Data @{
        Id = $null
        DisplayName = $DisplayName
        GroupTypes = @()
        IsPlanned = $true
      }
    }

    if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create dynamic security group")) {
      return New-MgGroup `
        -DisplayName $DisplayName `
        -MailEnabled:$false `
        -SecurityEnabled:$true `
        -MailNickname ([Guid]::NewGuid().ToString("N")) `
        -GroupTypes @("DynamicMembership") `
        -MembershipRule $dynamicMembershipRule `
        -MembershipRuleProcessingState "On"
    }
    return New-PlaceholderObject -Data @{
      Id = $null
      DisplayName = $DisplayName
      GroupTypes = @("DynamicMembership")
      MembershipRule = $dynamicMembershipRule
      MembershipRuleProcessingState = "On"
      IsPlanned = $true
    }
  }

  if ($Type -eq "Dynamic") {
    if (-not ($existing.GroupTypes -contains "DynamicMembership")) {
      throw "Group '$DisplayName' exists but is not dynamic. Convert/remove it before running bootstrap."
    }

    $shouldPatch = $false
    $patch = @{}
    if ($existing.MembershipRule -ne $dynamicMembershipRule) {
      $patch["MembershipRule"] = $dynamicMembershipRule
      $shouldPatch = $true
    }
    if ($existing.MembershipRuleProcessingState -ne "On") {
      $patch["MembershipRuleProcessingState"] = "On"
      $shouldPatch = $true
    }

    if ($shouldPatch) {
      Write-Step "Updating dynamic membership settings for $DisplayName"
      if ($script:PSCmdlet.ShouldProcess($DisplayName, "Update dynamic group membership settings")) {
        Update-MgGroup -GroupId $existing.Id @patch | Out-Null
        return Get-MgGroup -GroupId $existing.Id -Property "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState"
      }
    }
  } elseif ($existing.GroupTypes -contains "DynamicMembership") {
    throw "Group '$DisplayName' exists but is dynamic. Expected assigned/static group."
  }

  return $existing
}

function Ensure-Application {
  param([string] $DisplayName)

  $apps = @(Get-MgApplication -Filter "displayName eq '$($DisplayName.Replace("'","''"))'" -All -Property "id,appId,displayName,requiredResourceAccess")
  $existing = Get-SingleOrThrow -Items $apps -Description "application named $DisplayName"
  if ($existing) { return $existing }

  Write-Step "Creating app registration: $DisplayName"
  if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create app registration")) {
    return New-MgApplication -DisplayName $DisplayName
  }
  return New-PlaceholderObject -Data @{
    Id = $null
    AppId = $null
    DisplayName = $DisplayName
    RequiredResourceAccess = @()
    IsPlanned = $true
  }
}

function Ensure-ServicePrincipalForApp {
  param([string] $AppId)

  if ([string]::IsNullOrWhiteSpace($AppId)) {
    return New-PlaceholderObject -Data @{
      Id = $null
      AppId = $null
      DisplayName = "Planned ActaMSP App Service Principal"
      IsPlanned = $true
    }
  }

  $sps = @(Get-MgServicePrincipal -Filter "appId eq '$AppId'" -All -Property "id,appId,displayName")
  $existing = Get-SingleOrThrow -Items $sps -Description "service principal for appId $AppId"
  if ($existing) { return $existing }

  Write-Step "Creating service principal for appId $AppId"
  if ($script:PSCmdlet.ShouldProcess($AppId, "Create service principal")) {
    return New-MgServicePrincipal -AppId $AppId
  }
  return New-PlaceholderObject -Data @{
    Id = $null
    AppId = $AppId
    DisplayName = "Planned ActaMSP App Service Principal"
    IsPlanned = $true
  }
}

function Resolve-GraphAppRoleId {
  param(
    [object] $GraphSp,
    [string] $Value
  )

  $role = $GraphSp.AppRoles | Where-Object {
    $_.Value -eq $Value -and $_.AllowedMemberTypes -contains "Application" -and $_.IsEnabled -eq $true
  } | Select-Object -First 1

  if (-not $role) { throw "Graph application permission not found: $Value" }
  return $role.Id
}

function Resolve-GraphScopeId {
  param(
    [object] $GraphSp,
    [string] $Value
  )

  $scope = $GraphSp.Oauth2PermissionScopes | Where-Object {
    $_.Value -eq $Value -and $_.IsEnabled -eq $true
  } | Select-Object -First 1

  if (-not $scope) { throw "Graph delegated permission not found: $Value" }
  return $scope.Id
}

function Set-ApplicationRequiredResourceAccess {
  param(
    [object] $App,
    [object] $GraphSp,
    [string[]] $RequiredApplicationPerms,
    [string[]] $RequiredDelegatedPerms
  )

  if (-not $App.Id) {
    Write-Step "Skipping Graph requiredResourceAccess update because app registration is not materialized in this run."
    return
  }

  $desiredGraphAccess = @()
  foreach ($perm in ($RequiredApplicationPerms | Sort-Object -Unique)) {
    $desiredGraphAccess += @{
      Id = (Resolve-GraphAppRoleId -GraphSp $GraphSp -Value $perm)
      Type = "Role"
    }
  }
  foreach ($perm in ($RequiredDelegatedPerms | Sort-Object -Unique)) {
    $desiredGraphAccess += @{
      Id = (Resolve-GraphScopeId -GraphSp $GraphSp -Value $perm)
      Type = "Scope"
    }
  }

  $desiredGraphAccess = $desiredGraphAccess | Sort-Object @{ Expression = "Type"; Ascending = $true }, @{ Expression = "Id"; Ascending = $true } -Unique

  $existing = @($App.RequiredResourceAccess)
  $nonGraphExisting = @($existing | Where-Object { $_.ResourceAppId -ne $graphResourceAppId })
  $newRequiredResourceAccess = @($nonGraphExisting + @(@{
    ResourceAppId = $graphResourceAppId
    ResourceAccess = $desiredGraphAccess
  }))

  $currentGraph = @($existing | Where-Object { $_.ResourceAppId -eq $graphResourceAppId } | Select-Object -ExpandProperty ResourceAccess)
  $currentGraphKeys = @($currentGraph | ForEach-Object { "$($_.Type)|$($_.Id)" } | Sort-Object -Unique)
  $desiredGraphKeys = @($desiredGraphAccess | ForEach-Object { "$($_.Type)|$($_.Id)" } | Sort-Object -Unique)

  $isDifferent = ($currentGraphKeys -join ",") -ne ($desiredGraphKeys -join ",")
  if ($isDifferent) {
    Write-Step "Updating required Graph API permissions on app registration"
    if ($script:PSCmdlet.ShouldProcess($App.DisplayName, "Update required Graph API permissions")) {
      Update-MgApplication -ApplicationId $App.Id -RequiredResourceAccess $newRequiredResourceAccess | Out-Null
    }
  }
}

function Ensure-ApplicationAdminConsent {
  param(
    [object] $AppServicePrincipal,
    [object] $GraphSp,
    [string[]] $RequiredApplicationPerms
  )

  if (-not $AppServicePrincipal.Id) {
    Write-Step "Skipping application permission consent because service principal is not materialized in this run."
    return
  }

  $existingAssignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AppServicePrincipal.Id -All)
  $assignmentKeys = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($assignment in $existingAssignments) {
    [void]$assignmentKeys.Add("$($assignment.ResourceId)|$($assignment.AppRoleId)")
  }

  foreach ($perm in ($RequiredApplicationPerms | Sort-Object -Unique)) {
    $appRoleId = Resolve-GraphAppRoleId -GraphSp $GraphSp -Value $perm
    $key = "$($GraphSp.Id)|$appRoleId"
    if (-not $assignmentKeys.Contains($key)) {
      Write-Step "Granting application permission consent: $perm"
      if ($script:PSCmdlet.ShouldProcess($AppServicePrincipal.AppId, "Grant application permission consent: $perm")) {
        New-MgServicePrincipalAppRoleAssignment `
          -ServicePrincipalId $AppServicePrincipal.Id `
          -PrincipalId $AppServicePrincipal.Id `
          -ResourceId $GraphSp.Id `
          -AppRoleId $appRoleId | Out-Null
        [void]$assignmentKeys.Add($key)
      }
    }
  }
}

function Ensure-DelegatedAdminConsent {
  param(
    [object] $AppServicePrincipal,
    [object] $GraphSp,
    [string[]] $RequiredDelegatedPerms
  )

  $desiredScopes = @($RequiredDelegatedPerms | Sort-Object -Unique)
  $desiredScopeString = $desiredScopes -join " "

  if (-not $AppServicePrincipal.Id) {
    Write-Step "Skipping delegated permission consent because service principal is not materialized in this run."
    return $desiredScopeString
  }

  $grants = @(Get-MgOauth2PermissionGrant -Filter "clientId eq '$($AppServicePrincipal.Id)' and resourceId eq '$($GraphSp.Id)' and consentType eq 'AllPrincipals'" -All)
  if (-not $grants) {
    Write-Step "Granting delegated permission consent (AllPrincipals)"
    if ($script:PSCmdlet.ShouldProcess($AppServicePrincipal.AppId, "Grant delegated permission consent (AllPrincipals)")) {
      New-MgOauth2PermissionGrant `
        -ClientId $AppServicePrincipal.Id `
        -ConsentType "AllPrincipals" `
        -ResourceId $GraphSp.Id `
        -Scope $desiredScopeString | Out-Null
    }
    return $desiredScopeString
  }

  $grant = Get-SingleOrThrow -Items $grants -Description "AllPrincipals OAuth2 permission grant for app service principal $($AppServicePrincipal.Id)"
  $existingScopes = @($grant.Scope -split " " | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $mergedScopes = @($existingScopes + $desiredScopes | Sort-Object -Unique)
  $mergedScopeString = $mergedScopes -join " "

  if ($mergedScopeString -ne ($existingScopes -join " ")) {
    Write-Step "Updating delegated permission consent scopes"
    if ($script:PSCmdlet.ShouldProcess($AppServicePrincipal.AppId, "Update delegated permission consent scopes")) {
      Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope $mergedScopeString | Out-Null
    }
  }

  return $mergedScopeString
}

function New-BicepParametersFromState {
  param(
    [string] $OutputPath,
    [System.Collections.IDictionary] $State
  )

  $parameters = [ordered]@{}
  foreach ($entry in $State.GetEnumerator()) {
    $parameters[$entry.Key] = @{ value = $entry.Value }
  }

  $paramFile = [ordered]@{
    '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters = $parameters
  }

  if ($script:PSCmdlet.ShouldProcess($OutputPath, "Write Bicep parameters file")) {
    $paramFile | ConvertTo-Json -Depth 15 | Set-Content -Path $OutputPath -Encoding UTF8
    return $true
  }
  return $false
}

function Invoke-OptionalBicepDeployment {
  param(
    [object] $Config,
    [string] $BaseDirectory,
    [string] $BicepParametersPath
  )

  if ([string]::IsNullOrWhiteSpace($Config.BicepTemplatePath)) {
    return
  }

  $templatePath = $Config.BicepTemplatePath
  if (-not [System.IO.Path]::IsPathRooted($templatePath)) {
    $templatePath = Join-Path -Path $BaseDirectory -ChildPath $templatePath
  }
  if (-not (Test-Path -Path $templatePath -PathType Leaf)) {
    throw "Bicep template file not found: $templatePath"
  }

  $azCmd = Get-Command -Name "az" -ErrorAction SilentlyContinue
  if (-not $azCmd) {
    throw "Azure CLI 'az' is required for Bicep deployment but is not installed/in PATH."
  }

  $location = if ([string]::IsNullOrWhiteSpace($Config.BicepLocation)) { "eastus" } else { $Config.BicepLocation }
  $deploymentName = if ([string]::IsNullOrWhiteSpace($Config.BicepDeploymentName)) { "actamsp-bootstrap-$(Get-Date -Format 'yyyyMMddHHmmss')" } else { $Config.BicepDeploymentName }
  $extraParametersPath = $Config.BicepParametersPath
  if (-not [string]::IsNullOrWhiteSpace($extraParametersPath) -and -not [System.IO.Path]::IsPathRooted($extraParametersPath)) {
    $extraParametersPath = Join-Path -Path $BaseDirectory -ChildPath $extraParametersPath
  }

  Write-Step "Running tenant-scope Bicep deployment: $deploymentName"
  $azArgs = @(
    "deployment", "tenant", "create",
    "--name", $deploymentName,
    "--location", $location,
    "--template-file", $templatePath,
    "--parameters", "@$BicepParametersPath"
  )

  if (-not [string]::IsNullOrWhiteSpace($extraParametersPath)) {
    if (-not (Test-Path -Path $extraParametersPath -PathType Leaf)) {
      throw "Configured BicepParametersPath not found: $extraParametersPath"
    }
    $azArgs += @("--parameters", "@$extraParametersPath")
  }

  if ($script:PSCmdlet.ShouldProcess($deploymentName, "Run tenant-scope Bicep deployment")) {
    & az @azArgs
    if ($LASTEXITCODE -ne 0) {
      throw "Bicep deployment failed with exit code $LASTEXITCODE."
    }
  }
}

Write-Step "Ensuring ActaMSP groups"
$integrationGroup = Ensure-Group -DisplayName $config.IntegrationGroupName -Type Dynamic
$pilotGroup = Ensure-Group -DisplayName $config.PilotGroupName -Type Assigned

Write-Step "Ensuring app registration and service principal"
$app = Ensure-Application -DisplayName $config.AppDisplayName
$sp = Ensure-ServicePrincipalForApp -AppId $app.AppId

Write-Step "Resolving Microsoft Graph service principal"
$graphSp = Get-SingleOrThrow -Items @(Get-MgServicePrincipal -Filter "appId eq '$graphResourceAppId'" -All -Property "id,appRoles,oauth2PermissionScopes,displayName") -Description "Microsoft Graph service principal"
if (-not $graphSp) {
  throw "Microsoft Graph service principal not found in tenant."
}

$requiredApplicationPerms = @(
  "AdministrativeUnit.Read.All",
  "AuditLog.Read.All",
  "Device.Read.All",
  "Directory.Read.All",
  "Domain.Read.All",
  "Group.Read.All",
  "GroupMember.Read.All",
  "IdentityProvider.Read.All",
  "Notes.Read.All",
  "Organization.Read.All",
  "Reports.Read.All",
  "SecurityEvents.Read.All",
  "Sites.Read.All",
  "User.Read.All",
  "User.ReadBasic.All"
)

$requiredDelegatedPerms = @(
  "Subscription.Read.All",
  "User.Read",
  "User.Read.All",
  "User.ReadBasic.All"
)

Set-ApplicationRequiredResourceAccess `
  -App $app `
  -GraphSp $graphSp `
  -RequiredApplicationPerms $requiredApplicationPerms `
  -RequiredDelegatedPerms $requiredDelegatedPerms

Ensure-ApplicationAdminConsent `
  -AppServicePrincipal $sp `
  -GraphSp $graphSp `
  -RequiredApplicationPerms $requiredApplicationPerms

$delegatedScopeString = Ensure-DelegatedAdminConsent `
  -AppServicePrincipal $sp `
  -GraphSp $graphSp `
  -RequiredDelegatedPerms $requiredDelegatedPerms

$state = [ordered]@{
  TenantId = $tenantId
  IntegrationGroupId = $integrationGroup.Id
  PilotGroupId = $pilotGroup.Id
  ApplicationObjectId = $app.Id
  ApplicationAppId = $app.AppId
  ServicePrincipalId = $sp.Id
  GraphResourceSpId = $graphSp.Id
  DelegatedScopes = $delegatedScopeString
  ApplicationRoles = ($requiredApplicationPerms | Sort-Object -Unique)
}

$statePath = [System.IO.Path]::ChangeExtension($ConfigPath, ".state.json")
if ($script:PSCmdlet.ShouldProcess($statePath, "Write bootstrap state file")) {
  $state | ConvertTo-Json -Depth 15 | Set-Content -Path $statePath -Encoding UTF8
  Write-Step "State saved: $statePath"
} else {
  Write-Step "Skipped state file write: $statePath"
}

$bicepParamPath = [System.IO.Path]::ChangeExtension($ConfigPath, ".bootstrap.parameters.json")
$bicepParamWritten = New-BicepParametersFromState -OutputPath $bicepParamPath -State $state
if ($bicepParamWritten) {
  Write-Step "Bicep parameter scaffold saved: $bicepParamPath"
} else {
  Write-Step "Skipped Bicep parameter scaffold write: $bicepParamPath"
}

Invoke-OptionalBicepDeployment -Config $config -BaseDirectory $configDirectory -BicepParametersPath $bicepParamPath

Write-Step "Bootstrap complete."



