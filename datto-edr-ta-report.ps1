[CmdletBinding()]
param(
  [string] $ApiHost,

  [string] $ApiToken,

  [string] $TokenEnvVar = "DATTO_EDR_TOKEN",

  [string] $EnvFile,

  [string] $OutputCsvPath,

  [string] $OutputPoliciesCsvPath,

  [string] $OutputPolicyAssignmentsCsvPath,

  [int] $ApiTimeoutSec = 120,

  [int] $RequestDelayMs = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:EdrApiTimeoutSec = $ApiTimeoutSec
$script:RequestDelayMs   = $RequestDelayMs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-edr-ta-report] $Message"
}

function Resolve-BaseUrl {
  param([Parameter(Mandatory)] [string] $HostName)

  $value = $HostName.Trim()
  if ($value -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://') {
    return $value.TrimEnd('/')
  }
  if ($value -match '\.') {
    return ("https://{0}" -f $value.TrimEnd('/'))
  }
  return ("https://{0}.infocyte.com" -f $value.TrimEnd('/'))
}

function ConvertTo-QueryString {
  param([Parameter(Mandatory)] [hashtable] $Parameters)

  $parts = foreach ($key in ($Parameters.Keys | Sort-Object)) {
    $val = $Parameters[$key]
    if ($null -eq $val) { continue }
    '{0}={1}' -f [System.Uri]::EscapeDataString([string]$key), [System.Uri]::EscapeDataString([string]$val)
  }
  return ($parts -join '&')
}

function Invoke-EdrApiGet {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $Endpoint,
    [hashtable] $Where = @{},
    [string[]] $Fields,
    [int] $Limit = 5000,
    [switch] $NoThrow
  )

  $relative = $Endpoint.TrimStart('/')
  $uri = "{0}/api/{1}" -f $BaseUrl, $relative

  $filter = @{ limit = $Limit; order = 'id' }
  if ($Fields -and $Fields.Count -gt 0) { $filter['fields'] = $Fields }
  if ($Where.Count -gt 0) { $filter['where'] = $Where }

  $params = @{
    access_token = $Token
    filter       = ($filter | ConvertTo-Json -Depth 10 -Compress)
  }

  $query = ConvertTo-QueryString -Parameters $params
  $fullUri = "{0}?{1}" -f $uri, $query

  if ($script:RequestDelayMs -gt 0) {
    Start-Sleep -Milliseconds $script:RequestDelayMs
  }

  $headers = @{ 'Connection' = 'close' }
  $retryDelays = @(2, 5)
  $attempt = 0

  while ($true) {
    $attempt++
    try {
      return Invoke-RestMethod -Uri $fullUri -Method GET -ContentType 'application/json' -Headers $headers -TimeoutSec $script:EdrApiTimeoutSec
    } catch {
      $msg = $_.Exception.Message
      if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
        $msg = "{0} | Response: {1}" -f $msg, $_.ErrorDetails.Message
      }

      $isTransient = $msg -match 'ResponseEnded|response ended prematurely|connection.*reset|connection.*abort|SendFailure'

      if ($isTransient -and $attempt -le $retryDelays.Count) {
        $wait = $retryDelays[$attempt - 1]
        Write-Verbose "Transient error on '/$relative' (attempt $attempt), retrying in ${wait}s: $msg"
        Start-Sleep -Seconds $wait
        continue
      }

      if ($NoThrow) {
        Write-Verbose "API call skipped for '/$relative': $msg"
        return $null
      }
      throw "API request failed for '/$relative': $msg"
    }
  }
}

