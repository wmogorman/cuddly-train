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

function Add-AuditControl {
  param(
    [string] $ControlName,
    [string[]] $MissingItems = @(),
    [string] $Action = "None",
    [string] $Notes = ""
  )

  $missing = @($MissingItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $validationStatus = if ($missing.Count -eq 0) { "Compliant" } else { "Missing" }

  $script:AuditControls.Add([pscustomobject]@{
    ControlName = $ControlName
    ValidationStatus = $validationStatus
    MissingCount = $missing.Count
    MissingItems = $missing
    Action = $Action
    Notes = $Notes
  }) | Out-Null
}

function Get-AuditSummary {
  param([object[]] $Controls)

  $missingControls = @($Controls | Where-Object { $_.MissingCount -gt 0 })
  $compliantControls = @($Controls | Where-Object { $_.MissingCount -eq 0 })
  $remediated = @($missingControls | Where-Object { $_.Action -in @("Created", "Updated", "Granted") })
  $planned = @($missingControls | Where-Object { $_.Action -like "Planned*" })
  $unresolved = $missingControls.Count - $remediated.Count

  return [ordered]@{
    Controls = $Controls.Count
    AlreadyCompliant = $compliantControls.Count
    Missing = $missingControls.Count
    RemediatedNow = $remediated.Count
    PlannedOnly = $planned.Count
    StillMissing = $unresolved
  }
}

function Write-AuditReport {
  param(
    [object[]] $Controls,
    [System.Collections.IDictionary] $Summary
  )

  Write-Step ("Audit summary: controls={0}, already-compliant={1}, missing={2}, remediated-now={3}, planned-only={4}, still-missing={5}" -f `
    $Summary.Controls, $Summary.AlreadyCompliant, $Summary.Missing, $Summary.RemediatedNow, $Summary.PlannedOnly, $Summary.StillMissing)

  foreach ($control in $Controls) {
    $missingText = if ($control.MissingCount -eq 0) { "none" } else { ($control.MissingItems -join ", ") }
    Write-Host ("[actamsp-bootstrap][audit] {0} | status={1} | action={2} | missing={3}" -f `
      $control.ControlName, $control.ValidationStatus, $control.Action, $missingText)
  }
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

function Get-PrimaryDomainForIntegrationGroup {
  param([object] $Config)

  $configuredDomain = $Config.IntegrationGroupPrimaryDomain
  if (-not [string]::IsNullOrWhiteSpace($configuredDomain)) {
    return $configuredDomain.Trim()
  }

  $domains = @(Get-MgDomain -All -Property "id,isDefault,isVerified")
  $defaultVerified = @($domains | Where-Object { $_.IsDefault -eq $true -and $_.IsVerified -eq $true } | Select-Object -First 1)
  if ($defaultVerified.Count -gt 0) {
    return $defaultVerified[0].Id
  }

  $firstVerified = @($domains | Where-Object { $_.IsVerified -eq $true } | Select-Object -First 1)
  if ($firstVerified.Count -gt 0) {
    return $firstVerified[0].Id
  }

  throw "Could not resolve a verified primary domain for integration group rule. Set IntegrationGroupPrimaryDomain in config."
}

function Get-ExceptionMessageText {
  param([object] $ErrorObject)

  $exception = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
    $ErrorObject.Exception
  } elseif ($ErrorObject -is [System.Exception]) {
    $ErrorObject
  } else {
    return [string]$ErrorObject
  }

  $messages = [System.Collections.Generic.List[string]]::new()
  while ($exception) {
    if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
      $messages.Add($exception.Message) | Out-Null
    }
    $exception = $exception.InnerException
  }

  return ($messages -join " | ")
}