function Get-EdrAll {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $Endpoint,
    [hashtable] $Where = @{},
    [string[]] $Fields,
    [int] $PageSize = 1000,
    [switch] $NoThrow
  )

  $results = [System.Collections.Generic.List[object]]::new()
  $workingWhere = @{}
  foreach ($k in $Where.Keys) { $workingWhere[$k] = $Where[$k] }

  while ($true) {
    $page = Invoke-EdrApiGet -BaseUrl $BaseUrl -Token $Token -Endpoint $Endpoint `
      -Where $workingWhere -Fields $Fields -Limit $PageSize -NoThrow:$NoThrow

    if ($null -eq $page) { return $null }

    $batch = @($page)

    foreach ($item in $batch) { $results.Add($item) | Out-Null }
    if ($batch.Count -lt $PageSize) { break }

    $lastId = $null
    try { $lastId = $batch[-1].id } catch { $lastId = $null }
    if (-not $lastId) { break }
    $workingWhere['id'] = @{ gt = $lastId }
  }

  return @($results)
}

function Get-StringProp {
  param($Obj, [string[]] $Names)
  foreach ($name in $Names) {
    $val = $null
    try { $val = $Obj.$name } catch { $val = $null }
    if ($null -ne $val) {
      $s = [string]$val
      if (-not [string]::IsNullOrWhiteSpace($s)) { return $s.Trim() }
    }
  }
  return $null
}

function Get-NumProp {
  param($Obj, [string[]] $Names)
  foreach ($name in $Names) {
    $val = $null
    try { $val = $Obj.$name } catch { $val = $null }
    if ($null -ne $val) {
      try { return [int]$val } catch { return 0 }
    }
  }
  return 0
}

function ConvertTo-CanonicalPolicyType {
  param([AllowNull()] $Value)

  if ($null -eq $Value) { return "(unknown)" }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return "(unknown)" }

  $normalized = ($text.Trim() -replace '\s+', ' ').ToLowerInvariant()
  switch -Regex ($normalized) {
    '^(datto\s+edr|endpoint\s+security|edr|general)$' { return "Datto EDR" }
    '^(datto\s+av|datto\s+antivirus|antivirus|av)$' { return "Datto AV" }
    '^(ransomware|ransomware\s+detection)$' { return "Ransomware" }
    '^(windows\s+defender|defender|microsoft\s+defender)$' { return "Windows Defender" }
    '^(automated\s+response|response)$' { return "Automated Response" }
    default { return $text.Trim() }
  }
}

function Read-EnvFile {
  param([Parameter(Mandatory)] [string] $Path)
  if (-not (Test-Path $Path)) { throw "Env file not found: $Path" }
  $vars = @{}
  foreach ($line in (Get-Content $Path)) {
    $line = $line.Trim()
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -match '^([^=]+)=(.*)$') { $vars[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  return $vars
}

function Format-Date {
  param([AllowNull()] $Value)
  if ($null -eq $Value) { return "" }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  try {
    return ([datetimeoffset]$s).ToString("yyyy-MM-dd HH:mm")
  } catch {
    return $s
  }
}

function Get-EnrollmentStatus {
  param([int] $AgentCount, [int] $ActiveAgentCount)
  if ($AgentCount -eq 0) { return "Not Enrolled" }
  if ($ActiveAgentCount -eq 0) { return "Enrolled - No Active Agents" }
  return "Enrolled"
}

function ConvertTo-Array {
  param([AllowNull()] $InputObject)

  if ($null -eq $InputObject) {
    return @()
  }

  if ($InputObject -is [string]) {
    return @($InputObject)
  }

  if ($InputObject -is [System.Collections.IEnumerable]) {
    return @($InputObject)
  }

  return @($InputObject)
}

function ConvertTo-PlainData {
  param([AllowNull()] $InputObject)

  if ($null -eq $InputObject) {
    return $null
  }

  if ($InputObject -is [string] -or
      $InputObject -is [ValueType] -or
      $InputObject -is [datetime] -or
      $InputObject -is [datetimeoffset]) {
    return $InputObject
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $InputObject.Keys) {
      $copy[[string]$key] = ConvertTo-PlainData -InputObject $InputObject[$key]
    }
    return $copy
  }

  if ($InputObject -is [System.Collections.IEnumerable]) {
    $items = @()
    foreach ($item in $InputObject) {
      $items += @(ConvertTo-PlainData -InputObject $item)
    }
    return $items
  }

  $props = @{}
  foreach ($prop in $InputObject.PSObject.Properties) {
    if ($prop.MemberType -in @("NoteProperty", "Property", "AliasProperty", "ScriptProperty")) {
      $props[$prop.Name] = ConvertTo-PlainData -InputObject $prop.Value
    }
  }

  if ($props.Count -gt 0) {
    return $props
  }

  return $InputObject
}

function Get-PathValue {
  param(
    [AllowNull()] $InputObject,
    [Parameter(Mandatory)] [string] $Path
  )

  if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $segments = $Path.Split('.')
  $current = $InputObject

  foreach ($segment in $segments) {
    if ($null -eq $current) {
      return $null
    }

    if ($current -is [System.Collections.IDictionary]) {
      $found = $false
      foreach ($key in $current.Keys) {
        if ([string]::Equals([string]$key, $segment, [System.StringComparison]::OrdinalIgnoreCase)) {
          $current = $current[$key]
          $found = $true
          break
        }
      }

      if (-not $found) {
        return $null
      }

      continue
    }

    $prop = $current.PSObject.Properties | Where-Object {
      [string]::Equals($_.Name, $segment, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1

    if (-not $prop) {
      return $null
    }

    $current = $prop.Value
  }

  return $current
}

function Get-FirstValue {
  param(
    [AllowNull()] $InputObject,
    [Parameter(Mandatory)] [string[]] $PropertyPaths
  )

  foreach ($path in $PropertyPaths) {
    $value = Get-PathValue -InputObject $InputObject -Path $path
    if ($null -ne $value) {
      if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        continue
      }
      return $value
    }
  }

  return $null
}

function Get-StringValue {
  param(
    [AllowNull()] $InputObject,
    [Parameter(Mandatory)] [string[]] $PropertyPaths
  )

  $value = Get-FirstValue -InputObject $InputObject -PropertyPaths $PropertyPaths
  if ($null -eq $value) {
    return $null
  }

  $text = [string]$value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  return $text.Trim()
}

function ConvertTo-BooleanOrNull {
  param([AllowNull()] $Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [bool]) {
    return [bool]$Value
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  switch -Regex ($text.Trim().ToLowerInvariant()) {
    '^(true|enabled|enable|yes|y|1|active|on)$' { return $true }
    '^(false|disabled|disable|no|n|0|inactive|off)$' { return $false }
    default { return $null }
  }
}

function ConvertTo-DateString {
  param([AllowNull()] $Value)

  if ($null -eq $Value) {
    return $null
  }

  try {
    return ([datetimeoffset]$Value).ToString("o")
  } catch {
    try {
      return ([datetime]$Value).ToString("o")
    } catch {
      return [string]$Value
    }
  }
}

function Get-PolicyTypeFromName {
  param([AllowNull()] [string] $Name)

  if ([string]::IsNullOrWhiteSpace($Name)) {
    return $null
  }

  $text = $Name.Trim().ToLowerInvariant()
  if ($text -match 'datto\s+edr|endpoint\s+security') { return "Datto EDR" }
  if ($text -match 'datto\s+av|antivirus') { return "Datto AV" }
  if ($text -match 'ransomware') { return "Ransomware" }
  if ($text -match 'windows\s+defender|microsoft\s+defender|defender') { return "Windows Defender" }
  if ($text -match 'automated\s+response') { return "Automated Response" }
  return $null
}

function Get-SettingsCandidate {
  param(
    [AllowNull()] $InputObject,
    [Parameter(Mandatory)] [string[]] $PropertyNames
  )

  foreach ($property in $PropertyNames) {
    $value = Get-PathValue -InputObject $InputObject -Path $property
    if ($null -ne $value) {
      return (ConvertTo-PlainData -InputObject $value)
    }
  }

  return (ConvertTo-PlainData -InputObject $InputObject)
}

function Get-DefaultDiscoveryConfig {
  return [ordered]@{
    PoliciesEndpointCandidates       = @("policies", "Policies", "namedPolicies", "NamedPolicies")
    OrganizationsEndpointCandidates  = @("organizations", "Organizations", "orgs", "companies", "Companies")
    LocationsEndpointCandidates      = @("targets", "Targets", "targetgroups", "locations", "Locations")
    AssignmentsEndpointCandidates    = @(
      "policyAssignments",
      "PolicyAssignments",
      "organizationPolicyAssignments",
      "OrganizationPolicyAssignments",
      "targetPolicyAssignments",
      "TargetPolicyAssignments"
    )
    OrganizationRelationEndpointCandidates = @("Organizations", "organizations", "OrganizationDetails")
    LocationRelationEndpointCandidates     = @("Locations", "locations", "LocationDetails", "Targets", "targets")
    DeviceGroupsEndpointCandidates         = @("deviceGroups", "DeviceGroups", "devicegroups")
    PolicyFields                     = @("id", "name", "type", "policyType", "enabled", "isEnabled", "status", "description", "settings", "configuration", "updatedOn", "updatedAt")
    OrganizationFields               = @("id", "name", "displayName", "assignedPolicies", "policies", "locations")
    LocationFields                   = @("id", "name", "displayName", "organizationId", "orgId", "companyId", "organization", "policies", "assignedPolicies")
    DeviceGroupFields                = @("id", "name", "description", "deviceType", "createdOn")
    AssignmentFields                 = @("id", "policyId", "policyName", "policyType", "type", "organizationId", "targetId", "locationId", "scopeType", "scopeId", "enabled", "status", "updatedOn", "updatedAt")
    OrganizationAssignmentProperties = @("assignedPolicies", "policyAssignments", "policies")
    LocationAssignmentProperties     = @("assignedPolicies", "policyAssignments", "policies")
    PolicyOrganizationProperties     = @("organizations", "assignedOrganizations", "orgs")
    PolicyLocationProperties         = @("targets", "targetGroups", "locations", "assignedTargets")
    PolicySettingsProperties         = @("settings", "configuration", "config", "options", "policy", "definition", "template")
  }
}

function Get-EndpointData {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string[]] $Candidates,
    [string[]] $Fields,
    [switch] $CollectAll
  )

  $selected = [System.Collections.Generic.List[string]]::new()
  $items = [System.Collections.Generic.List[object]]::new()

  foreach ($candidate in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    try {
      $data = Get-EdrAll -BaseUrl $BaseUrl -Token $Token -Endpoint $candidate -Fields $Fields -NoThrow
      if ($null -eq $data) {
        continue
      }

      $selected.Add($candidate) | Out-Null
      foreach ($item in @($data)) {
        $items.Add($item) | Out-Null
      }

      if (-not $CollectAll) {
        break
      }
    } catch {
      continue
    }
  }

  return [pscustomobject]@{
    SelectedEndpoints = @($selected)
    Items             = @($items)
  }
}

function Normalize-PolicyRecord {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] [hashtable] $Discovery
  )

  $name = Get-StringValue -InputObject $Record -PropertyPaths @("name", "displayName", "policy.name", "policyName")
  $typeValue = Get-FirstValue -InputObject $Record -PropertyPaths @("policyType", "type", "category", "templateType", "policy.type")
  $type = $null
  if ($null -ne $typeValue -and -not [string]::IsNullOrWhiteSpace([string]$typeValue)) {
    $type = ConvertTo-CanonicalPolicyType -Value $typeValue
  }
  if (-not $type -or $type -eq "(unknown)") {
    $type = Get-PolicyTypeFromName -Name $name
  }
  if (-not $type) {
    $type = "(unknown)"
  }

  [pscustomobject][ordered]@{
    Id             = Get-StringValue -InputObject $Record -PropertyPaths @("id", "policyId", "policy.id")
    Name           = $name
    PolicyType     = $type
    Enabled        = ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("enabled", "isEnabled", "status", "state"))
    Description    = Get-StringValue -InputObject $Record -PropertyPaths @("description", "summary")
    UpdatedOn      = ConvertTo-DateString -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("updatedOn", "updatedAt", "modifiedOn"))
    Settings       = Get-SettingsCandidate -InputObject $Record -PropertyNames $Discovery.PolicySettingsProperties
    Raw            = ConvertTo-PlainData -InputObject $Record
    EvidenceSource = "API"
  }
}

function Normalize-OrganizationRecord {
  param([Parameter(Mandatory)] $Record)

  [pscustomobject][ordered]@{
    Id             = Get-StringValue -InputObject $Record -PropertyPaths @("id", "organizationId", "orgId", "companyId")
    Name           = Get-StringValue -InputObject $Record -PropertyPaths @("name", "displayName", "companyName")
    Raw            = ConvertTo-PlainData -InputObject $Record
    EvidenceSource = "API"
  }
}

function Normalize-LocationRecord {
  param([Parameter(Mandatory)] $Record)

  [pscustomobject][ordered]@{
    Id               = Get-StringValue -InputObject $Record -PropertyPaths @("id", "targetId", "locationId")
    Name             = Get-StringValue -InputObject $Record -PropertyPaths @("name", "displayName", "targetName", "locationName")
    OrganizationId   = Get-StringValue -InputObject $Record -PropertyPaths @("organizationId", "orgId", "companyId", "organization.id", "org.id", "company.id")
    OrganizationName = Get-StringValue -InputObject $Record -PropertyPaths @("organizationName", "orgName", "companyName", "organization.name", "org.name", "company.name")
    Raw              = ConvertTo-PlainData -InputObject $Record
    EvidenceSource   = "API"
  }
}

function Normalize-DeviceGroupRecord {
  param([Parameter(Mandatory)] $Record)

  [pscustomobject][ordered]@{
    Id             = Get-StringValue -InputObject $Record -PropertyPaths @("id", "deviceGroupId", "groupId")
    Name           = Get-StringValue -InputObject $Record -PropertyPaths @("name", "displayName", "groupName", "deviceGroupName")
    Raw            = ConvertTo-PlainData -InputObject $Record
    EvidenceSource = "API"
  }
}

function New-NormalizedAssignment {
  param(
    [AllowNull()] [string] $AssignmentId,
    [AllowNull()] [string] $PolicyId,
    [AllowNull()] [string] $PolicyName,
    [AllowNull()] [string] $PolicyType,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [AllowNull()] [string] $ScopeId,
    [AllowNull()] [string] $ScopeName,
    [AllowNull()] [Nullable[bool]] $Enabled,
    [AllowNull()] [Nullable[bool]] $PolicyIsDefault,
    [AllowNull()] [string] $DeviceGroupId,
    [AllowNull()] [string] $DeviceGroupName,
    [AllowNull()] [string] $AssignedTo,
    [AllowNull()] [Nullable[bool]] $IsOverride,
    [AllowNull()] $Settings,
    [AllowNull()] [string] $UpdatedOn,
    [Parameter(Mandatory)] [string] $EvidenceSource,
    [AllowNull()] $Raw
  )

  [pscustomobject][ordered]@{
    AssignmentId   = $AssignmentId
    PolicyId       = $PolicyId
    PolicyName     = $PolicyName
    PolicyType     = if ($PolicyType) { $PolicyType } else { "(unknown)" }
    ScopeType      = $ScopeType
    ScopeId        = $ScopeId
    ScopeName      = $ScopeName
    Enabled        = $Enabled
    PolicyIsDefault = $PolicyIsDefault
    DeviceGroupId   = $DeviceGroupId
    DeviceGroupName = $DeviceGroupName
    AssignedTo      = $AssignedTo
    IsOverride      = $IsOverride
    Settings       = $Settings
    UpdatedOn      = $UpdatedOn
    EvidenceSource = $EvidenceSource
    Raw            = $Raw
  }
}

function Normalize-AssignmentRecord {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Organizations,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Locations
  )

  $policyId = Get-StringValue -InputObject $Record -PropertyPaths @("policyId", "policy.id", "namedPolicyId")
  $policyName = Get-StringValue -InputObject $Record -PropertyPaths @("policyName", "policy.name", "name")
  $typeValue = Get-FirstValue -InputObject $Record -PropertyPaths @("policyType", "type", "policy.type", "policy.policyType")
  $policyType = $null
  if ($null -ne $typeValue -and -not [string]::IsNullOrWhiteSpace([string]$typeValue)) {
    $policyType = ConvertTo-CanonicalPolicyType -Value $typeValue
  }

  $organizationId = Get-StringValue -InputObject $Record -PropertyPaths @("organizationId", "orgId", "companyId", "organization.id")
  $locationId = Get-StringValue -InputObject $Record -PropertyPaths @("targetId", "locationId", "targetGroupId", "location.id", "target.id")
  $scopeType = Get-StringValue -InputObject $Record -PropertyPaths @("scopeType")
  $scopeName = $null

  if ($locationId) {
    $scopeType = "Location"
    $scopeName = Get-StringValue -InputObject $Record -PropertyPaths @("locationName", "targetName", "location.name", "target.name")
  } elseif ($organizationId) {
    $scopeType = "Organization"
    $scopeName = Get-StringValue -InputObject $Record -PropertyPaths @("organizationName", "companyName", "organization.name")
  }

  if (-not $scopeType) {
    return $null
  }

  if ($policyId -or $policyName) {
    $policy = @($Policies | Where-Object {
      ($policyId -and $_.Id -and $_.Id -eq $policyId) -or
      ($policyName -and $_.Name -and $_.Name -ieq $policyName)
    } | Select-Object -First 1)

    if ($policy.Count -gt 0) {
      if (-not $policyName) { $policyName = $policy[0].Name }
      if (-not $policyId) { $policyId = $policy[0].Id }
      if ((-not $policyType -or $policyType -eq "(unknown)") -and $policy[0].PolicyType) {
        $policyType = $policy[0].PolicyType
      }
    }
  }

  if (-not $policyType -or $policyType -eq "(unknown)") {
    $policyType = Get-PolicyTypeFromName -Name $policyName
  }
  if (-not $policyType) {
    $policyType = "(unknown)"
  }

  if ($scopeType -eq "Organization" -and -not $scopeName -and $organizationId) {
    $scopeName = @($Organizations | Where-Object { $_.Id -eq $organizationId } | Select-Object -First 1).Name
  }
  if ($scopeType -eq "Location" -and -not $scopeName -and $locationId) {
    $scopeName = @($Locations | Where-Object { $_.Id -eq $locationId } | Select-Object -First 1).Name
  }

  $resolvedScopeId = if ($scopeType -eq "Location") { $locationId } else { $organizationId }

  return (New-NormalizedAssignment `
    -AssignmentId (Get-StringValue -InputObject $Record -PropertyPaths @("id", "assignmentId")) `
    -PolicyId $policyId `
    -PolicyName $policyName `
    -PolicyType $policyType `
    -ScopeType $scopeType `
    -ScopeId $resolvedScopeId `
    -ScopeName $scopeName `
    -Enabled (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("enabled", "isEnabled", "status"))) `
    -PolicyIsDefault (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("policyIsDefault", "isDefault", "policy.isDefault"))) `
    -DeviceGroupId (Get-StringValue -InputObject $Record -PropertyPaths @("deviceGroupId", "deviceGroup.id", "groupId")) `
    -DeviceGroupName (Get-StringValue -InputObject $Record -PropertyPaths @("deviceGroupName", "deviceGroup.name", "groupName")) `
    -AssignedTo (Get-StringValue -InputObject $Record -PropertyPaths @("assignedTo", "assignmentScope")) `
    -IsOverride (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("isOverride", "override"))) `
    -Settings (Get-SettingsCandidate -InputObject $Record -PropertyNames @("settings", "configuration", "policy", "assignment")) `
    -UpdatedOn (ConvertTo-DateString -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("updatedOn", "updatedAt", "modifiedOn"))) `
    -EvidenceSource "API" `
    -Raw (ConvertTo-PlainData -InputObject $Record)
  )
}

function Test-LocationRelationOverrideRecord {
  param([Parameter(Mandatory)] $Record)

  $isOverride = ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("isOverride"))
  if ($isOverride -eq $true) {
    return $true
  }

  $assignedTo = Get-StringValue -InputObject $Record -PropertyPaths @("assignedTo")
  if (-not [string]::IsNullOrWhiteSpace($assignedTo)) {
    $normalizedAssignedTo = $assignedTo.Trim().ToUpperInvariant()
    if ($normalizedAssignedTo -notin @("ORG", "ORGANIZATION")) {
      return $true
    }
  }

  $policyId = Get-StringValue -InputObject $Record -PropertyPaths @("policyId", "policy.id")
  $policyName = Get-StringValue -InputObject $Record -PropertyPaths @("policyName", "policy.name", "name")
  $organizationPolicyId = Get-StringValue -InputObject $Record -PropertyPaths @("organizationPolicyId")
  $organizationPolicyName = Get-StringValue -InputObject $Record -PropertyPaths @("organizationPolicyName")

  if (($organizationPolicyId -and $policyId -and $organizationPolicyId -ne $policyId) -or
      ($organizationPolicyName -and $policyName -and $organizationPolicyName -ine $policyName)) {
    return $true
  }

  return $false
}

function Normalize-RelationAssignmentRecord {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [Parameter(Mandatory)] $ScopeObject,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
    [Parameter(Mandatory)] [string] $EvidenceSource
  )

  if ($ScopeType -eq "Location" -and -not (Test-LocationRelationOverrideRecord -Record $Record)) {
    return $null
  }

  $policyId = Get-StringValue -InputObject $Record -PropertyPaths @("policyId", "policy.id", "namedPolicyId", "organizationPolicyId")
  $policyName = Get-StringValue -InputObject $Record -PropertyPaths @("policyName", "policy.name", "name", "organizationPolicyName")
  $typeValue = Get-FirstValue -InputObject $Record -PropertyPaths @("policyType", "type", "policy.type")
  $policyType = $null
  if ($null -ne $typeValue -and -not [string]::IsNullOrWhiteSpace([string]$typeValue)) {
    $policyType = ConvertTo-CanonicalPolicyType -Value $typeValue
  }

  $policy = Find-PolicyRecord -Policies $Policies -PolicyId $policyId -PolicyName $policyName
  if ($null -ne $policy) {
    if (-not $policyId) { $policyId = $policy.Id }
    if (-not $policyName) { $policyName = $policy.Name }
    if ((-not $policyType -or $policyType -eq "(unknown)") -and $policy.PolicyType) {
      $policyType = $policy.PolicyType
    }
  }

  if (-not $policyType -or $policyType -eq "(unknown)") {
    $policyType = Get-PolicyTypeFromName -Name $policyName
  }
  if (-not $policyType) {
    $policyType = "(unknown)"
  }

  return (New-NormalizedAssignment `
    -AssignmentId (Get-StringValue -InputObject $Record -PropertyPaths @("policyAssignmentId", "assignmentId", "id")) `
    -PolicyId $policyId `
    -PolicyName $policyName `
    -PolicyType $policyType `
    -ScopeType $ScopeType `
    -ScopeId $ScopeObject.Id `
    -ScopeName $ScopeObject.Name `
    -Enabled (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("active", "enabled", "isEnabled", "status", "policyActive"))) `
    -PolicyIsDefault (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("policyIsDefault", "isDefault", "policy.isDefault"))) `
    -DeviceGroupId (Get-StringValue -InputObject $Record -PropertyPaths @("deviceGroupId", "deviceGroup.id", "groupId")) `
    -DeviceGroupName (Get-StringValue -InputObject $Record -PropertyPaths @("deviceGroupName", "deviceGroup.name", "groupName")) `
    -AssignedTo (Get-StringValue -InputObject $Record -PropertyPaths @("assignedTo", "assignmentScope")) `
    -IsOverride (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("isOverride", "override"))) `
    -Settings (Get-SettingsCandidate -InputObject $Record -PropertyNames @("settings", "configuration", "policy", "data")) `
    -UpdatedOn (Get-LatestDateValue -Values @(
      (Get-FirstValue -InputObject $Record -PropertyPaths @("policyUpdatedOn")),
      (Get-FirstValue -InputObject $Record -PropertyPaths @("assignedOn", "updatedOn", "updatedAt", "modifiedOn"))
    )) `
    -EvidenceSource $EvidenceSource `
    -Raw (ConvertTo-PlainData -InputObject $Record)
  )
}

function Get-ScopedRelationAssignments {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ScopeObjects,
    [Parameter(Mandatory)] [string[]] $CollectionCandidates,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies
  )

  $sampleScope = @($ScopeObjects | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Id) } | Select-Object -First 1)
  if ($sampleScope.Count -eq 0) {
    return [pscustomobject]@{
      SelectedEndpoint = $null
      Assignments      = @()
    }
  }

  $selectedEndpoint = $null
  foreach ($candidate in $CollectionCandidates) {
    $probeEndpoint = "{0}/{1}/policyAssignments" -f $candidate, $sampleScope[0].Id
    $probeData = Get-EdrAll -BaseUrl $BaseUrl -Token $Token -Endpoint $probeEndpoint -NoThrow
    if ($null -ne $probeData) {
      $selectedEndpoint = $candidate
      break
    }
  }

  if (-not $selectedEndpoint) {
    return [pscustomobject]@{
      SelectedEndpoint = $null
      Assignments      = @()
    }
  }

  $assignments = [System.Collections.Generic.List[object]]::new()
  foreach ($scope in $ScopeObjects) {
    if ([string]::IsNullOrWhiteSpace([string]$scope.Id)) {
      continue
    }

    $endpoint = "{0}/{1}/policyAssignments" -f $selectedEndpoint, $scope.Id
    $records = Get-EdrAll -BaseUrl $BaseUrl -Token $Token -Endpoint $endpoint -NoThrow
    if ($null -eq $records) {
      continue
    }

    foreach ($record in @($records)) {
      $normalized = Normalize-RelationAssignmentRecord `
        -Record $record `
        -ScopeType $ScopeType `
        -ScopeObject $scope `
        -Policies $Policies `
        -EvidenceSource ("API:{0}/policyAssignments" -f $selectedEndpoint)

      if ($null -ne $normalized) {
        $assignments.Add($normalized) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    SelectedEndpoint = $selectedEndpoint
    Assignments      = @($assignments)
  }
}