function Test-IsDynamicGroupLicenseConstraintError {
  param([object] $ErrorObject)

  $message = Get-ExceptionMessageText -ErrorObject $ErrorObject
  if ([string]::IsNullOrWhiteSpace($message)) {
    return $false
  }

  $hasDynamicSignal = $message -match "(?i)(dynamic|membershiprule|membership rule)"
  $hasLicenseSignal = $message -match "(?i)(premium|p1|license|licensing|sku|subscription)"
  return ($hasDynamicSignal -and $hasLicenseSignal)
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
  throw "Config file not found: $ConfigPath"
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$tenantId = Get-ConfigValue -Config $config -Name "TenantId"
$resolvedConfigPath = (Resolve-Path -Path $ConfigPath).Path
$configDirectory = Split-Path -Path $resolvedConfigPath -Parent
$script:AuditControls = [System.Collections.Generic.List[object]]::new()
$script:RunStartedAt = (Get-Date).ToString("o")

$requiredConfigKeys = @("IntegrationGroupName", "PilotGroupName", "AppDisplayName")
foreach ($key in $requiredConfigKeys) {
  [void](Get-ConfigValue -Config $config -Name $key)
}

$integrationGroupModeRaw = [string]$config.IntegrationGroupMode
if ([string]::IsNullOrWhiteSpace($integrationGroupModeRaw)) {
  $integrationGroupModeRaw = "Auto"
}

switch -Regex ($integrationGroupModeRaw.Trim().ToLowerInvariant()) {
  "^auto$"     { $integrationGroupMode = "Auto"; break }
  "^dynamic$"  { $integrationGroupMode = "Dynamic"; break }
  "^assigned$" { $integrationGroupMode = "Assigned"; break }
  default {
    throw "Invalid IntegrationGroupMode '$integrationGroupModeRaw'. Valid values: Auto, Dynamic, Assigned."
  }
}

$requiredGraphConnectionScopes = @(
  "Application.ReadWrite.All",
  "Directory.ReadWrite.All",
  "Domain.Read.All",
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
$integrationPrimaryDomain = Get-PrimaryDomainForIntegrationGroup -Config $config
$integrationGroupLegacyNames = @("DMX Integration Group", "DMX_Integration_Group")
Write-Step "Using integration group primary domain filter: $integrationPrimaryDomain"
$dynamicMembershipRule = "(user.userPrincipalName -contains '@$integrationPrimaryDomain') and (user.department -ne `"NotSupport`") and (user.accountEnabled -eq true) and (user.assignedPlans -any (assignedPlan.servicePlanId -ne `"`" -and assignedPlan.capabilityStatus -eq `"Enabled`"))"
Write-Step "Integration group mode: $integrationGroupMode"

function Ensure-Group {
  param(
    [string] $DisplayName,
    [ValidateSet("Assigned","Dynamic")] [string] $Type,
    [switch] $AllowAssignedFallbackIfDynamicUnavailable,
    [string[]] $LegacyDisplayNames = @(),
    [switch] $RenameLegacyDisplayNameToCurrent,
    [switch] $PreserveExistingDynamicMembershipRule,
    [switch] $PrintDynamicMembershipRule
  )

  $controlName = "Group/$DisplayName"
  $searchDisplayNames = @($DisplayName + @($LegacyDisplayNames) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $allMatches = @()
  foreach ($name in $searchDisplayNames) {
    $allMatches += @(Get-MgGroup -Filter "displayName eq '$($name.Replace("'","''"))'" -ConsistencyLevel eventual -CountVariable ignore -All `
      -Property "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled")
  }

  $byId = @{}
  foreach ($group in $allMatches) {
    if (-not $byId.ContainsKey($group.Id)) {
      $byId[$group.Id] = $group
    }
  }
  $matchedGroups = @($byId.Values)

  $preferredMatches = @($matchedGroups | Where-Object { $_.DisplayName -eq $DisplayName })
  if ($preferredMatches.Count -gt 1) {
    $ids = ($preferredMatches | ForEach-Object { $_.Id }) -join ", "
    Add-AuditControl -ControlName $controlName -MissingItems @("DuplicateTargetGroups") -Action "Error" -Notes "Multiple groups already named '$DisplayName'. IDs: $ids"
    throw "Multiple groups named '$DisplayName' found. Resolve duplicates first. IDs: $ids"
  }

  $existing = $null
  if ($preferredMatches.Count -eq 1) {
    $existing = $preferredMatches[0]
    $legacyCollisions = @($matchedGroups | Where-Object { $_.Id -ne $existing.Id })
    if ($legacyCollisions.Count -gt 0) {
      $legacyNames = ($legacyCollisions | Select-Object -ExpandProperty DisplayName -Unique) -join ", "
      Write-Warning "Found additional legacy-named integration groups while '$DisplayName' already exists. Leaving extras unchanged: $legacyNames"
      Add-AuditControl -ControlName "GroupAlias/$DisplayName" -MissingItems @("AdditionalLegacyNamedGroups") -Action "Warning" -Notes "Additional legacy-named groups found and not renamed: $legacyNames"
    }
  } elseif ($matchedGroups.Count -eq 1) {
    $existing = $matchedGroups[0]
  } elseif ($matchedGroups.Count -gt 1) {
    $ids = ($matchedGroups | ForEach-Object { "$($_.DisplayName) [$($_.Id)]" }) -join "; "
    Add-AuditControl -ControlName $controlName -MissingItems @("AmbiguousLegacyGroups") -Action "Error" -Notes "Multiple legacy candidates found: $ids"
    throw "Multiple matching legacy groups found for '$DisplayName'. Resolve manually: $ids"
  }

  if ($existing -and $existing.DisplayName -ne $DisplayName -and $RenameLegacyDisplayNameToCurrent) {
    $legacyName = $existing.DisplayName
    Write-Step "Renaming legacy group '$legacyName' to '$DisplayName'"
    if ($script:PSCmdlet.ShouldProcess("$legacyName [$($existing.Id)]", "Rename group to '$DisplayName'")) {
      Update-MgGroup -GroupId $existing.Id -DisplayName $DisplayName | Out-Null
      $existing = Get-MgGroup -GroupId $existing.Id -Property "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled"
      Add-AuditControl -ControlName "GroupRename/$DisplayName" -MissingItems @("LegacyName:$legacyName") -Action "Updated" -Notes "Legacy group renamed to standardized name."
    } else {
      Add-AuditControl -ControlName "GroupRename/$DisplayName" -MissingItems @("LegacyName:$legacyName") -Action "PlannedUpdate" -Notes "Legacy group rename planned only."
    }
  }

  if ($existing -and $PrintDynamicMembershipRule) {
    if ($existing.GroupTypes -contains "DynamicMembership") {
      $ruleText = if ([string]::IsNullOrWhiteSpace($existing.MembershipRule)) { "<empty>" } else { $existing.MembershipRule }
      Write-Step "Dynamic membership rule for '$($existing.DisplayName)' [$($existing.Id)]: $ruleText"
    } else {
      Write-Step "Group '$($existing.DisplayName)' [$($existing.Id)] is not dynamic; membership rule is not applicable."
    }
  }

  if (-not $existing) {
    Write-Step "Creating $Type group: $DisplayName"
    if ($Type -eq "Assigned") {
      if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create assigned security group")) {
        $created = New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -SecurityEnabled:$true -MailNickname ([Guid]::NewGuid().ToString("N"))
        Add-AuditControl -ControlName $controlName -MissingItems @("GroupNotFound") -Action "Created" -Notes "Assigned group created."
        return $created
      }
      Add-AuditControl -ControlName $controlName -MissingItems @("GroupNotFound") -Action "PlannedCreate" -Notes "Assigned group creation planned only."
      return New-PlaceholderObject -Data @{
        Id = $null
        DisplayName = $DisplayName
        GroupTypes = @()
        IsPlanned = $true
      }
    }

    if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create dynamic security group")) {
      try {
        $created = New-MgGroup `
          -DisplayName $DisplayName `
          -MailEnabled:$false `
          -SecurityEnabled:$true `
          -MailNickname ([Guid]::NewGuid().ToString("N")) `
          -GroupTypes @("DynamicMembership") `
          -MembershipRule $dynamicMembershipRule `
          -MembershipRuleProcessingState "On"
        Add-AuditControl -ControlName $controlName -MissingItems @("GroupNotFound") -Action "Created" -Notes "Dynamic group created."
        return $created
      } catch {
        if ($AllowAssignedFallbackIfDynamicUnavailable -and (Test-IsDynamicGroupLicenseConstraintError -ErrorObject $_)) {
          $errorText = Get-ExceptionMessageText -ErrorObject $_
          Write-Warning "Dynamic group is unavailable for '$DisplayName' (likely no Entra ID P1). Falling back to assigned group. Error: $errorText"
          $fallback = New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -SecurityEnabled:$true -MailNickname ([Guid]::NewGuid().ToString("N"))
          Add-AuditControl -ControlName $controlName -MissingItems @("DynamicMembershipUnavailable") -Action "CreatedFallbackAssigned" -Notes "Dynamic group unavailable due to licensing/capability. Assigned fallback created."
          return $fallback
        }
        throw
      }
    }

    if ($AllowAssignedFallbackIfDynamicUnavailable) {
      Add-AuditControl -ControlName $controlName -MissingItems @("GroupNotFound","DynamicMembershipUnavailable") -Action "PlannedCreateFallbackAssigned" -Notes "Assigned fallback creation planned only."
      return New-PlaceholderObject -Data @{
        Id = $null
        DisplayName = $DisplayName
        GroupTypes = @()
        IsPlanned = $true
      }
    }

    Add-AuditControl -ControlName $controlName -MissingItems @("GroupNotFound") -Action "PlannedCreate" -Notes "Dynamic group creation planned only."
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
      if ($AllowAssignedFallbackIfDynamicUnavailable) {
        Add-AuditControl -ControlName $controlName -MissingItems @("DynamicMembershipUnavailable") -Action "FallbackAssignedInUse" -Notes "Assigned group in use because dynamic groups are unavailable for this tenant."
        return $existing
      }
      Add-AuditControl -ControlName $controlName -MissingItems @("ExpectedDynamicMembership") -Action "Error" -Notes "Group exists but is assigned/static."
      throw "Group '$DisplayName' exists but is not dynamic. Convert/remove it before running bootstrap."
    }

    $missingSettings = @()
    $patch = @{}
    if ($existing.MembershipRule -ne $dynamicMembershipRule) {
      $patch["MembershipRule"] = $dynamicMembershipRule
      $missingSettings += "MembershipRule"
    }
    if ($existing.MembershipRuleProcessingState -ne "On") {
      $patch["MembershipRuleProcessingState"] = "On"
      $missingSettings += "MembershipRuleProcessingState"
    }

    if ($missingSettings.Count -gt 0) {
      if ($PreserveExistingDynamicMembershipRule) {
        Add-AuditControl -ControlName $controlName -MissingItems $missingSettings -Action "PreservedExistingRule" -Notes "Existing dynamic membership settings were not modified by policy."
      } else {
        Write-Step "Updating dynamic membership settings for $DisplayName"
        if ($script:PSCmdlet.ShouldProcess($DisplayName, "Update dynamic group membership settings")) {
          Update-MgGroup -GroupId $existing.Id @patch | Out-Null
          $updated = Get-MgGroup -GroupId $existing.Id -Property "id,displayName,groupTypes,membershipRule,membershipRuleProcessingState"
          Add-AuditControl -ControlName $controlName -MissingItems $missingSettings -Action "Updated" -Notes "Dynamic group settings remediated."
          return $updated
        }
        Add-AuditControl -ControlName $controlName -MissingItems $missingSettings -Action "PlannedUpdate" -Notes "Dynamic group settings remediation planned only."
      }
    } else {
      Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "Dynamic group already compliant."
    }
  } elseif ($existing.GroupTypes -contains "DynamicMembership") {
    Add-AuditControl -ControlName $controlName -MissingItems @("ExpectedAssignedMembership") -Action "Error" -Notes "Group exists but is dynamic."
    throw "Group '$DisplayName' exists but is dynamic. Expected assigned/static group."
  } else {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "Assigned group already compliant."
  }

  return $existing
}

function Ensure-Application {
  param([string] $DisplayName)

  $controlName = "AppRegistration/$DisplayName"
  $apps = @(Get-MgApplication -Filter "displayName eq '$($DisplayName.Replace("'","''"))'" -All -Property "id,appId,displayName,requiredResourceAccess")
  $existing = Get-SingleOrThrow -Items $apps -Description "application named $DisplayName"
  if ($existing) {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "App registration already exists."
    return $existing
  }

  Write-Step "Creating app registration: $DisplayName"
  if ($script:PSCmdlet.ShouldProcess($DisplayName, "Create app registration")) {
    $created = New-MgApplication -DisplayName $DisplayName
    Add-AuditControl -ControlName $controlName -MissingItems @("ApplicationNotFound") -Action "Created" -Notes "App registration created."
    return $created
  }
  Add-AuditControl -ControlName $controlName -MissingItems @("ApplicationNotFound") -Action "PlannedCreate" -Notes "App registration creation planned only."
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

  $controlName = "ServicePrincipal/$AppId"
  if ([string]::IsNullOrWhiteSpace($AppId)) {
    Add-AuditControl -ControlName $controlName -MissingItems @("ServicePrincipalMissingDependency:ApplicationId") -Action "SkippedMissingDependency" -Notes "Cannot resolve service principal until app exists."
    return New-PlaceholderObject -Data @{
      Id = $null
      AppId = $null
      DisplayName = "Planned ActaMSP App Service Principal"
      IsPlanned = $true
    }
  }

  $sps = @(Get-MgServicePrincipal -Filter "appId eq '$AppId'" -All -Property "id,appId,displayName")
  $existing = Get-SingleOrThrow -Items $sps -Description "service principal for appId $AppId"
  if ($existing) {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "Service principal already exists."
    return $existing
  }

  Write-Step "Creating service principal for appId $AppId"
  if ($script:PSCmdlet.ShouldProcess($AppId, "Create service principal")) {
    $created = New-MgServicePrincipal -AppId $AppId
    Add-AuditControl -ControlName $controlName -MissingItems @("ServicePrincipalNotFound") -Action "Created" -Notes "Service principal created."
    return $created
  }
  Add-AuditControl -ControlName $controlName -MissingItems @("ServicePrincipalNotFound") -Action "PlannedCreate" -Notes "Service principal creation planned only."
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

  $appName = if ([string]::IsNullOrWhiteSpace($App.DisplayName)) { "unknown" } else { $App.DisplayName }
  $controlName = "AppRegistration/$appName/RequiredResourceAccess"

  if (-not $App.Id) {
    Write-Step "Skipping Graph requiredResourceAccess update because app registration is not materialized in this run."
    $dependencyMissing = @(
      @($RequiredApplicationPerms | ForEach-Object { "ApplicationPermission:$($_)" }),
      @($RequiredDelegatedPerms | ForEach-Object { "DelegatedPermission:$($_)" })
    ) | ForEach-Object { $_ }
    Add-AuditControl -ControlName $controlName -MissingItems $dependencyMissing -Action "SkippedMissingDependency" -Notes "Cannot set requiredResourceAccess until app exists."
    return
  }

  $existing = @($App.RequiredResourceAccess)
  $currentGraph = @($existing | Where-Object { $_.ResourceAppId -eq $graphResourceAppId } | Select-Object -ExpandProperty ResourceAccess)
  $currentGraphKeys = @($currentGraph | ForEach-Object { "$($_.Type)|$($_.Id)" } | Sort-Object -Unique)

  $desiredGraphAccess = @()
  $desiredGraphKeys = @()
  $missingItems = @()

  foreach ($perm in ($RequiredApplicationPerms | Sort-Object -Unique)) {
    $roleId = Resolve-GraphAppRoleId -GraphSp $GraphSp -Value $perm
    $key = "Role|$roleId"
    $desiredGraphAccess += @{
      Id = $roleId
      Type = "Role"
    }
    $desiredGraphKeys += $key
    if ($currentGraphKeys -notcontains $key) {
      $missingItems += "ApplicationPermission:$perm"
    }
  }
  foreach ($perm in ($RequiredDelegatedPerms | Sort-Object -Unique)) {
    $scopeId = Resolve-GraphScopeId -GraphSp $GraphSp -Value $perm
    $key = "Scope|$scopeId"
    $desiredGraphAccess += @{
      Id = $scopeId
      Type = "Scope"
    }
    $desiredGraphKeys += $key
    if ($currentGraphKeys -notcontains $key) {
      $missingItems += "DelegatedPermission:$perm"
    }
  }

  $desiredGraphAccess = $desiredGraphAccess | Sort-Object @{ Expression = "Type"; Ascending = $true }, @{ Expression = "Id"; Ascending = $true } -Unique
  $nonGraphExisting = @($existing | Where-Object { $_.ResourceAppId -ne $graphResourceAppId })
  $newRequiredResourceAccess = @($nonGraphExisting + @(@{
    ResourceAppId = $graphResourceAppId
    ResourceAccess = $desiredGraphAccess
  }))

  $extraGraphKeys = @($currentGraphKeys | Where-Object { $desiredGraphKeys -notcontains $_ })
  foreach ($extra in $extraGraphKeys) {
    $missingItems += "UnexpectedGraphPermission:$extra"
  }

  $isDifferent = $missingItems.Count -gt 0
  if ($isDifferent) {
    Write-Step "Updating required Graph API permissions on app registration"
    if ($script:PSCmdlet.ShouldProcess($App.DisplayName, "Update required Graph API permissions")) {
      Update-MgApplication -ApplicationId $App.Id -RequiredResourceAccess $newRequiredResourceAccess | Out-Null
      Add-AuditControl -ControlName $controlName -MissingItems $missingItems -Action "Updated" -Notes "RequiredResourceAccess remediated to baseline."
    } else {
      Add-AuditControl -ControlName $controlName -MissingItems $missingItems -Action "PlannedUpdate" -Notes "RequiredResourceAccess remediation planned only."
    }
  } else {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "RequiredResourceAccess already compliant."
  }
}

function Ensure-ApplicationAdminConsent {
  param(
    [object] $AppServicePrincipal,
    [object] $GraphSp,
    [string[]] $RequiredApplicationPerms
  )

  $appIdText = if ([string]::IsNullOrWhiteSpace($AppServicePrincipal.AppId)) { "unknown" } else { $AppServicePrincipal.AppId }
  $controlName = "ServicePrincipal/$appIdText/ApplicationAdminConsent"

  if (-not $AppServicePrincipal.Id) {
    Write-Step "Skipping application permission consent because service principal is not materialized in this run."
    Add-AuditControl -ControlName $controlName -MissingItems (@($RequiredApplicationPerms | ForEach-Object { "ApplicationConsent:$($_)" })) -Action "SkippedMissingDependency" -Notes "Cannot grant app role consent until service principal exists."
    return
  }

  $existingAssignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AppServicePrincipal.Id -All)
  $assignmentKeys = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($assignment in $existingAssignments) {
    [void]$assignmentKeys.Add("$($assignment.ResourceId)|$($assignment.AppRoleId)")
  }

  $missingPerms = @()
  foreach ($perm in ($RequiredApplicationPerms | Sort-Object -Unique)) {
    $appRoleId = Resolve-GraphAppRoleId -GraphSp $GraphSp -Value $perm
    $key = "$($GraphSp.Id)|$appRoleId"
    if (-not $assignmentKeys.Contains($key)) {
      $missingPerms += $perm
    }
  }

  if ($missingPerms.Count -eq 0) {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "Application admin consent already compliant."
    return
  }

  $grantedAny = $false
  $plannedAny = $false

  foreach ($perm in ($RequiredApplicationPerms | Sort-Object -Unique)) {
    if ($missingPerms -notcontains $perm) { continue }
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
        $grantedAny = $true
      } else {
        $plannedAny = $true
      }
    }
  }

  $auditMissing = @($missingPerms | ForEach-Object { "ApplicationConsent:$($_)" })
  if ($grantedAny) {
    Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "Granted" -Notes "Application admin consent granted for missing permissions."
  } elseif ($plannedAny) {
    Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "PlannedGrant" -Notes "Application admin consent grant planned only."
  } else {
    Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "None" -Notes "No consent updates applied."
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
  $appIdText = if ([string]::IsNullOrWhiteSpace($AppServicePrincipal.AppId)) { "unknown" } else { $AppServicePrincipal.AppId }
  $controlName = "ServicePrincipal/$appIdText/DelegatedAdminConsent"

  if (-not $AppServicePrincipal.Id) {
    Write-Step "Skipping delegated permission consent because service principal is not materialized in this run."
    Add-AuditControl -ControlName $controlName -MissingItems (@($desiredScopes | ForEach-Object { "DelegatedConsent:$($_)" })) -Action "SkippedMissingDependency" -Notes "Cannot grant delegated consent until service principal exists."
    return $desiredScopeString
  }

  $grants = @(Get-MgOauth2PermissionGrant -Filter "clientId eq '$($AppServicePrincipal.Id)' and resourceId eq '$($GraphSp.Id)' and consentType eq 'AllPrincipals'" -All)
  if (-not $grants) {
    Write-Step "Granting delegated permission consent (AllPrincipals)"
    $auditMissing = @($desiredScopes | ForEach-Object { "DelegatedConsent:$($_)" })
    if ($script:PSCmdlet.ShouldProcess($AppServicePrincipal.AppId, "Grant delegated permission consent (AllPrincipals)")) {
      New-MgOauth2PermissionGrant `
        -ClientId $AppServicePrincipal.Id `
        -ConsentType "AllPrincipals" `
        -ResourceId $GraphSp.Id `
        -Scope $desiredScopeString | Out-Null
      Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "Granted" -Notes "Delegated consent grant created."
    } else {
      Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "PlannedGrant" -Notes "Delegated consent grant planned only."
    }
    return $desiredScopeString
  }

  $grant = Get-SingleOrThrow -Items $grants -Description "AllPrincipals OAuth2 permission grant for app service principal $($AppServicePrincipal.Id)"
  $existingScopes = @($grant.Scope -split " " | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $missingScopes = @($desiredScopes | Where-Object { $existingScopes -notcontains $_ })
  $mergedScopes = @($existingScopes + $desiredScopes | Sort-Object -Unique)
  $mergedScopeString = $mergedScopes -join " "

  if ($missingScopes.Count -eq 0) {
    Add-AuditControl -ControlName $controlName -MissingItems @() -Action "None" -Notes "Delegated admin consent already compliant."
    return $mergedScopeString
  }

  $auditMissing = @($missingScopes | ForEach-Object { "DelegatedConsent:$($_)" })
  if ($mergedScopeString -ne ($existingScopes -join " ")) {
    Write-Step "Updating delegated permission consent scopes"
    if ($script:PSCmdlet.ShouldProcess($AppServicePrincipal.AppId, "Update delegated permission consent scopes")) {
      Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope $mergedScopeString | Out-Null
      Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "Updated" -Notes "Delegated consent scopes updated."
    } else {
      Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "PlannedUpdate" -Notes "Delegated consent scope update planned only."
    }
  } else {
    Add-AuditControl -ControlName $controlName -MissingItems $auditMissing -Action "None" -Notes "Delegated consent already includes required scopes."
  }

  return $mergedScopeString
}

function Ensure-AppBaseline {
  param(
    [string] $DisplayName,
    [object] $GraphSp,
    [string[]] $RequiredApplicationPerms,
    [string[]] $RequiredDelegatedPerms
  )

  Write-Step "Ensuring app registration and service principal: $DisplayName"
  $app = Ensure-Application -DisplayName $DisplayName
  $sp = Ensure-ServicePrincipalForApp -AppId $app.AppId

  Set-ApplicationRequiredResourceAccess `
    -App $app `
    -GraphSp $GraphSp `
    -RequiredApplicationPerms $RequiredApplicationPerms `
    -RequiredDelegatedPerms $RequiredDelegatedPerms

  Ensure-ApplicationAdminConsent `
    -AppServicePrincipal $sp `
    -GraphSp $GraphSp `
    -RequiredApplicationPerms $RequiredApplicationPerms

  $delegatedScopeString = Ensure-DelegatedAdminConsent `
    -AppServicePrincipal $sp `
    -GraphSp $GraphSp `
    -RequiredDelegatedPerms $RequiredDelegatedPerms

  return [pscustomobject]@{
    DisplayName = $DisplayName
    App = $app
    ServicePrincipal = $sp
    DelegatedScopeString = $delegatedScopeString
    RequiredApplicationPerms = @($RequiredApplicationPerms | Sort-Object -Unique)
    RequiredDelegatedPerms = @($RequiredDelegatedPerms | Sort-Object -Unique)
  }
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
switch ($integrationGroupMode) {
  "Assigned" {
    $integrationGroup = Ensure-Group `
      -DisplayName $config.IntegrationGroupName `
      -Type Assigned `
      -LegacyDisplayNames $integrationGroupLegacyNames `
      -RenameLegacyDisplayNameToCurrent `
      -PrintDynamicMembershipRule
    break
  }
  "Dynamic" {
    $integrationGroup = Ensure-Group `
      -DisplayName $config.IntegrationGroupName `
      -Type Dynamic `
      -LegacyDisplayNames $integrationGroupLegacyNames `
      -RenameLegacyDisplayNameToCurrent `
      -PreserveExistingDynamicMembershipRule `
      -PrintDynamicMembershipRule
    break
  }
  default {
    $integrationGroup = Ensure-Group `
      -DisplayName $config.IntegrationGroupName `
      -Type Dynamic `
      -AllowAssignedFallbackIfDynamicUnavailable `
      -LegacyDisplayNames $integrationGroupLegacyNames `
      -RenameLegacyDisplayNameToCurrent `
      -PreserveExistingDynamicMembershipRule `
      -PrintDynamicMembershipRule
    break
  }
}
$pilotGroup = Ensure-Group -DisplayName $config.PilotGroupName -Type Assigned

Write-Step "Resolving Microsoft Graph service principal"
$graphSp = Get-SingleOrThrow -Items @(Get-MgServicePrincipal -Filter "appId eq '$graphResourceAppId'" -All -Property "id,appRoles,oauth2PermissionScopes,displayName") -Description "Microsoft Graph service principal"
if (-not $graphSp) {
  Add-AuditControl -ControlName "ServicePrincipal/MicrosoftGraphResource" -MissingItems @("GraphResourceServicePrincipalMissing") -Action "Error" -Notes "Microsoft Graph resource service principal not found."
  throw "Microsoft Graph service principal not found in tenant."
}
Add-AuditControl -ControlName "ServicePrincipal/MicrosoftGraphResource" -MissingItems @() -Action "None" -Notes "Microsoft Graph resource service principal is present."

$requiredApplicationPermsPrimary = @(
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

$requiredDelegatedPermsPrimary = @(
  "Subscription.Read.All",
  "User.Read",
  "User.Read.All",
  "User.ReadBasic.All"
)

$requiredApplicationPermsNetworkDetectivePro = @(
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
  "User.Read.All"
)

$requiredDelegatedPermsNetworkDetectivePro = @(
  "Subscription.Read.All",
  "User.ReadBasic.All"
)

$networkDetectiveProDisplayName = "Network Detective Pro"
$isPrimaryAlsoNetworkDetectivePro = $config.AppDisplayName.Trim().Equals($networkDetectiveProDisplayName, [System.StringComparison]::OrdinalIgnoreCase)

if ($isPrimaryAlsoNetworkDetectivePro) {
  Write-Step "Primary app display name matches Network Detective Pro; applying merged permission baseline once."
  $mergedApplicationPerms = @($requiredApplicationPermsPrimary + $requiredApplicationPermsNetworkDetectivePro | Sort-Object -Unique)
  $mergedDelegatedPerms = @($requiredDelegatedPermsPrimary + $requiredDelegatedPermsNetworkDetectivePro | Sort-Object -Unique)

  $primaryAppBaseline = Ensure-AppBaseline `
    -DisplayName $config.AppDisplayName `
    -GraphSp $graphSp `
    -RequiredApplicationPerms $mergedApplicationPerms `
    -RequiredDelegatedPerms $mergedDelegatedPerms

  $networkDetectiveProBaseline = $primaryAppBaseline
} else {
  $primaryAppBaseline = Ensure-AppBaseline `
    -DisplayName $config.AppDisplayName `
    -GraphSp $graphSp `
    -RequiredApplicationPerms $requiredApplicationPermsPrimary `
    -RequiredDelegatedPerms $requiredDelegatedPermsPrimary

  $networkDetectiveProBaseline = Ensure-AppBaseline `
    -DisplayName $networkDetectiveProDisplayName `
    -GraphSp $graphSp `
    -RequiredApplicationPerms $requiredApplicationPermsNetworkDetectivePro `
    -RequiredDelegatedPerms $requiredDelegatedPermsNetworkDetectivePro
}

$auditControls = @($script:AuditControls)
$auditSummary = Get-AuditSummary -Controls $auditControls
Write-AuditReport -Controls $auditControls -Summary $auditSummary

$audit = [ordered]@{
  TenantId = $tenantId
  RunStartedAt = $script:RunStartedAt
  RunCompletedAt = (Get-Date).ToString("o")
  WhatIf = [bool]$WhatIfPreference
  Summary = $auditSummary
  Controls = $auditControls
}

$auditPath = [System.IO.Path]::ChangeExtension($ConfigPath, ".audit.json")
if ($script:PSCmdlet.ShouldProcess($auditPath, "Write bootstrap audit report file")) {
  $audit | ConvertTo-Json -Depth 20 | Set-Content -Path $auditPath -Encoding UTF8
  Write-Step "Audit report saved: $auditPath"
} else {
  Write-Step "Skipped audit report write: $auditPath"
}

$state = [ordered]@{
  TenantId = $tenantId
  IntegrationGroupMode = $integrationGroupMode
  IntegrationGroupPrimaryDomain = $integrationPrimaryDomain
  IntegrationGroupIsDynamic = [bool]($integrationGroup.GroupTypes -contains "DynamicMembership")
  IntegrationGroupMembershipRule = if ($integrationGroup.GroupTypes -contains "DynamicMembership") { $integrationGroup.MembershipRule } else { $null }
  IntegrationGroupId = $integrationGroup.Id
  PilotGroupId = $pilotGroup.Id
  ApplicationObjectId = $primaryAppBaseline.App.Id
  ApplicationAppId = $primaryAppBaseline.App.AppId
  ServicePrincipalId = $primaryAppBaseline.ServicePrincipal.Id
  GraphResourceSpId = $graphSp.Id
  DelegatedScopes = $primaryAppBaseline.DelegatedScopeString
  ApplicationRoles = $primaryAppBaseline.RequiredApplicationPerms
  NetworkDetectiveProApplicationObjectId = $networkDetectiveProBaseline.App.Id
  NetworkDetectiveProApplicationAppId = $networkDetectiveProBaseline.App.AppId
  NetworkDetectiveProServicePrincipalId = $networkDetectiveProBaseline.ServicePrincipal.Id
  NetworkDetectiveProDelegatedScopes = $networkDetectiveProBaseline.DelegatedScopeString
  NetworkDetectiveProApplicationRoles = @($requiredApplicationPermsNetworkDetectivePro | Sort-Object -Unique)
  Applications = @(
    [ordered]@{
      LogicalName = "Primary"
      DisplayName = $primaryAppBaseline.DisplayName
      ApplicationObjectId = $primaryAppBaseline.App.Id
      ApplicationAppId = $primaryAppBaseline.App.AppId
      ServicePrincipalId = $primaryAppBaseline.ServicePrincipal.Id
      DelegatedScopes = $primaryAppBaseline.DelegatedScopeString
      ApplicationRoles = $primaryAppBaseline.RequiredApplicationPerms
      DelegatedPermissions = $primaryAppBaseline.RequiredDelegatedPerms
    },
    [ordered]@{
      LogicalName = "NetworkDetectivePro"
      DisplayName = $networkDetectiveProDisplayName
      ApplicationObjectId = $networkDetectiveProBaseline.App.Id
      ApplicationAppId = $networkDetectiveProBaseline.App.AppId
      ServicePrincipalId = $networkDetectiveProBaseline.ServicePrincipal.Id
      DelegatedScopes = $networkDetectiveProBaseline.DelegatedScopeString
      ApplicationRoles = @($requiredApplicationPermsNetworkDetectivePro | Sort-Object -Unique)
      DelegatedPermissions = @($requiredDelegatedPermsNetworkDetectivePro | Sort-Object -Unique)
    }
  )
  AuditReportPath = $auditPath
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