function Get-EmbeddedAssignmentsFromScopes {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ScopeObjects,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [Parameter(Mandatory)] [string[]] $PropertyCandidates
  )

  $assignments = [System.Collections.Generic.List[object]]::new()

  foreach ($scope in $ScopeObjects) {
    foreach ($propertyName in $PropertyCandidates) {
      $list = Get-PathValue -InputObject $scope.Raw -Path $propertyName
      foreach ($item in (ConvertTo-Array -InputObject $list)) {
        if ($null -eq $item) {
          continue
        }

        $policyName = Get-StringValue -InputObject $item -PropertyPaths @("name", "displayName", "policyName", "policy.name")
        $typeValue = Get-FirstValue -InputObject $item -PropertyPaths @("policyType", "type", "policyTypeName", "policy.type")
        $policyType = $null
        if ($null -ne $typeValue -and -not [string]::IsNullOrWhiteSpace([string]$typeValue)) {
          $policyType = ConvertTo-CanonicalPolicyType -Value $typeValue
        }
        if (-not $policyType -or $policyType -eq "(unknown)") {
          $policyType = Get-PolicyTypeFromName -Name $policyName
        }
        if (-not $policyType) {
          $policyType = "(unknown)"
        }

        if (-not $policyName -and $policyType -eq "(unknown)") {
          continue
        }

        $assignments.Add((New-NormalizedAssignment `
          -AssignmentId $null `
          -PolicyId (Get-StringValue -InputObject $item -PropertyPaths @("id", "policyId", "policy.id")) `
          -PolicyName $policyName `
          -PolicyType $policyType `
          -ScopeType $ScopeType `
          -ScopeId $scope.Id `
          -ScopeName $scope.Name `
          -Enabled (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $item -PropertyPaths @("enabled", "isEnabled", "status"))) `
          -Settings (Get-SettingsCandidate -InputObject $item -PropertyNames @("settings", "configuration", "policy")) `
          -UpdatedOn (ConvertTo-DateString -Value (Get-FirstValue -InputObject $item -PropertyPaths @("updatedOn", "updatedAt"))) `
          -EvidenceSource ("API:{0}" -f $propertyName) `
          -Raw (ConvertTo-PlainData -InputObject $item)
        )) | Out-Null
      }
    }
  }

  return @($assignments)
}

function Get-EmbeddedAssignmentsFromPolicies {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
    [Parameter(Mandatory)] [string[]] $OrganizationProperties,
    [Parameter(Mandatory)] [string[]] $LocationProperties
  )

  $assignments = [System.Collections.Generic.List[object]]::new()

  foreach ($policy in $Policies) {
    foreach ($propertyName in $OrganizationProperties) {
      foreach ($item in (ConvertTo-Array -InputObject (Get-PathValue -InputObject $policy.Raw -Path $propertyName))) {
        $scopeId = Get-StringValue -InputObject $item -PropertyPaths @("id", "organizationId", "orgId", "companyId")
        $scopeName = Get-StringValue -InputObject $item -PropertyPaths @("name", "displayName", "companyName")
        if ($scopeId -or $scopeName) {
          $assignments.Add((New-NormalizedAssignment `
            -AssignmentId $null `
            -PolicyId $policy.Id `
            -PolicyName $policy.Name `
            -PolicyType $policy.PolicyType `
            -ScopeType "Organization" `
            -ScopeId $scopeId `
            -ScopeName $scopeName `
            -Enabled $policy.Enabled `
            -Settings $policy.Settings `
            -UpdatedOn $policy.UpdatedOn `
            -EvidenceSource ("API:{0}" -f $propertyName) `
            -Raw (ConvertTo-PlainData -InputObject $item)
          )) | Out-Null
        }
      }
    }

    foreach ($propertyName in $LocationProperties) {
      foreach ($item in (ConvertTo-Array -InputObject (Get-PathValue -InputObject $policy.Raw -Path $propertyName))) {
        $scopeId = Get-StringValue -InputObject $item -PropertyPaths @("id", "targetId", "locationId")
        $scopeName = Get-StringValue -InputObject $item -PropertyPaths @("name", "displayName", "targetName", "locationName")
        if ($scopeId -or $scopeName) {
          $assignments.Add((New-NormalizedAssignment `
            -AssignmentId $null `
            -PolicyId $policy.Id `
            -PolicyName $policy.Name `
            -PolicyType $policy.PolicyType `
            -ScopeType "Location" `
            -ScopeId $scopeId `
            -ScopeName $scopeName `
            -Enabled $policy.Enabled `
            -Settings $policy.Settings `
            -UpdatedOn $policy.UpdatedOn `
            -EvidenceSource ("API:{0}" -f $propertyName) `
            -Raw (ConvertTo-PlainData -InputObject $item)
          )) | Out-Null
        }
      }
    }
  }

  return @($assignments)
}

function Resolve-LocationOrganizationLinks {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Organizations,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Locations
  )

  foreach ($location in $Locations) {
    if ($location.OrganizationId -or $location.OrganizationName) {
      continue
    }

    foreach ($organization in $Organizations) {
      foreach ($child in (ConvertTo-Array -InputObject (Get-FirstValue -InputObject $organization.Raw -PropertyPaths @("locations", "targets", "locationIds", "targetIds")))) {
        $childId = if ($child -is [ValueType] -or $child -is [string]) { [string]$child } else { Get-StringValue -InputObject $child -PropertyPaths @("id", "targetId", "locationId") }
        $childName = if ($child -is [ValueType] -or $child -is [string]) { $null } else { Get-StringValue -InputObject $child -PropertyPaths @("name", "displayName", "targetName", "locationName") }

        if (($childId -and $location.Id -eq $childId) -or ($childName -and $location.Name -and $location.Name -ieq $childName)) {
          $location.OrganizationId = $organization.Id
          $location.OrganizationName = $organization.Name
          break
        }
      }

      if ($location.OrganizationId -or $location.OrganizationName) {
        break
      }
    }
  }
}

function Remove-DuplicateAssignments {
  param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments)

  $seen = @{}
  $result = [System.Collections.Generic.List[object]]::new()

  foreach ($assignment in $Assignments) {
    $key = "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}" -f `
      ([string]$assignment.ScopeType), `
      ([string]$assignment.ScopeId), `
      ([string]$assignment.ScopeName), `
      ([string]$assignment.PolicyType), `
      ([string]$assignment.PolicyId), `
      ([string]$assignment.PolicyName), `
      ([string]$assignment.AssignmentId), `
      ([string]$assignment.DeviceGroupId), `
      ([string]$assignment.DeviceGroupName), `
      ([string]$assignment.AssignedTo), `
      ([string]$assignment.IsOverride)

    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $result.Add($assignment) | Out-Null
    }
  }

  return @($result)
}

function Resolve-AssignmentDeviceGroupNames {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $DeviceGroups
  )

  $deviceGroupNamesById = @{}
  foreach ($deviceGroup in $DeviceGroups) {
    if (-not [string]::IsNullOrWhiteSpace([string]$deviceGroup.Id) -and
        -not [string]::IsNullOrWhiteSpace([string]$deviceGroup.Name) -and
        -not $deviceGroupNamesById.ContainsKey($deviceGroup.Id)) {
      $deviceGroupNamesById[$deviceGroup.Id] = $deviceGroup.Name
    }
  }

  foreach ($assignment in $Assignments) {
    if ([string]::IsNullOrWhiteSpace([string]$assignment.DeviceGroupId) -or
        -not [string]::IsNullOrWhiteSpace([string]$assignment.DeviceGroupName)) {
      continue
    }

    if ($deviceGroupNamesById.ContainsKey($assignment.DeviceGroupId)) {
      $assignment.DeviceGroupName = $deviceGroupNamesById[$assignment.DeviceGroupId]
    }
  }
}

function Get-ReportScopes {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Organizations,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Locations
  )

  $scopes = [System.Collections.Generic.List[object]]::new()

  foreach ($location in $Locations) {
    $organization = @($Organizations | Where-Object {
      ($location.OrganizationId -and $_.Id -eq $location.OrganizationId) -or
      ($location.OrganizationName -and $_.Name -and $_.Name -ieq $location.OrganizationName)
    } | Select-Object -First 1)

    $organizationId = if ($organization.Count -gt 0) { $organization[0].Id } else { $location.OrganizationId }
    $organizationName = if ($organization.Count -gt 0) { $organization[0].Name } else { $location.OrganizationName }
    $locationName = if ($location.Name) { $location.Name } elseif ($location.Id) { $location.Id } else { "" }

    $scopes.Add([pscustomobject][ordered]@{
      OrganizationId    = if ($organizationId) { $organizationId } else { "" }
      OrganizationName  = if ($organizationName) { $organizationName } elseif ($organizationId) { $organizationId } else { "(unresolved)" }
      LocationId        = if ($location.Id) { $location.Id } else { "" }
      LocationName      = $locationName
      HasLocationRecord = $true
    }) | Out-Null
  }

  foreach ($organization in $Organizations) {
    $hasLocation = @($Locations | Where-Object {
      ($organization.Id -and $_.OrganizationId -and $_.OrganizationId -eq $organization.Id) -or
      ($organization.Name -and $_.OrganizationName -and $_.OrganizationName -ieq $organization.Name)
    }).Count -gt 0

    if (-not $hasLocation) {
      $scopes.Add([pscustomobject][ordered]@{
        OrganizationId    = if ($organization.Id) { $organization.Id } else { "" }
        OrganizationName  = if ($organization.Name) { $organization.Name } elseif ($organization.Id) { $organization.Id } else { "(unresolved)" }
        LocationId        = ""
        LocationName      = "(no location record)"
        HasLocationRecord = $false
      }) | Out-Null
    }
  }

  return @($scopes)
}

function Get-UniquePolicyTypes {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments
  )

  $types = [System.Collections.Generic.List[string]]::new()

  foreach ($policy in $Policies) {
    $text = [string]$policy.PolicyType
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $types.Add($text.Trim()) | Out-Null
    }
  }

  foreach ($assignment in $Assignments) {
    $text = [string]$assignment.PolicyType
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $types.Add($text.Trim()) | Out-Null
    }
  }

  return @($types | Sort-Object -Unique)
}

function Join-UniqueValues {
  param([AllowNull()] [object[]] $Values)

  $seen = @{}
  $result = [System.Collections.Generic.List[string]]::new()

  foreach ($value in @($Values)) {
    if ($null -eq $value) {
      continue
    }

    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) {
      continue
    }

    $trimmed = $text.Trim()
    $key = $trimmed.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      continue
    }

    $seen[$key] = $true
    $result.Add($trimmed) | Out-Null
  }

  return ($result -join '; ')
}

function Get-AssignmentIdentityKey {
  param([Parameter(Mandatory)] $Assignment)

  $policyId = [string]$Assignment.PolicyId
  $policyName = [string]$Assignment.PolicyName
  $assignmentId = [string]$Assignment.AssignmentId

  if (-not [string]::IsNullOrWhiteSpace($policyId) -or -not [string]::IsNullOrWhiteSpace($policyName)) {
    return "{0}|{1}" -f $policyId.Trim().ToLowerInvariant(), $policyName.Trim().ToLowerInvariant()
  }

  if (-not [string]::IsNullOrWhiteSpace($assignmentId)) {
    return $assignmentId.Trim().ToLowerInvariant()
  }

  return "{0}|{1}" -f ([string]$Assignment.ScopeType).Trim().ToLowerInvariant(), ([string]$Assignment.EvidenceSource).Trim().ToLowerInvariant()
}

function Get-DistinctAssignments {
  param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments)

  $seen = @{}
  $result = [System.Collections.Generic.List[object]]::new()

  foreach ($assignment in $Assignments) {
    $key = Get-AssignmentIdentityKey -Assignment $assignment
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $result.Add($assignment) | Out-Null
    }
  }

  return @($result)
}

function Select-AssignmentsForScope {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [string] $ScopeId,
    [string] $ScopeName,
    [Parameter(Mandatory)] [string] $PolicyType
  )

  return @(
    $Assignments | Where-Object {
      $_.PolicyType -eq $PolicyType -and
      $_.ScopeType -eq $ScopeType -and (
        ($ScopeId -and $_.ScopeId -and $_.ScopeId -eq $ScopeId) -or
        ($ScopeName -and $_.ScopeName -and $_.ScopeName -ieq $ScopeName)
      )
    }
  )
}

function Get-LatestDateValue {
  param([AllowNull()] [object[]] $Values)

  $latest = $null
  $fallback = $null

  foreach ($value in @($Values)) {
    if ($null -eq $value) {
      continue
    }

    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) {
      continue
    }

    if (-not $fallback) {
      $fallback = $text.Trim()
    }

    try {
      $parsed = [datetimeoffset]$text
      if ($null -eq $latest -or $parsed -gt $latest) {
        $latest = $parsed
      }
    } catch {
      continue
    }
  }

  if ($null -ne $latest) {
    return $latest.ToString("o")
  }

  return $fallback
}

function Find-PolicyRecord {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies,
    [string] $PolicyId,
    [string] $PolicyName
  )

  if ($PolicyId) {
    $match = @($Policies | Where-Object { $_.Id -and $_.Id -eq $PolicyId } | Select-Object -First 1)
    if ($match.Count -gt 0) {
      return $match[0]
    }
  }

  if ($PolicyName) {
    $match = @($Policies | Where-Object { $_.Name -and $_.Name -ieq $PolicyName } | Select-Object -First 1)
    if ($match.Count -gt 0) {
      return $match[0]
    }
  }

  return $null
}

function Resolve-PolicyEnabledValue {
  param(
    [AllowNull()] $Assignment,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Policies
  )

  if ($null -eq $Assignment) {
    return ""
  }

  if ($null -ne $Assignment.Enabled) {
    return [string]([bool]$Assignment.Enabled)
  }

  $policy = Find-PolicyRecord -Policies $Policies -PolicyId $Assignment.PolicyId -PolicyName $Assignment.PolicyName
  if ($null -ne $policy -and $null -ne $policy.Enabled) {
    return [string]([bool]$policy.Enabled)
  }

  return ""
}

# ---------------------------------------------------------------------------
# Resolve credentials (env file > parameters > environment variables)
# ---------------------------------------------------------------------------

$resolvedHost  = $ApiHost
$resolvedToken = $ApiToken

if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
  Write-Step "Loading credentials from: $EnvFile"
  $envVars = Read-EnvFile -Path $EnvFile
  if ([string]::IsNullOrWhiteSpace($resolvedHost) -and $envVars.ContainsKey("DATTO_EDR_HOST")) { $resolvedHost = $envVars["DATTO_EDR_HOST"] }
  if ([string]::IsNullOrWhiteSpace($resolvedToken) -and $envVars.ContainsKey("DATTO_EDR_TOKEN")) { $resolvedToken = $envVars["DATTO_EDR_TOKEN"] }
} elseif (Test-Path (Join-Path (Split-Path $PSCommandPath -Parent) "datto-edr.env")) {
  $defaultEnv = Join-Path (Split-Path $PSCommandPath -Parent) "datto-edr.env"
  Write-Step "Loading credentials from: $defaultEnv"
  $envVars = Read-EnvFile -Path $defaultEnv
  if ([string]::IsNullOrWhiteSpace($resolvedHost) -and $envVars.ContainsKey("DATTO_EDR_HOST")) { $resolvedHost = $envVars["DATTO_EDR_HOST"] }
  if ([string]::IsNullOrWhiteSpace($resolvedToken) -and $envVars.ContainsKey("DATTO_EDR_TOKEN")) { $resolvedToken = $envVars["DATTO_EDR_TOKEN"] }
}

if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
  $resolvedToken = [System.Environment]::GetEnvironmentVariable($TokenEnvVar)
}
if ([string]::IsNullOrWhiteSpace($resolvedHost)) {
  $resolvedHost = [System.Environment]::GetEnvironmentVariable("DATTO_EDR_HOST")
}

if ([string]::IsNullOrWhiteSpace($resolvedHost)) {
  throw "No API host provided. Pass -ApiHost, set DATTO_EDR_HOST in datto-edr.env, or pass -EnvFile."
}
if ([string]::IsNullOrWhiteSpace($resolvedToken)) {
  throw "No API token provided. Pass -ApiToken, set DATTO_EDR_TOKEN in datto-edr.env, or pass -EnvFile."
}

$baseUrl = Resolve-BaseUrl -HostName $resolvedHost
Write-Step "Base URL: $baseUrl"

# ---------------------------------------------------------------------------
# Resolve output paths
# ---------------------------------------------------------------------------

$artifactsDir = Join-Path (Split-Path $PSCommandPath -Parent) "artifacts/datto-edr"
if (-not (Test-Path $artifactsDir)) {
  New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $OutputCsvPath = Join-Path $artifactsDir "ta-report-enrollment.csv"
}
if ([string]::IsNullOrWhiteSpace($OutputPoliciesCsvPath)) {
  $OutputPoliciesCsvPath = Join-Path $artifactsDir "ta-report-policies.csv"
}
if ([string]::IsNullOrWhiteSpace($OutputPolicyAssignmentsCsvPath)) {
  $OutputPolicyAssignmentsCsvPath = Join-Path $artifactsDir "ta-report-policy-assignments.csv"
}

# ---------------------------------------------------------------------------
# Fetch and normalize data
# ---------------------------------------------------------------------------

$discovery = Get-DefaultDiscoveryConfig

Write-Step "Fetching organizations..."
$organizationsData = Get-EndpointData -BaseUrl $baseUrl -Token $resolvedToken -Candidates $discovery.OrganizationsEndpointCandidates -Fields $discovery.OrganizationFields
$organizations = @($organizationsData.Items | ForEach-Object { Normalize-OrganizationRecord -Record $_ } | Where-Object { $_.Name -or $_.Id })
Write-Step "  $($organizations.Count) organizations found."

Write-Step "Fetching locations/targets..."
$locationsData = Get-EndpointData -BaseUrl $baseUrl -Token $resolvedToken -Candidates $discovery.LocationsEndpointCandidates -Fields $discovery.LocationFields
$locations = @($locationsData.Items | ForEach-Object { Normalize-LocationRecord -Record $_ } | Where-Object { $_.Name -or $_.Id })
Resolve-LocationOrganizationLinks -Organizations $organizations -Locations $locations
Write-Step "  $($locations.Count) locations/targets found."

Write-Step "Fetching policies..."
$policiesData = Get-EndpointData -BaseUrl $baseUrl -Token $resolvedToken -Candidates $discovery.PoliciesEndpointCandidates -Fields $discovery.PolicyFields
$policies = @($policiesData.Items | ForEach-Object { Normalize-PolicyRecord -Record $_ -Discovery $discovery } | Where-Object { $_.Name -or $_.Id })
Write-Step "  $($policies.Count) policies found."

Write-Step "Fetching device groups..."
$deviceGroupsData = Get-EndpointData -BaseUrl $baseUrl -Token $resolvedToken -Candidates $discovery.DeviceGroupsEndpointCandidates -Fields $discovery.DeviceGroupFields
$deviceGroups = @($deviceGroupsData.Items | ForEach-Object { Normalize-DeviceGroupRecord -Record $_ } | Where-Object { $_.Name -or $_.Id })
Write-Step "  $($deviceGroups.Count) device groups found."

Write-Step "Fetching policy assignments..."
$assignmentData = Get-EndpointData -BaseUrl $baseUrl -Token $resolvedToken -Candidates $discovery.AssignmentsEndpointCandidates -Fields $discovery.AssignmentFields -CollectAll
$directAssignments = @(
  $assignmentData.Items |
    ForEach-Object { Normalize-AssignmentRecord -Record $_ -Policies $policies -Organizations $organizations -Locations $locations } |
    Where-Object { $null -ne $_ }
)
$organizationRelationAssignmentData = Get-ScopedRelationAssignments `
  -BaseUrl $baseUrl `
  -Token $resolvedToken `
  -ScopeObjects $organizations `
  -CollectionCandidates $discovery.OrganizationRelationEndpointCandidates `
  -ScopeType "Organization" `
  -Policies $policies
$locationRelationAssignmentData = Get-ScopedRelationAssignments `
  -BaseUrl $baseUrl `
  -Token $resolvedToken `
  -ScopeObjects $locations `
  -CollectionCandidates $discovery.LocationRelationEndpointCandidates `
  -ScopeType "Location" `
  -Policies $policies
$relationAssignments = @($organizationRelationAssignmentData.Assignments + $locationRelationAssignmentData.Assignments)
$embeddedAssignments = @()
$embeddedAssignments += @(Get-EmbeddedAssignmentsFromScopes -ScopeObjects $organizations -ScopeType "Organization" -PropertyCandidates $discovery.OrganizationAssignmentProperties)
$embeddedAssignments += @(Get-EmbeddedAssignmentsFromScopes -ScopeObjects $locations -ScopeType "Location" -PropertyCandidates $discovery.LocationAssignmentProperties)
$embeddedAssignments += @(Get-EmbeddedAssignmentsFromPolicies -Policies $policies -OrganizationProperties $discovery.PolicyOrganizationProperties -LocationProperties $discovery.PolicyLocationProperties)
$assignments = @(Remove-DuplicateAssignments -Assignments (@($directAssignments + $relationAssignments + $embeddedAssignments)))
Resolve-AssignmentDeviceGroupNames -Assignments $assignments -DeviceGroups $deviceGroups
if ($organizationRelationAssignmentData.SelectedEndpoint -or $locationRelationAssignmentData.SelectedEndpoint) {
  $relationSources = @()
  if ($organizationRelationAssignmentData.SelectedEndpoint) {
    $relationSources += @("{0}/{{id}}/policyAssignments" -f $organizationRelationAssignmentData.SelectedEndpoint)
  }
  if ($locationRelationAssignmentData.SelectedEndpoint) {
    $relationSources += @("{0}/{{id}}/policyAssignments" -f $locationRelationAssignmentData.SelectedEndpoint)
  }
  Write-Step "  Scoped relation endpoints: $(Join-UniqueValues -Values $relationSources)"
}
Write-Step "  $($assignments.Count) normalized assignments found."

# ---------------------------------------------------------------------------
# Build org lookup
# ---------------------------------------------------------------------------

$orgById = @{}
foreach ($organization in $organizations) {
  if ($organization.Id) {
    $orgById[$organization.Id] = $organization
  }
}

# ---------------------------------------------------------------------------
# Build enrollment report (one row per org/location)
# ---------------------------------------------------------------------------

Write-Step ""
Write-Step "Building enrollment report..."

$enrollmentRows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($location in $locations) {
  $locId = $location.Id
  $locName = if ($location.Name) { $location.Name } else { $locId }
  $orgId = $location.OrganizationId
  $orgName = $location.OrganizationName

  if (-not $orgName -and $orgId -and $orgById.ContainsKey($orgId)) {
    $orgName = $orgById[$orgId].Name
    if (-not $orgName) { $orgName = $orgId }
  } elseif (-not $orgName -and $orgId) {
    $orgName = $orgId
  } elseif (-not $orgName) {
    $orgName = "(unresolved)"
  }

  $agentCount = Get-NumProp -Obj $location.Raw -Names @("agentCount")
  $activeAgentCount = Get-NumProp -Obj $location.Raw -Names @("activeAgentCount")
  $alertCount = Get-NumProp -Obj $location.Raw -Names @("alertCount")
  $lastScan = Format-Date (Get-StringValue -InputObject $location.Raw -PropertyPaths @("lastScannedOn", "lastScan", "lastActivity"))
  $status = Get-EnrollmentStatus -AgentCount $agentCount -ActiveAgentCount $activeAgentCount
  $rmmUid = Get-StringValue -InputObject $location.Raw -PropertyPaths @("data.rmmUid")
  if (-not $rmmUid) { $rmmUid = "" }

  $enrollmentRows.Add([pscustomobject][ordered]@{
    Organization     = $orgName
    Location         = if ($locName) { $locName } else { "" }
    EnrollmentStatus = $status
    AgentCount       = $agentCount
    ActiveAgentCount = $activeAgentCount
    AlertCount       = $alertCount
    LastScanDate     = $lastScan
    RmmSiteId        = $rmmUid
    LocationId       = if ($locId) { $locId } else { "" }
    OrganizationId   = if ($orgId) { $orgId } else { "" }
  }) | Out-Null
}

foreach ($organization in $organizations) {
  $hasLocation = @($locations | Where-Object {
    ($organization.Id -and $_.OrganizationId -and $_.OrganizationId -eq $organization.Id) -or
    ($organization.Name -and $_.OrganizationName -and $_.OrganizationName -ieq $organization.Name)
  }).Count -gt 0

  if (-not $hasLocation) {
    $enrollmentRows.Add([pscustomobject][ordered]@{
      Organization     = if ($organization.Name) { $organization.Name } else { $organization.Id }
      Location         = "(no location record)"
      EnrollmentStatus = "Not Enrolled"
      AgentCount       = 0
      ActiveAgentCount = 0
      AlertCount       = 0
      LastScanDate     = ""
      RmmSiteId        = ""
      LocationId       = ""
      OrganizationId   = if ($organization.Id) { $organization.Id } else { "" }
    }) | Out-Null
  }
}

$sortedEnrollment = @($enrollmentRows | Sort-Object Organization, Location)

# ---------------------------------------------------------------------------
# Build policy inventory
# ---------------------------------------------------------------------------

Write-Step "Building policy inventory..."

$policyRows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($policy in $policies) {
  $typeName = Get-StringValue -InputObject $policy.Raw -PropertyPaths @("typeName")
  $active = Get-FirstValue -InputObject $policy.Raw -PropertyPaths @("active")
  $disabled = Get-FirstValue -InputObject $policy.Raw -PropertyPaths @("disabled")
  $isDefault = Get-FirstValue -InputObject $policy.Raw -PropertyPaths @("isDefault")

  $effectiveStatus = "Active"
  if ($active -eq $false) { $effectiveStatus = "Inactive" }
  if ($disabled -eq $true) { $effectiveStatus = "Disabled" }

  $policyRows.Add([pscustomobject][ordered]@{
    PolicyType  = if ($policy.PolicyType) { $policy.PolicyType } else { "(unknown)" }
    TypeName    = if ($typeName) { $typeName } else { "" }
    PolicyName  = if ($policy.Name) { $policy.Name } else { "" }
    Status      = $effectiveStatus
    Active      = if ($null -ne $active) { [string]$active } else { "" }
    Disabled    = if ($null -ne $disabled) { [string]$disabled } else { "" }
    IsDefault   = if ($null -ne $isDefault) { [string]$isDefault } else { "" }
    Description = if ($policy.Description) { $policy.Description } else { "" }
    LastUpdated = Format-Date $policy.UpdatedOn
    PolicyId    = if ($policy.Id) { $policy.Id } else { "" }
  }) | Out-Null
}

$sortedPolicies = @($policyRows | Sort-Object PolicyType, PolicyName)

# ---------------------------------------------------------------------------
# Build effective policy assignment report
# ---------------------------------------------------------------------------

Write-Step "Building effective policy assignment report..."

$policyAssignmentRows = [System.Collections.Generic.List[pscustomobject]]::new()
$reportScopes = @(Get-ReportScopes -Organizations $organizations -Locations $locations)
$policyTypes = @(Get-UniquePolicyTypes -Policies $policies -Assignments $assignments)

foreach ($scope in $reportScopes) {
  foreach ($policyType in $policyTypes) {
    $organizationMatches = @(Select-AssignmentsForScope `
      -Assignments $assignments `
      -ScopeType "Organization" `
      -ScopeId $scope.OrganizationId `
      -ScopeName $scope.OrganizationName `
      -PolicyType $policyType)

    $locationMatches = @()
    if ($scope.HasLocationRecord) {
      $locationMatches = @(Select-AssignmentsForScope `
        -Assignments $assignments `
        -ScopeType "Location" `
        -ScopeId $scope.LocationId `
        -ScopeName $scope.LocationName `
        -PolicyType $policyType)
    }

    $winningMatches = @()
    $effectiveSourceScope = "None"

    if ($locationMatches.Count -gt 0) {
      $winningMatches = @($locationMatches)
      $effectiveSourceScope = "Location"
    } elseif ($organizationMatches.Count -gt 0) {
      $winningMatches = @($organizationMatches)
      $effectiveSourceScope = "Organization"
    }

    if ($winningMatches.Count -eq 0) {
      $policyAssignmentRows.Add([pscustomobject][ordered]@{
        Organization                   = if ($scope.OrganizationName) { $scope.OrganizationName } else { "" }
        OrganizationId                 = if ($scope.OrganizationId) { $scope.OrganizationId } else { "" }
        Location                       = if ($scope.LocationName) { $scope.LocationName } else { "" }
        LocationId                     = if ($scope.LocationId) { $scope.LocationId } else { "" }
        PolicyType                     = $policyType
        OrganizationAssignedPolicyName = Join-UniqueValues -Values ($organizationMatches | ForEach-Object { $_.PolicyName })
        OrganizationAssignedPolicyId   = Join-UniqueValues -Values ($organizationMatches | ForEach-Object { $_.PolicyId })
        LocationAssignedPolicyName     = Join-UniqueValues -Values ($locationMatches | ForEach-Object { $_.PolicyName })
        LocationAssignedPolicyId       = Join-UniqueValues -Values ($locationMatches | ForEach-Object { $_.PolicyId })
        EffectivePolicyName            = ""
        EffectivePolicyId              = ""
        EffectiveSourceScope           = $effectiveSourceScope
        ResolutionStatus               = "Unassigned"
        PolicyEnabled                  = ""
        PolicyIsDefault                = ""
        DeviceGroupId                  = ""
        DeviceGroupName                = ""
        AssignedTo                     = ""
        IsOverride                     = ""
        EvidenceSource                 = ""
        LastUpdated                    = ""
      }) | Out-Null
      continue
    }

    $rowAssignments = @(Remove-DuplicateAssignments -Assignments $winningMatches)
    foreach ($effectiveAssignment in $rowAssignments) {
      $organizationAssignedPolicyName = if ($effectiveAssignment.ScopeType -eq "Organization") {
        if ($effectiveAssignment.PolicyName) { $effectiveAssignment.PolicyName } else { "" }
      } else {
        Join-UniqueValues -Values ($organizationMatches | ForEach-Object { $_.PolicyName })
      }
      $organizationAssignedPolicyId = if ($effectiveAssignment.ScopeType -eq "Organization") {
        if ($effectiveAssignment.PolicyId) { $effectiveAssignment.PolicyId } else { "" }
      } else {
        Join-UniqueValues -Values ($organizationMatches | ForEach-Object { $_.PolicyId })
      }
      $locationAssignedPolicyName = if ($effectiveAssignment.ScopeType -eq "Location") {
        if ($effectiveAssignment.PolicyName) { $effectiveAssignment.PolicyName } else { "" }
      } else {
        Join-UniqueValues -Values ($locationMatches | ForEach-Object { $_.PolicyName })
      }
      $locationAssignedPolicyId = if ($effectiveAssignment.ScopeType -eq "Location") {
        if ($effectiveAssignment.PolicyId) { $effectiveAssignment.PolicyId } else { "" }
      } else {
        Join-UniqueValues -Values ($locationMatches | ForEach-Object { $_.PolicyId })
      }

      $policyAssignmentRows.Add([pscustomobject][ordered]@{
        Organization                   = if ($scope.OrganizationName) { $scope.OrganizationName } else { "" }
        OrganizationId                 = if ($scope.OrganizationId) { $scope.OrganizationId } else { "" }
        Location                       = if ($scope.LocationName) { $scope.LocationName } else { "" }
        LocationId                     = if ($scope.LocationId) { $scope.LocationId } else { "" }
        PolicyType                     = $policyType
        OrganizationAssignedPolicyName = $organizationAssignedPolicyName
        OrganizationAssignedPolicyId   = $organizationAssignedPolicyId
        LocationAssignedPolicyName     = $locationAssignedPolicyName
        LocationAssignedPolicyId       = $locationAssignedPolicyId
        EffectivePolicyName            = if ($effectiveAssignment.PolicyName) { $effectiveAssignment.PolicyName } else { "" }
        EffectivePolicyId              = if ($effectiveAssignment.PolicyId) { $effectiveAssignment.PolicyId } else { "" }
        EffectiveSourceScope           = $effectiveSourceScope
        ResolutionStatus               = "Resolved"
        PolicyEnabled                  = Resolve-PolicyEnabledValue -Assignment $effectiveAssignment -Policies $policies
        PolicyIsDefault                = if ($null -ne $effectiveAssignment.PolicyIsDefault) { [string]$effectiveAssignment.PolicyIsDefault } else { "" }
        DeviceGroupId                  = if ($effectiveAssignment.DeviceGroupId) { $effectiveAssignment.DeviceGroupId } else { "" }
        DeviceGroupName                = if ($effectiveAssignment.DeviceGroupName) { $effectiveAssignment.DeviceGroupName } else { "" }
        AssignedTo                     = if ($effectiveAssignment.AssignedTo) { $effectiveAssignment.AssignedTo } else { "" }
        IsOverride                     = if ($null -ne $effectiveAssignment.IsOverride) { [string]$effectiveAssignment.IsOverride } else { "" }
        EvidenceSource                 = if ($effectiveAssignment.EvidenceSource) { [string]$effectiveAssignment.EvidenceSource } else { "" }
        LastUpdated                    = Format-Date $effectiveAssignment.UpdatedOn
      }) | Out-Null
    }
  }
}

$sortedPolicyAssignments = @($policyAssignmentRows | Sort-Object Organization, Location, PolicyType, EffectiveSourceScope, DeviceGroupName, EffectivePolicyName)

# ---------------------------------------------------------------------------
# Write CSVs
# ---------------------------------------------------------------------------

$sortedEnrollment        | Export-Csv -Path $OutputCsvPath                  -NoTypeInformation -Encoding UTF8
$sortedPolicies          | Export-Csv -Path $OutputPoliciesCsvPath          -NoTypeInformation -Encoding UTF8
$sortedPolicyAssignments | Export-Csv -Path $OutputPolicyAssignmentsCsvPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

$notEnrolled = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -eq "Not Enrolled" }).Count
$enrolled = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -ne "Not Enrolled" }).Count
$withAlerts = @($sortedEnrollment | Where-Object { $_.AlertCount -gt 0 }).Count
$activePols = @($sortedPolicies | Where-Object { $_.Status -eq "Active" }).Count
$resolvedAssignmentRows = @($sortedPolicyAssignments | Where-Object { $_.ResolutionStatus -eq "Resolved" }).Count
$unassignedAssignmentRows = @($sortedPolicyAssignments | Where-Object { $_.ResolutionStatus -eq "Unassigned" }).Count
$conflictAssignmentRows = @($sortedPolicyAssignments | Where-Object { $_.ResolutionStatus -like "ConflictAt*" }).Count

Write-Step ""
Write-Step "=== Summary ==="
Write-Step "  Organizations:    $($organizations.Count)"
Write-Step "  Locations:        $($locations.Count)"
Write-Step "  Enrolled:         $enrolled  |  Not Enrolled: $notEnrolled"
Write-Step "  Locations w/ open alerts: $withAlerts"
Write-Step "  Active policies:  $activePols of $($policies.Count) total"
Write-Step "  Assignment rows:  $($sortedPolicyAssignments.Count) | Resolved: $resolvedAssignmentRows | Unassigned: $unassignedAssignmentRows | Conflicts: $conflictAssignmentRows"
Write-Step ""
Write-Step "Enrollment report:  $OutputCsvPath"
Write-Step "Policy inventory:   $OutputPoliciesCsvPath"
Write-Step "Policy assignments: $OutputPolicyAssignmentsCsvPath"

$gaps = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -eq "Not Enrolled" })
if ($gaps.Count -gt 0) {
  Write-Step ""
  Write-Step "Locations with no enrolled agents ($($gaps.Count)):"
  foreach ($gap in $gaps) {
    Write-Step "  - $($gap.Organization) / $($gap.Location)"
  }
}
