[CmdletBinding(DefaultParameterSetName = "Audit")]
param(
  [Parameter(Mandatory, ParameterSetName = "Audit")]
  [string] $ConfigPath,

  [Parameter(ParameterSetName = "Audit")]
  [string] $OutputCsvPath,

  [Parameter(ParameterSetName = "Audit")]
  [string] $OutputJsonPath,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyOrganizations,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyLocations,

  [Parameter(ParameterSetName = "Audit")]
  [switch] $UseUiFallback,

  [Parameter(Mandatory, ParameterSetName = "SelfTest")]
  [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:BlockingIssues = [System.Collections.Generic.List[string]]::new()
$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-edr-policy-audit] $Message"
}

function Add-BlockingIssue {
  param([string] $Message)

  if (-not [string]::IsNullOrWhiteSpace($Message)) {
    $script:BlockingIssues.Add($Message) | Out-Null
    Write-Warning $Message
  }
}

function Add-AuditWarning {
  param([string] $Message)

  if (-not [string]::IsNullOrWhiteSpace($Message)) {
    $script:Warnings.Add($Message) | Out-Null
    Write-Warning $Message
  }
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $BaseDirectory = (Get-Location).Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Path cannot be empty."
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDirectory -ChildPath $Path))
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

function Resolve-DattoEdrInstanceUrl {
  param([Parameter(Mandatory)] [string] $InstanceUrl)

  $value = $InstanceUrl.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "InstanceUrl cannot be empty."
  }

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
    $value = $Parameters[$key]
    if ($null -eq $value) {
      continue
    }
    '{0}={1}' -f [System.Uri]::EscapeDataString([string]$key), [System.Uri]::EscapeDataString([string]$value)
  }

  return ($parts -join '&')
}

function Invoke-DattoEdrApiRequest {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [ValidateSet("GET")] [string] $Method,
    [Parameter(Mandatory)] [string] $Endpoint,
    [hashtable] $Where = @{},
    [string[]] $Fields,
    [int] $Limit = 1000,
    [switch] $CountOnly,
    [switch] $NoThrow
  )

  $relative = $Endpoint.TrimStart('/')
  $uri = "{0}/api/{1}" -f $BaseUrl.TrimEnd('/'), $relative

  $parameters = @{
    access_token = $Token
  }

  if ($CountOnly -or $relative -match '/count$') {
    if ($Where.Count -gt 0) {
      $parameters['where'] = ($Where | ConvertTo-Json -Depth 30 -Compress)
    }
  } else {
    $filter = @{
      order = 'id'
      limit = $Limit
    }

    if ($Fields -and $Fields.Count -gt 0) {
      $filter['fields'] = $Fields
    }

    if ($Where.Count -gt 0) {
      $filter['where'] = $Where
    }

    $parameters['filter'] = ($filter | ConvertTo-Json -Depth 30 -Compress)
  }

  $query = ConvertTo-QueryString -Parameters $parameters
  if (-not [string]::IsNullOrWhiteSpace($query)) {
    $uri = "{0}?{1}" -f $uri, $query
  }

  try {
    return Invoke-RestMethod -Uri $uri -Method GET -ContentType 'application/json'
  } catch {
    if ($NoThrow) {
      return $null
    }

    $message = $_.Exception.Message
    if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
      $message = "{0} Response: {1}" -f $message, $_.ErrorDetails.Message
    }
    throw "Datto EDR API request failed for endpoint '$Endpoint': $message"
  }
}

function Get-DattoEdrAll {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] [string] $Endpoint,
    [hashtable] $Where = @{},
    [string[]] $Fields,
    [int] $PageSize = 1000,
    [switch] $AllowSingleObject,
    [switch] $NoThrow
  )

  $objects = @()
  $workingWhere = @{}
  foreach ($key in $Where.Keys) {
    $workingWhere[$key] = $Where[$key]
  }

  while ($true) {
    $page = Invoke-DattoEdrApiRequest -BaseUrl $BaseUrl -Token $Token -Method GET -Endpoint $Endpoint -Where $workingWhere -Fields $Fields -Limit $PageSize -NoThrow:$NoThrow
    if ($null -eq $page) {
      return $null
    }

    if ($page -is [System.Collections.IEnumerable] -and -not ($page -is [string]) -and -not ($page -is [System.Collections.IDictionary])) {
      $batch = @($page)
    } else {
      if ($AllowSingleObject) {
        return @($page)
      }
      $batch = @($page)
    }

    if ($batch.Count -eq 0) {
      break
    }

    $objects += $batch

    if ($batch.Count -lt $PageSize) {
      break
    }

    $lastId = Get-FirstValue -InputObject $batch[-1] -PropertyPaths @("id")
    if ($null -eq $lastId) {
      break
    }

    $workingWhere['id'] = @{ gt = $lastId }
  }

  return @($objects)
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
    PolicyFields                     = @("id", "name", "type", "policyType", "enabled", "isEnabled", "status", "description", "settings", "configuration", "updatedOn", "updatedAt")
    OrganizationFields               = @("id", "name", "displayName", "assignedPolicies", "policies", "locations")
    LocationFields                   = @("id", "name", "displayName", "organizationId", "orgId", "companyId", "organization", "policies", "assignedPolicies")
    AssignmentFields                 = @("id", "policyId", "policyName", "policyType", "type", "organizationId", "targetId", "locationId", "scopeType", "scopeId", "enabled", "status", "updatedOn", "updatedAt")
    OrganizationAssignmentProperties = @("assignedPolicies", "policyAssignments", "policies")
    LocationAssignmentProperties     = @("assignedPolicies", "policyAssignments", "policies")
    PolicyOrganizationProperties     = @("organizations", "assignedOrganizations", "orgs")
    PolicyLocationProperties         = @("targets", "targetGroups", "locations", "assignedTargets")
    PolicySettingsProperties         = @("settings", "configuration", "config", "options", "policy", "definition", "template")
  }
}

function Merge-DiscoveryConfig {
  param([AllowNull()] $ConfigValue)

  $default = Get-DefaultDiscoveryConfig
  $plain = ConvertTo-PlainData -InputObject $ConfigValue

  if ($plain -isnot [System.Collections.IDictionary]) {
    return $default
  }

  foreach ($key in $plain.Keys) {
    $default[$key] = $plain[$key]
  }

  return $default
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
      $data = Get-DattoEdrAll -BaseUrl $BaseUrl -Token $Token -Endpoint $candidate -Fields $Fields -NoThrow
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

function ConvertTo-CanonicalPolicyType {
  param([AllowNull()] $Value)

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

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

function Normalize-PolicyRecord {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] [hashtable] $Discovery
  )

  $name = Get-StringValue -InputObject $Record -PropertyPaths @("name", "displayName", "policy.name", "policyName")
  $typeValue = Get-FirstValue -InputObject $Record -PropertyPaths @("policyType", "type", "category", "templateType", "policy.type")
  $type = ConvertTo-CanonicalPolicyType -Value $typeValue
  if (-not $type) {
    $type = Get-PolicyTypeFromName -Name $name
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

function New-NormalizedAssignment {
  param(
    [AllowNull()] [string] $AssignmentId,
    [AllowNull()] [string] $PolicyId,
    [AllowNull()] [string] $PolicyName,
    [AllowNull()] [string] $PolicyType,
    [Parameter(Mandatory)] [ValidateSet("Organization", "Location")] [string] $ScopeType,
    [AllowNull()] [string] $ScopeId,
    [AllowNull()] [string] $ScopeName,
    [AllowNull()] [bool] $Enabled,
    [AllowNull()] $Settings,
    [AllowNull()] [string] $UpdatedOn,
    [Parameter(Mandatory)] [string] $EvidenceSource,
    [AllowNull()] $Raw
  )

  [pscustomobject][ordered]@{
    AssignmentId  = $AssignmentId
    PolicyId      = $PolicyId
    PolicyName    = $PolicyName
    PolicyType    = $PolicyType
    ScopeType     = $ScopeType
    ScopeId       = $ScopeId
    ScopeName     = $ScopeName
    Enabled       = $Enabled
    Settings      = $Settings
    UpdatedOn     = $UpdatedOn
    EvidenceSource = $EvidenceSource
    Raw           = $Raw
  }
}

function Normalize-AssignmentRecord {
  param(
    [Parameter(Mandatory)] $Record,
    [Parameter(Mandatory)] [object[]] $Policies,
    [Parameter(Mandatory)] [object[]] $Organizations,
    [Parameter(Mandatory)] [object[]] $Locations
  )

  $policyId = Get-StringValue -InputObject $Record -PropertyPaths @("policyId", "policy.id", "namedPolicyId")
  $policyName = Get-StringValue -InputObject $Record -PropertyPaths @("policyName", "policy.name", "name")
  $policyType = ConvertTo-CanonicalPolicyType -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("policyType", "type", "policy.type", "policy.policyType"))

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
      if (-not $policyType) { $policyType = $policy[0].PolicyType }
    }
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
    -Settings (Get-SettingsCandidate -InputObject $Record -PropertyNames @("settings", "configuration", "policy", "assignment")) `
    -UpdatedOn (ConvertTo-DateString -Value (Get-FirstValue -InputObject $Record -PropertyPaths @("updatedOn", "updatedAt", "modifiedOn"))) `
    -EvidenceSource "API" `
    -Raw (ConvertTo-PlainData -InputObject $Record)
  )
}

function Get-EmbeddedAssignmentsFromScopes {
  param(
    [Parameter(Mandatory)] [object[]] $ScopeObjects,
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
        $policyType = ConvertTo-CanonicalPolicyType -Value (Get-FirstValue -InputObject $item -PropertyPaths @("policyType", "type", "policyTypeName", "policy.type"))
        if (-not $policyType) {
          $policyType = Get-PolicyTypeFromName -Name $policyName
        }

        if (-not $policyName -and -not $policyType) {
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
    [Parameter(Mandatory)] [object[]] $Policies,
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
    [Parameter(Mandatory)] [object[]] $Organizations,
    [Parameter(Mandatory)] [object[]] $Locations
  )

  foreach ($location in $Locations) {
    if ($location.OrganizationId -or $location.OrganizationName) {
      continue
    }

    foreach ($organization in $Organizations) {
      foreach ($child in (ConvertTo-Array -InputObject (Get-FirstValue -InputObject $organization.Raw -PropertyPaths @("locations", "targets", "locationIds", "targetIds")))) {
        $childId = if ($child -is [ValueType] -or $child -is [string]) { [string]$child } else { Get-StringValue -InputObject $child -PropertyPaths @("id", "targetId", "locationId") }
        $childName = if ($child -is [ValueType] -or $child -is [string]) { $null } else { Get-StringValue -InputObject $child -PropertyPaths @("name", "displayName", "targetName", "locationName") }

        if (($childId -and $location.Id -eq $childId) -or ($childName -and $location.Name -ieq $childName)) {
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
  param([Parameter(Mandatory)] [object[]] $Assignments)

  $seen = @{}
  $result = [System.Collections.Generic.List[object]]::new()

  foreach ($assignment in $Assignments) {
    $key = "{0}|{1}|{2}|{3}|{4}" -f `
      ([string]$assignment.ScopeType), `
      ([string]$assignment.ScopeId), `
      ([string]$assignment.ScopeName), `
      ([string]$assignment.PolicyType), `
      ([string]$assignment.PolicyName)

    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $result.Add($assignment) | Out-Null
    }
  }

  return @($result)
}

function Get-RecentPolicyChanges {
  param(
    [Parameter(Mandatory)] [string] $BaseUrl,
    [Parameter(Mandatory)] [string] $Token
  )

  $where = @{
    createdOn = @{
      gte = (Get-Date).AddDays(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
  }

  try {
    $activities = Get-DattoEdrAll -BaseUrl $BaseUrl -Token $Token -Endpoint "useractivities" -Where $where -NoThrow
    if (-not $activities -or $activities.Count -eq 0) {
      return @()
    }

    return @(
      $activities |
        ForEach-Object {
          $queryText = Get-FirstValue -InputObject $_ -PropertyPaths @("query", "details", "description")
          $text = ($queryText | ConvertTo-Json -Depth 10 -Compress)
          $action = Get-StringValue -InputObject $_ -PropertyPaths @("action", "type", "eventType")
          if (([string]$text + " " + [string]$action) -match '(?i)policy|assign|unassign|enable|disable|defender|ransomware|av') {
            [pscustomobject][ordered]@{
              Id             = Get-StringValue -InputObject $_ -PropertyPaths @("id")
              Username       = Get-StringValue -InputObject $_ -PropertyPaths @("username", "user.username", "userName")
              Action         = $action
              CreatedOn      = ConvertTo-DateString -Value (Get-FirstValue -InputObject $_ -PropertyPaths @("createdOn", "timestamp", "updatedOn"))
              Query          = $text
              EvidenceSource = "API:useractivities"
            }
          }
        } |
        Where-Object { $null -ne $_ }
    )
  } catch {
    Add-AuditWarning -Message "Unable to retrieve recent user activity logs. Continuing without change evidence. $($_.Exception.Message)"
    return @()
  }
}

function Get-NormalizedObservedStateFromApi {
  param(
    [Parameter(Mandatory)] [hashtable] $Config,
    [switch] $UseUiFallbackRequested
  )

  $instanceUrl = Resolve-DattoEdrInstanceUrl -InstanceUrl ([string]$Config.InstanceUrl)
  $tokenEnvVar = [string]$Config.TokenEnvVar
  if ([string]::IsNullOrWhiteSpace($tokenEnvVar)) {
    throw "Config value TokenEnvVar is required."
  }

  $token = [Environment]::GetEnvironmentVariable($tokenEnvVar)
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Environment variable '$tokenEnvVar' is not set."
  }

  $discovery = Merge-DiscoveryConfig -ConfigValue (Get-FirstValue -InputObject $Config -PropertyPaths @("ApiDiscovery"))

  Write-Step "Querying Datto EDR policies."
  $policiesData = Get-EndpointData -BaseUrl $instanceUrl -Token $token -Candidates $discovery.PoliciesEndpointCandidates -Fields $discovery.PolicyFields
  $policies = @($policiesData.Items | ForEach-Object { Normalize-PolicyRecord -Record $_ -Discovery $discovery } | Where-Object { $_.Name -or $_.Id })

  Write-Step "Querying Datto EDR organizations."
  $organizationsData = Get-EndpointData -BaseUrl $instanceUrl -Token $token -Candidates $discovery.OrganizationsEndpointCandidates -Fields $discovery.OrganizationFields
  $organizations = @($organizationsData.Items | ForEach-Object { Normalize-OrganizationRecord -Record $_ } | Where-Object { $_.Name -or $_.Id })

  Write-Step "Querying Datto EDR locations."
  $locationsData = Get-EndpointData -BaseUrl $instanceUrl -Token $token -Candidates $discovery.LocationsEndpointCandidates -Fields $discovery.LocationFields
  $locations = @($locationsData.Items | ForEach-Object { Normalize-LocationRecord -Record $_ } | Where-Object { $_.Name -or $_.Id })

  Resolve-LocationOrganizationLinks -Organizations $organizations -Locations $locations

  Write-Step "Querying Datto EDR policy assignments."
  $assignmentData = Get-EndpointData -BaseUrl $instanceUrl -Token $token -Candidates $discovery.AssignmentsEndpointCandidates -Fields $discovery.AssignmentFields -CollectAll
  $directAssignments = @(
    $assignmentData.Items |
      ForEach-Object { Normalize-AssignmentRecord -Record $_ -Policies $policies -Organizations $organizations -Locations $locations } |
      Where-Object { $null -ne $_ }
  )

  $embeddedAssignments = @()
  $embeddedAssignments += @(Get-EmbeddedAssignmentsFromScopes -ScopeObjects $organizations -ScopeType "Organization" -PropertyCandidates $discovery.OrganizationAssignmentProperties)
  $embeddedAssignments += @(Get-EmbeddedAssignmentsFromScopes -ScopeObjects $locations -ScopeType "Location" -PropertyCandidates $discovery.LocationAssignmentProperties)
  $embeddedAssignments += @(Get-EmbeddedAssignmentsFromPolicies -Policies $policies -OrganizationProperties $discovery.PolicyOrganizationProperties -LocationProperties $discovery.PolicyLocationProperties)

  $assignments = Remove-DuplicateAssignments -Assignments (@($directAssignments + $embeddedAssignments))
  $recentPolicyChanges = Get-RecentPolicyChanges -BaseUrl $instanceUrl -Token $token

  if (@($policies).Count -eq 0) {
    Add-BlockingIssue -Message "No policy data could be collected from the Datto EDR API."
  }

  if (@($locations).Count -eq 0 -and @($organizations).Count -eq 0) {
    Add-BlockingIssue -Message "No organization or location data could be collected from the Datto EDR API."
  }

  if (@($assignments).Count -eq 0 -and -not $UseUiFallbackRequested) {
    Add-BlockingIssue -Message "No policy assignment data was discovered from the Datto EDR API and UI fallback was not enabled."
  }

  return [pscustomobject][ordered]@{
    Discovery = [ordered]@{
      InstanceUrl           = $instanceUrl
      PoliciesEndpoints     = $policiesData.SelectedEndpoints
      OrganizationsEndpoints = $organizationsData.SelectedEndpoints
      LocationsEndpoints    = $locationsData.SelectedEndpoints
      AssignmentsEndpoints  = $assignmentData.SelectedEndpoints
    }
    Policies            = $policies
    Organizations       = $organizations
    Locations           = $locations
    Assignments         = $assignments
    RecentPolicyChanges = $recentPolicyChanges
    UiFallbackUsed      = $false
    UiFallbackError     = $null
  }
}

function Test-WildcardMatch {
  param(
    [AllowNull()] [string] $Actual,
    [AllowNull()] [string] $Expected
  )

  if ([string]::IsNullOrWhiteSpace($Expected)) {
    return $true
  }

  if ([string]::IsNullOrWhiteSpace($Actual)) {
    return $false
  }

  if ($Expected.Contains('*') -or $Expected.Contains('?')) {
    return ($Actual -like $Expected)
  }

  return $Actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
}

function Normalize-BaselineConfig {
  param(
    [Parameter(Mandatory)] [hashtable] $Config,
    [Parameter(Mandatory)] [string] $BaseDirectory
  )

  $policyBaselines = [System.Collections.Generic.List[object]]::new()
  $baselineSource = ConvertTo-PlainData -InputObject $Config.PolicyBaselines
  if ($baselineSource -isnot [System.Collections.IDictionary]) {
    throw "Config value PolicyBaselines must be an object keyed by policy type."
  }

  foreach ($key in $baselineSource.Keys) {
    $policyType = ConvertTo-CanonicalPolicyType -Value $key
    $value = $baselineSource[$key]
    $expectedPolicyName = Get-StringValue -InputObject $value -PropertyPaths @("ExpectedPolicyName", "PolicyName", "Name")
    if ([string]::IsNullOrWhiteSpace($expectedPolicyName)) {
      throw "Policy baseline '$key' is missing ExpectedPolicyName."
    }

    $policyBaselines.Add([pscustomobject][ordered]@{
      PolicyType         = $policyType
      ExpectedPolicyName = $expectedPolicyName
      ExpectedEnabled    = ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $value -PropertyPaths @("ExpectedEnabled", "Enabled"))
      ExpectedSettings   = ConvertTo-PlainData -InputObject (Get-FirstValue -InputObject $value -PropertyPaths @("ExpectedSettings", "Settings"))
    }) | Out-Null
  }

  $assignmentRules = [System.Collections.Generic.List[object]]::new()
  foreach ($rule in (ConvertTo-Array -InputObject $Config.AssignmentRules)) {
    $policies = ConvertTo-PlainData -InputObject (Get-FirstValue -InputObject $rule -PropertyPaths @("Policies"))
    if ($policies -isnot [System.Collections.IDictionary]) {
      continue
    }

    $assignmentRules.Add([pscustomobject][ordered]@{
      OrganizationId   = Get-StringValue -InputObject $rule -PropertyPaths @("OrganizationId")
      OrganizationName = Get-StringValue -InputObject $rule -PropertyPaths @("OrganizationName")
      LocationId       = Get-StringValue -InputObject $rule -PropertyPaths @("LocationId")
      LocationName     = Get-StringValue -InputObject $rule -PropertyPaths @("LocationName")
      Policies         = $policies
    }) | Out-Null
  }

  $allowedExceptions = [System.Collections.Generic.List[object]]::new()
  foreach ($exception in (ConvertTo-Array -InputObject $Config.AllowedExceptions)) {
    $allowedExceptions.Add([pscustomobject][ordered]@{
      OrganizationId   = Get-StringValue -InputObject $exception -PropertyPaths @("OrganizationId")
      OrganizationName = Get-StringValue -InputObject $exception -PropertyPaths @("OrganizationName")
      LocationId       = Get-StringValue -InputObject $exception -PropertyPaths @("LocationId")
      LocationName     = Get-StringValue -InputObject $exception -PropertyPaths @("LocationName")
      PolicyType       = ConvertTo-CanonicalPolicyType -Value (Get-FirstValue -InputObject $exception -PropertyPaths @("PolicyType"))
      ControlName      = Get-StringValue -InputObject $exception -PropertyPaths @("ControlName")
      ExpiresOn        = ConvertTo-DateString -Value (Get-FirstValue -InputObject $exception -PropertyPaths @("ExpiresOn"))
      Notes            = Get-StringValue -InputObject $exception -PropertyPaths @("Notes", "Note")
    }) | Out-Null
  }

  return [pscustomobject][ordered]@{
    InstanceUrl       = Resolve-DattoEdrInstanceUrl -InstanceUrl ([string]$Config.InstanceUrl)
    TokenEnvVar       = [string]$Config.TokenEnvVar
    PolicyBaselines   = @($policyBaselines)
    AssignmentRules   = @($assignmentRules)
    AllowedExceptions = @($allowedExceptions)
    UiFallback        = ConvertTo-PlainData -InputObject (Get-FirstValue -InputObject $Config -PropertyPaths @("UiFallback"))
    ApiDiscovery      = Merge-DiscoveryConfig -ConfigValue (Get-FirstValue -InputObject $Config -PropertyPaths @("ApiDiscovery"))
    BaseDirectory     = $BaseDirectory
  }
}

function Get-ScopeObjects {
  param(
    [Parameter(Mandatory)] [object[]] $Organizations,
    [Parameter(Mandatory)] [object[]] $Locations
  )

  $scopes = [System.Collections.Generic.List[object]]::new()

  if (@($Locations).Count -gt 0) {
    foreach ($location in $Locations) {
      $organization = @($Organizations | Where-Object {
        ($location.OrganizationId -and $_.Id -eq $location.OrganizationId) -or
        ($location.OrganizationName -and $_.Name -ieq $location.OrganizationName)
      } | Select-Object -First 1)

      $scopes.Add([pscustomobject][ordered]@{
        OrganizationId     = if (@($organization).Count -gt 0) { $organization[0].Id } else { $location.OrganizationId }
        OrganizationName   = if (@($organization).Count -gt 0) { $organization[0].Name } else { $location.OrganizationName }
        LocationId         = $location.Id
        LocationName       = $location.Name
        IsOrganizationOnly = $false
      }) | Out-Null
    }
  } else {
    foreach ($organization in $Organizations) {
      $scopes.Add([pscustomobject][ordered]@{
        OrganizationId     = $organization.Id
        OrganizationName   = $organization.Name
        LocationId         = $null
        LocationName       = $null
        IsOrganizationOnly = $true
      }) | Out-Null
    }
  }

  return @($scopes)
}

function Filter-Scopes {
  param(
    [Parameter(Mandatory)] [object[]] $Scopes,
    [string[]] $OnlyOrganizations,
    [string[]] $OnlyLocations
  )

  $filtered = @($Scopes)

  if ($OnlyOrganizations -and @($OnlyOrganizations).Count -gt 0) {
    $filtered = @(
      $filtered | Where-Object {
        $orgName = [string]$_.OrganizationName
        $orgId = [string]$_.OrganizationId
        foreach ($candidate in $OnlyOrganizations) {
          if (Test-WildcardMatch -Actual $orgName -Expected $candidate -or Test-WildcardMatch -Actual $orgId -Expected $candidate) {
            return $true
          }
        }
        return $false
      }
    )
  }

  if ($OnlyLocations -and @($OnlyLocations).Count -gt 0) {
    $filtered = @(
      $filtered | Where-Object {
        $locName = [string]$_.LocationName
        $locId = [string]$_.LocationId
        foreach ($candidate in $OnlyLocations) {
          if (Test-WildcardMatch -Actual $locName -Expected $candidate -or Test-WildcardMatch -Actual $locId -Expected $candidate) {
            return $true
          }
        }
        return $false
      }
    )
  }

  return $filtered
}

function Resolve-ExpectedPolicyName {
  param(
    [Parameter(Mandatory)] [object] $Scope,
    [Parameter(Mandatory)] [string] $PolicyType,
    [Parameter(Mandatory)] [object[]] $PolicyBaselines,
    [Parameter(Mandatory)] [object[]] $AssignmentRules
  )

  $baseline = @($PolicyBaselines | Where-Object { $_.PolicyType -eq $PolicyType } | Select-Object -First 1)
  if (@($baseline).Count -eq 0) {
    return $null
  }

  $matchingRules = @()
  foreach ($rule in $AssignmentRules) {
    $policyValue = $null
    foreach ($ruleKey in $rule.Policies.Keys) {
      if ((ConvertTo-CanonicalPolicyType -Value $ruleKey) -eq $PolicyType) {
        $policyValue = [string]$rule.Policies[$ruleKey]
        break
      }
    }

    if ([string]::IsNullOrWhiteSpace($policyValue)) {
      continue
    }

    $isMatch =
      (Test-WildcardMatch -Actual $Scope.OrganizationId -Expected $rule.OrganizationId) -and
      (Test-WildcardMatch -Actual $Scope.OrganizationName -Expected $rule.OrganizationName) -and
      (Test-WildcardMatch -Actual $Scope.LocationId -Expected $rule.LocationId) -and
      (Test-WildcardMatch -Actual $Scope.LocationName -Expected $rule.LocationName)

    if ($isMatch) {
      $specificity = 0
      foreach ($field in @($rule.OrganizationId, $rule.OrganizationName, $rule.LocationId, $rule.LocationName)) {
        if (-not [string]::IsNullOrWhiteSpace($field)) {
          $specificity++
        }
      }

      $matchingRules += [pscustomobject]@{
        Specificity = $specificity
        PolicyName  = $policyValue
      }
    }
  }

  if (@($matchingRules).Count -eq 0) {
    return $baseline[0].ExpectedPolicyName
  }

  $topSpecificity = ($matchingRules | Measure-Object -Property Specificity -Maximum).Maximum
  $topRules = @($matchingRules | Where-Object { $_.Specificity -eq $topSpecificity })
  $distinctNames = @($topRules.PolicyName | Sort-Object -Unique)
  if (@($distinctNames).Count -gt 1) {
    throw "Multiple assignment rules with the same specificity matched scope '$($Scope.OrganizationName)/$($Scope.LocationName)' for policy type '$PolicyType'."
  }

  return $distinctNames[0]
}

function Get-PolicyBaseline {
  param(
    [Parameter(Mandatory)] [object[]] $PolicyBaselines,
    [Parameter(Mandatory)] [string] $PolicyType
  )

  return @($PolicyBaselines | Where-Object { $_.PolicyType -eq $PolicyType } | Select-Object -First 1)
}

function Resolve-EffectiveAssignment {
  param(
    [Parameter(Mandatory)] [object] $Scope,
    [Parameter(Mandatory)] [string] $PolicyType,
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Assignments
  )

  $matches = @(
    $Assignments | Where-Object {
      $_.PolicyType -eq $PolicyType -and (
        ($Scope.LocationId -and $_.ScopeType -eq "Location" -and $_.ScopeId -eq $Scope.LocationId) -or
        ($Scope.LocationName -and $_.ScopeType -eq "Location" -and $_.ScopeName -and $_.ScopeName -ieq $Scope.LocationName)
      )
    }
  )

  if (@($matches).Count -gt 0) {
    return [pscustomobject]@{
      EffectiveMatches = $matches
      Source           = "Location"
    }
  }

  $matches = @(
    $Assignments | Where-Object {
      $_.PolicyType -eq $PolicyType -and (
        ($Scope.OrganizationId -and $_.ScopeType -eq "Organization" -and $_.ScopeId -eq $Scope.OrganizationId) -or
        ($Scope.OrganizationName -and $_.ScopeType -eq "Organization" -and $_.ScopeName -and $_.ScopeName -ieq $Scope.OrganizationName)
      )
    }
  )

  return [pscustomobject]@{
    EffectiveMatches = $matches
    Source           = if (@($matches).Count -gt 0) { "Organization" } else { $null }
  }
}

function Compare-ExpectedSettings {
  param(
    [AllowNull()] $Expected,
    [AllowNull()] $Actual,
    [string] $Path = ""
  )

  $missing = [System.Collections.Generic.List[string]]::new()
  $expectedPlain = ConvertTo-PlainData -InputObject $Expected
  $actualPlain = ConvertTo-PlainData -InputObject $Actual

  if ($null -eq $expectedPlain) {
    return @()
  }

  if ($expectedPlain -is [System.Collections.IDictionary]) {
    if ($actualPlain -isnot [System.Collections.IDictionary]) {
      $pathLabel = if ($Path) { $Path } else { "<settings>" }
      $missing.Add($pathLabel) | Out-Null
      return @($missing)
    }

    foreach ($key in $expectedPlain.Keys) {
      $actualValue = $null
      $found = $false
      foreach ($actualKey in $actualPlain.Keys) {
        if ([string]::Equals([string]$actualKey, [string]$key, [System.StringComparison]::OrdinalIgnoreCase)) {
          $actualValue = $actualPlain[$actualKey]
          $found = $true
          break
        }
      }

      $childPath = if ($Path) { "{0}.{1}" -f $Path, $key } else { [string]$key }
      if (-not $found) {
        $missing.Add($childPath) | Out-Null
        continue
      }

      foreach ($item in (Compare-ExpectedSettings -Expected $expectedPlain[$key] -Actual $actualValue -Path $childPath)) {
        $missing.Add($item) | Out-Null
      }
    }

    return @($missing)
  }

  if ($expectedPlain -is [System.Collections.IEnumerable] -and -not ($expectedPlain -is [string])) {
    $actualItems = @()
    if ($actualPlain -is [System.Collections.IEnumerable] -and -not ($actualPlain -is [string])) {
      $actualItems = @($actualPlain)
    }

    foreach ($expectedItem in @($expectedPlain)) {
      $expectedText = (ConvertTo-PlainData -InputObject $expectedItem | ConvertTo-Json -Depth 10 -Compress)
      $match = $actualItems | Where-Object {
        (ConvertTo-PlainData -InputObject $_ | ConvertTo-Json -Depth 10 -Compress) -eq $expectedText
      } | Select-Object -First 1
      if (-not $match) {
        $pathLabel = if ($Path) { $Path } else { "<settings>" }
        $missing.Add(("{0}[{1}]" -f $pathLabel, $expectedText)) | Out-Null
      }
    }

    return @($missing)
  }

  $expectedBool = ConvertTo-BooleanOrNull -Value $expectedPlain
  $actualBool = ConvertTo-BooleanOrNull -Value $actualPlain
  if ($null -ne $expectedBool -or $null -ne $actualBool) {
    if ($expectedBool -ne $actualBool) {
      $pathLabel = if ($Path) { $Path } else { "<settings>" }
      return @($pathLabel)
    }
    return @()
  }

  $expectedText = [string]$expectedPlain
  $actualText = [string]$actualPlain
  if ($expectedText -ne $actualText) {
    $pathLabel = if ($Path) { $Path } else { "<settings>" }
    return @($pathLabel)
  }

  return @()
}

function Resolve-AllowedException {
  param(
    [Parameter(Mandatory)] [object] $Row,
    [Parameter(Mandatory)] [object[]] $AllowedExceptions
  )

  foreach ($exception in $AllowedExceptions) {
    if ($exception.PolicyType -and $exception.PolicyType -ne $Row.PolicyType) {
      continue
    }
    if ($exception.ControlName -and $exception.ControlName -ne $Row.ControlName) {
      continue
    }
    if ($exception.OrganizationName -and -not (Test-WildcardMatch -Actual $Row.Organization -Expected $exception.OrganizationName)) {
      continue
    }
    if ($exception.OrganizationId -and -not (Test-WildcardMatch -Actual $Row.OrganizationId -Expected $exception.OrganizationId)) {
      continue
    }
    if ($exception.LocationName -and -not (Test-WildcardMatch -Actual $Row.Location -Expected $exception.LocationName)) {
      continue
    }
    if ($exception.LocationId -and -not (Test-WildcardMatch -Actual $Row.LocationId -Expected $exception.LocationId)) {
      continue
    }

    if ($exception.ExpiresOn) {
      try {
        if ([datetimeoffset]$exception.ExpiresOn -lt [datetimeoffset]::UtcNow) {
          continue
        }
      } catch {
      }
    }

    return $exception
  }

  return $null
}

function New-FindingRow {
  param(
    [Parameter(Mandatory)] [object] $Scope,
    [Parameter(Mandatory)] [string] $PolicyType,
    [Parameter(Mandatory)] [string] $ControlName,
    [Parameter(Mandatory)] [string] $ValidationStatus,
    [string[]] $MissingItems = @(),
    [string] $EvidenceSource = "",
    [string] $Notes = "",
    [string] $ExpectedPolicyName = "",
    [string] $ActualPolicyName = "",
    [AllowNull()] $ExpectedEnabled,
    [AllowNull()] $ActualEnabled
  )

  [pscustomobject][ordered]@{
    Organization       = [string]$Scope.OrganizationName
    OrganizationId     = [string]$Scope.OrganizationId
    Location           = [string]$Scope.LocationName
    LocationId         = [string]$Scope.LocationId
    PolicyType         = $PolicyType
    ControlName        = $ControlName
    ValidationStatus   = $ValidationStatus
    MissingItems       = @($MissingItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    MissingCount       = @($MissingItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    ExpectedPolicyName = $ExpectedPolicyName
    ActualPolicyName   = $ActualPolicyName
    ExpectedEnabled    = $ExpectedEnabled
    ActualEnabled      = $ActualEnabled
    EvidenceSource     = $EvidenceSource
    Notes              = $Notes
  }
}

function Merge-UiFallbackSnapshot {
  param(
    [Parameter(Mandatory)] [object] $ObservedState,
    [Parameter(Mandatory)] $Snapshot
  )

  $snapshotAssignments = ConvertTo-Array -InputObject (Get-FirstValue -InputObject $Snapshot -PropertyPaths @("assignments", "Assignments"))
  if (@($snapshotAssignments).Count -eq 0) {
    return $ObservedState
  }

  $merged = [System.Collections.Generic.List[object]]::new()
  foreach ($assignment in $ObservedState.Assignments) {
    $merged.Add($assignment) | Out-Null
  }

  foreach ($snapshotAssignment in $snapshotAssignments) {
    $scopeType = if (Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("locationName", "LocationName")) { "Location" } else { "Organization" }
    $organizationName = Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("organizationName", "OrganizationName")
    $locationName = Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("locationName", "LocationName")
    $policyType = ConvertTo-CanonicalPolicyType -Value (Get-FirstValue -InputObject $snapshotAssignment -PropertyPaths @("policyType", "PolicyType"))
    if (-not $policyType) {
      $policyType = Get-PolicyTypeFromName -Name (Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("policyName", "PolicyName"))
    }

    $scopeObject = $null
    if ($scopeType -eq "Location") {
      $scopeObject = @($ObservedState.Locations | Where-Object {
        $_.Name -and $locationName -and $_.Name -ieq $locationName -and
        (-not $organizationName -or ($_.OrganizationName -and $_.OrganizationName -ieq $organizationName))
      } | Select-Object -First 1)
    } else {
      $scopeObject = @($ObservedState.Organizations | Where-Object { $_.Name -and $organizationName -and $_.Name -ieq $organizationName } | Select-Object -First 1)
    }

    if (@($scopeObject).Count -eq 0) {
      continue
    }

    $existing = @($ObservedState.Assignments | Where-Object {
      $_.ScopeType -eq $scopeType -and
      $_.PolicyType -eq $policyType -and
      $_.ScopeId -eq $scopeObject[0].Id
    })

    if (@($existing).Count -gt 0) {
      continue
    }

    $merged.Add((New-NormalizedAssignment `
      -AssignmentId $null `
      -PolicyId (Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("policyId", "PolicyId")) `
      -PolicyName (Get-StringValue -InputObject $snapshotAssignment -PropertyPaths @("policyName", "PolicyName")) `
      -PolicyType $policyType `
      -ScopeType $scopeType `
      -ScopeId $scopeObject[0].Id `
      -ScopeName $scopeObject[0].Name `
      -Enabled (ConvertTo-BooleanOrNull -Value (Get-FirstValue -InputObject $snapshotAssignment -PropertyPaths @("enabled", "Enabled", "status"))) `
      -Settings (ConvertTo-PlainData -InputObject (Get-FirstValue -InputObject $snapshotAssignment -PropertyPaths @("settings", "Settings"))) `
      -UpdatedOn (ConvertTo-DateString -Value (Get-FirstValue -InputObject $snapshotAssignment -PropertyPaths @("updatedOn", "UpdatedOn"))) `
      -EvidenceSource "UIFallback" `
      -Raw (ConvertTo-PlainData -InputObject $snapshotAssignment)
    )) | Out-Null
  }

  $ObservedState.Assignments = Remove-DuplicateAssignments -Assignments @($merged)
  $ObservedState.UiFallbackUsed = $true
  return $ObservedState
}

function Invoke-UiFallback {
  param(
    [Parameter(Mandatory)] [object] $NormalizedConfig,
    [Parameter(Mandatory)] [string] $ConfigPath
  )

  $uiConfig = $NormalizedConfig.UiFallback
  if ($uiConfig -isnot [System.Collections.IDictionary]) {
    throw "UiFallback configuration is missing from the config file."
  }

  $outputPathValue = [string]$uiConfig.OutputJsonPath
  if ([string]::IsNullOrWhiteSpace($outputPathValue)) {
    $outputPathValue = ".\datto-edr-ui-snapshot.json"
  }
  $outputPath = Resolve-AbsolutePath -Path $outputPathValue -BaseDirectory $NormalizedConfig.BaseDirectory

  $commandTemplate = [string]$uiConfig.Command
  if ([string]::IsNullOrWhiteSpace($commandTemplate)) {
    $commandTemplate = "npx tsx datto-edr-headless/datto-edr-policy-snapshot.ts --config <CONFIG_PATH> --output <OUTPUT_PATH>"
  }

  $command = $commandTemplate.Replace("<CONFIG_PATH>", ('"{0}"' -f (Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory $NormalizedConfig.BaseDirectory))).Replace("<OUTPUT_PATH>", ('"{0}"' -f $outputPath))

  Write-Step "Running Datto EDR UI fallback snapshot."
  try {
    Invoke-Expression $command | Out-Host
  } catch {
    throw "UI fallback command failed: $($_.Exception.Message)"
  }

  if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "UI fallback did not produce the expected snapshot file: $outputPath"
  }

  return (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json)
}

function Get-AuditRows {
  param(
    [Parameter(Mandatory)] [object] $NormalizedConfig,
    [Parameter(Mandatory)] [object] $ObservedState,
    [string[]] $OnlyOrganizations,
    [string[]] $OnlyLocations
  )

  $scopes = Filter-Scopes -Scopes (Get-ScopeObjects -Organizations $ObservedState.Organizations -Locations $ObservedState.Locations) -OnlyOrganizations $OnlyOrganizations -OnlyLocations $OnlyLocations
  if (@($scopes).Count -eq 0) {
    throw "No organizations or locations matched the requested filters."
  }

  $rows = [System.Collections.Generic.List[object]]::new()
  $policyTypes = @($NormalizedConfig.PolicyBaselines.PolicyType | Sort-Object -Unique)

  foreach ($scope in $scopes) {
    foreach ($policyType in $policyTypes) {
      $baseline = Get-PolicyBaseline -PolicyBaselines $NormalizedConfig.PolicyBaselines -PolicyType $policyType
      if (@($baseline).Count -eq 0) {
        continue
      }

      $expectedPolicyName = Resolve-ExpectedPolicyName -Scope $scope -PolicyType $policyType -PolicyBaselines $NormalizedConfig.PolicyBaselines -AssignmentRules $NormalizedConfig.AssignmentRules
      $expectedEnabled = $baseline[0].ExpectedEnabled
      $expectedSettings = $baseline[0].ExpectedSettings

      $effective = Resolve-EffectiveAssignment -Scope $scope -PolicyType $policyType -Assignments $ObservedState.Assignments
      $effectiveMatches = @($effective.EffectiveMatches)
      $policyRecord = @($ObservedState.Policies | Where-Object { $_.Name -and $_.Name -ieq $expectedPolicyName } | Select-Object -First 1)

      $assignmentStatus = "Compliant"
      $assignmentMissing = @()
      $assignmentNotes = @()
      $actualPolicyName = $null
      $actualEnabled = $null
      $evidenceSource = $null

      if (@($effectiveMatches).Count -eq 0) {
        if ($ObservedState.UiFallbackError) {
          $assignmentStatus = "ManualVerificationRequired"
          $assignmentMissing += "AssignmentNotObserved"
          $assignmentNotes += $ObservedState.UiFallbackError
        } else {
          $assignmentStatus = "Missing"
          $assignmentMissing += "AssignmentNotObserved"
        }
      } elseif (@($effectiveMatches).Count -gt 1) {
        $assignmentStatus = "Missing"
        $assignmentMissing += "MultipleEffectiveAssignments"
        $assignmentNotes += ("Effective assignments found: {0}" -f ($effectiveMatches.PolicyName -join ", "))
      } else {
        $actualPolicyName = $effectiveMatches[0].PolicyName
        $actualEnabled = if ($null -ne $effectiveMatches[0].Enabled) { $effectiveMatches[0].Enabled } elseif (@($policyRecord).Count -gt 0) { $policyRecord[0].Enabled } else { $null }
        $evidenceSource = $effectiveMatches[0].EvidenceSource

        if ([string]::IsNullOrWhiteSpace($actualPolicyName) -or $actualPolicyName -ine $expectedPolicyName) {
          $assignmentStatus = "Missing"
          $assignmentMissing += ("ExpectedPolicy:{0}" -f $expectedPolicyName)
        }
      }

      $assignmentRow = New-FindingRow -Scope $scope -PolicyType $policyType -ControlName "PolicyAssignment" -ValidationStatus $assignmentStatus -MissingItems $assignmentMissing -EvidenceSource $evidenceSource -Notes ($assignmentNotes -join " | ") -ExpectedPolicyName $expectedPolicyName -ActualPolicyName $actualPolicyName -ExpectedEnabled $expectedEnabled -ActualEnabled $actualEnabled
      $exception = Resolve-AllowedException -Row $assignmentRow -AllowedExceptions $NormalizedConfig.AllowedExceptions
      if ($exception) {
        $assignmentRow.ValidationStatus = "Exception"
        $assignmentRow.Notes = (($assignmentRow.Notes, $exception.Notes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
      }
      $rows.Add($assignmentRow) | Out-Null

      $enabledStatus = "Compliant"
      $enabledMissing = @()
      $enabledNotes = @()
      if ($assignmentRow.ValidationStatus -in @("Missing", "ManualVerificationRequired")) {
        $enabledStatus = $assignmentRow.ValidationStatus
        $enabledMissing = @($assignmentRow.MissingItems)
        $enabledNotes += "Enabled-state check depends on effective assignment."
      } elseif (@($policyRecord).Count -eq 0 -and -not $actualPolicyName) {
        $enabledStatus = "Missing"
        $enabledMissing += ("PolicyNotFound:{0}" -f $expectedPolicyName)
      } else {
        $actualPolicy = if (@($policyRecord).Count -gt 0) { $policyRecord[0] } else { $null }
        if ($null -eq $actualEnabled -and $null -ne $actualPolicy) {
          $actualEnabled = $actualPolicy.Enabled
        }
        if ($null -ne $expectedEnabled -and $expectedEnabled -ne $actualEnabled) {
          $enabledStatus = "Missing"
          $enabledMissing += ("ExpectedEnabled:{0}" -f $expectedEnabled)
        }
      }

      $enabledPolicyName = if (-not [string]::IsNullOrWhiteSpace($actualPolicyName)) { $actualPolicyName } else { $expectedPolicyName }
      $enabledRow = New-FindingRow -Scope $scope -PolicyType $policyType -ControlName "PolicyEnabled" -ValidationStatus $enabledStatus -MissingItems $enabledMissing -EvidenceSource $evidenceSource -Notes ($enabledNotes -join " | ") -ExpectedPolicyName $expectedPolicyName -ActualPolicyName $enabledPolicyName -ExpectedEnabled $expectedEnabled -ActualEnabled $actualEnabled
      $exception = Resolve-AllowedException -Row $enabledRow -AllowedExceptions $NormalizedConfig.AllowedExceptions
      if ($exception) {
        $enabledRow.ValidationStatus = "Exception"
        $enabledRow.Notes = (($enabledRow.Notes, $exception.Notes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
      }
      $rows.Add($enabledRow) | Out-Null

      $settingsStatus = "Compliant"
      $settingsMissing = @()
      $settingsNotes = @()
      if ($assignmentRow.ValidationStatus -in @("Missing", "ManualVerificationRequired")) {
        $settingsStatus = $assignmentRow.ValidationStatus
        $settingsMissing = @($assignmentRow.MissingItems)
        $settingsNotes += "Settings check depends on effective assignment."
      } else {
        $actualPolicy = if (@($policyRecord).Count -gt 0) { $policyRecord[0] } else { $null }
        if ($null -eq $actualPolicy) {
          $settingsStatus = "Missing"
          $settingsMissing += ("PolicyNotFound:{0}" -f $expectedPolicyName)
        } else {
          $settingsDiffs = @(Compare-ExpectedSettings -Expected $expectedSettings -Actual $actualPolicy.Settings)
          if (@($settingsDiffs).Count -gt 0) {
            $settingsStatus = "Missing"
            $settingsMissing += $settingsDiffs
          }
        }
      }

      $settingsPolicyName = if (-not [string]::IsNullOrWhiteSpace($actualPolicyName)) { $actualPolicyName } else { $expectedPolicyName }
      $settingsRow = New-FindingRow -Scope $scope -PolicyType $policyType -ControlName "PolicySettings" -ValidationStatus $settingsStatus -MissingItems $settingsMissing -EvidenceSource $evidenceSource -Notes ($settingsNotes -join " | ") -ExpectedPolicyName $expectedPolicyName -ActualPolicyName $settingsPolicyName -ExpectedEnabled $expectedEnabled -ActualEnabled $actualEnabled
      $exception = Resolve-AllowedException -Row $settingsRow -AllowedExceptions $NormalizedConfig.AllowedExceptions
      if ($exception) {
        $settingsRow.ValidationStatus = "Exception"
        $settingsRow.Notes = (($settingsRow.Notes, $exception.Notes) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
      }
      $rows.Add($settingsRow) | Out-Null
    }
  }

  return @($rows)
}

function Get-AuditSummary {
  param([Parameter(Mandatory)] [object[]] $Rows)

  $compliant = @($Rows | Where-Object { $_.ValidationStatus -eq "Compliant" })
  $missing = @($Rows | Where-Object { $_.ValidationStatus -eq "Missing" })
  $exceptions = @($Rows | Where-Object { $_.ValidationStatus -eq "Exception" })
  $manual = @($Rows | Where-Object { $_.ValidationStatus -eq "ManualVerificationRequired" })

  [ordered]@{
    Controls                 = $Rows.Count
    AlreadyCompliant         = $compliant.Count
    Missing                  = $missing.Count
    Exceptions               = $exceptions.Count
    ManualVerificationNeeded = $manual.Count
    StillMissing             = ($missing.Count + $manual.Count)
  }
}

function Write-AuditReport {
  param(
    [Parameter(Mandatory)] [object[]] $Rows,
    [Parameter(Mandatory)] [System.Collections.IDictionary] $Summary
  )

  Write-Step ("Audit summary: controls={0}, already-compliant={1}, missing={2}, exceptions={3}, manual-verification={4}, still-missing={5}" -f `
    $Summary.Controls, $Summary.AlreadyCompliant, $Summary.Missing, $Summary.Exceptions, $Summary.ManualVerificationNeeded, $Summary.StillMissing)

  foreach ($row in $Rows) {
    $missingText = if ($row.MissingCount -eq 0) { "none" } else { ($row.MissingItems -join ", ") }
    Write-Host ("[datto-edr-policy-audit][audit] {0}/{1}/{2} | status={3} | expected={4} | actual={5} | missing={6}" -f `
      $row.Organization, $row.Location, $row.PolicyType, $row.ValidationStatus, $row.ExpectedPolicyName, $row.ActualPolicyName, $missingText)
  }
}

function Export-AuditOutputs {
  param(
    [Parameter(Mandatory)] [string] $CsvPath,
    [Parameter(Mandatory)] [string] $JsonPath,
    [Parameter(Mandatory)] [object] $NormalizedConfig,
    [Parameter(Mandatory)] [object] $ObservedState,
    [Parameter(Mandatory)] [object[]] $Rows,
    [Parameter(Mandatory)] [System.Collections.IDictionary] $Summary
  )

  $csvDirectory = Split-Path -Parent $CsvPath
  $jsonDirectory = Split-Path -Parent $JsonPath
  if ($csvDirectory -and -not (Test-Path -LiteralPath $csvDirectory)) {
    New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
  }
  if ($jsonDirectory -and -not (Test-Path -LiteralPath $jsonDirectory)) {
    New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
  }

  $Rows | Select-Object `
    Organization, OrganizationId, Location, LocationId, PolicyType, ControlName, ValidationStatus, `
    @{ Name = "MissingItems"; Expression = { $_.MissingItems -join "; " } }, `
    MissingCount, ExpectedPolicyName, ActualPolicyName, ExpectedEnabled, ActualEnabled, EvidenceSource, Notes |
    Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

  $payload = [ordered]@{
    RunInfo = [ordered]@{
      StartedAt       = (Get-Date).ToString("o")
      InstanceUrl     = $NormalizedConfig.InstanceUrl
      UiFallbackUsed  = $ObservedState.UiFallbackUsed
      UiFallbackError = $ObservedState.UiFallbackError
      Warnings        = @($script:Warnings)
      BlockingIssues  = @($script:BlockingIssues)
    }
    Summary             = $Summary
    Baseline            = [ordered]@{
      PolicyBaselines   = $NormalizedConfig.PolicyBaselines
      AssignmentRules   = $NormalizedConfig.AssignmentRules
      AllowedExceptions = $NormalizedConfig.AllowedExceptions
    }
    ObservedState       = [ordered]@{
      Discovery         = $ObservedState.Discovery
      Policies          = $ObservedState.Policies
      Organizations     = $ObservedState.Organizations
      Locations         = $ObservedState.Locations
      Assignments       = $ObservedState.Assignments
      UiFallbackUsed    = $ObservedState.UiFallbackUsed
      UiFallbackError   = $ObservedState.UiFallbackError
    }
    Findings            = $Rows
    RecentPolicyChanges = $ObservedState.RecentPolicyChanges
  }

  $payload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}

function Invoke-CaseAssertion {
  param(
    [Parameter(Mandatory)] [string] $CaseName,
    [Parameter(Mandatory)] [object[]] $Rows,
    [Parameter(Mandatory)] [hashtable] $Expected
  )

  foreach ($key in $Expected.Keys) {
    $value = $Expected[$key]
    switch ($key) {
      "StillMissing" {
        $actual = @($Rows | Where-Object { $_.ValidationStatus -in @("Missing", "ManualVerificationRequired") }).Count
        if ($actual -ne $value) {
          throw "$CaseName expected StillMissing=$value but got $actual."
        }
      }
      "Exceptions" {
        $actual = @($Rows | Where-Object { $_.ValidationStatus -eq "Exception" }).Count
        if ($actual -ne $value) {
          throw "$CaseName expected Exceptions=$value but got $actual."
        }
      }
      "ManualVerificationRequired" {
        $actual = @($Rows | Where-Object { $_.ValidationStatus -eq "ManualVerificationRequired" }).Count
        if ($actual -ne $value) {
          throw "$CaseName expected ManualVerificationRequired=$value but got $actual."
        }
      }
      "AssignmentStatus" {
        $actual = @($Rows | Where-Object { $_.ControlName -eq "PolicyAssignment" }).ValidationStatus | Select-Object -First 1
        if ($actual -ne $value) {
          throw "$CaseName expected PolicyAssignment=$value but got $actual."
        }
      }
      "SettingsStatus" {
        $actual = @($Rows | Where-Object { $_.ControlName -eq "PolicySettings" }).ValidationStatus | Select-Object -First 1
        if ($actual -ne $value) {
          throw "$CaseName expected PolicySettings=$value but got $actual."
        }
      }
    }
  }
}

function Invoke-DattoEdrPolicyAuditSelfTest {
  $config = @{
    InstanceUrl = "https://example.infocyte.com"
    TokenEnvVar = "DATTO_EDR_TOKEN"
    PolicyBaselines = @{
      "Datto EDR" = @{
        ExpectedPolicyName = "Standard EDR"
        ExpectedEnabled = $true
        ExpectedSettings = @{
          isolation = @{
            allow = $true
          }
        }
      }
    }
    AssignmentRules = @(
      @{
        OrganizationName = "*"
        LocationName = "*"
        Policies = @{
          "Datto EDR" = "Standard EDR"
        }
      }
    )
    AllowedExceptions = @(
      @{
        OrganizationName = "Exception Org"
        LocationName = "Legacy"
        PolicyType = "Datto EDR"
        ControlName = "PolicyAssignment"
        ExpiresOn = "2099-12-31"
        Notes = "Approved variance"
      }
    )
  }

  $normalizedConfig = Normalize-BaselineConfig -Config $config -BaseDirectory (Get-Location).Path

  function New-ObservedState {
    param(
      [string] $OrganizationName,
      [string] $LocationName,
      [string] $PolicyName,
      [bool] $Enabled,
      [bool] $IsolationAllowed,
      [switch] $MissingAssignment,
      [switch] $UiFallbackError
    )

    $policy = [pscustomobject]@{
      Id = "policy-1"
      Name = $PolicyName
      PolicyType = "Datto EDR"
      Enabled = $Enabled
      Settings = @{
        isolation = @{
          allow = $IsolationAllowed
        }
      }
      EvidenceSource = "API"
      Raw = @{}
      UpdatedOn = (Get-Date).ToString("o")
    }

    $organization = [pscustomobject]@{
      Id = "org-1"
      Name = $OrganizationName
      Raw = @{}
      EvidenceSource = "API"
    }

    $location = [pscustomobject]@{
      Id = "loc-1"
      Name = $LocationName
      OrganizationId = "org-1"
      OrganizationName = $OrganizationName
      Raw = @{}
      EvidenceSource = "API"
    }

    $assignments = @()
    if (-not $MissingAssignment) {
      $assignments += New-NormalizedAssignment -AssignmentId "assign-1" -PolicyId "policy-1" -PolicyName $PolicyName -PolicyType "Datto EDR" -ScopeType "Location" -ScopeId "loc-1" -ScopeName $LocationName -Enabled $Enabled -Settings $policy.Settings -UpdatedOn (Get-Date).ToString("o") -EvidenceSource "API" -Raw @{}
    }

    return [pscustomobject]@{
      Discovery = @{}
      Policies = @($policy)
      Organizations = @($organization)
      Locations = @($location)
      Assignments = @($assignments)
      RecentPolicyChanges = @()
      UiFallbackUsed = $false
      UiFallbackError = if ($UiFallbackError) { "UI selectors drifted." } else { $null }
    }
  }

  $cases = @(
    @{
      Name = "fully compliant"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $true -IsolationAllowed $true
      Expected = @{ StillMissing = 0; AssignmentStatus = "Compliant"; SettingsStatus = "Compliant" }
    },
    @{
      Name = "wrong policy assignment"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Wrong EDR" -Enabled $true -IsolationAllowed $true
      Expected = @{ StillMissing = 3; AssignmentStatus = "Missing" }
    },
    @{
      Name = "disabled policy"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $false -IsolationAllowed $true
      Expected = @{ StillMissing = 1; AssignmentStatus = "Compliant" }
    },
    @{
      Name = "setting drift"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $true -IsolationAllowed $false
      Expected = @{ StillMissing = 1; SettingsStatus = "Missing" }
    },
    @{
      Name = "missing policy assignment"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $true -IsolationAllowed $true -MissingAssignment
      Expected = @{ StillMissing = 3; AssignmentStatus = "Missing" }
    },
    @{
      Name = "approved exception"
      Observed = New-ObservedState -OrganizationName "Exception Org" -LocationName "Legacy" -PolicyName "Wrong EDR" -Enabled $true -IsolationAllowed $true
      Expected = @{ StillMissing = 1; Exceptions = 1; AssignmentStatus = "Exception" }
    },
    @{
      Name = "ui fallback merge"
      Observed = (Merge-UiFallbackSnapshot -ObservedState (New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $true -IsolationAllowed $true -MissingAssignment) -Snapshot @{
        assignments = @(
          @{
            organizationName = "Org A"
            locationName = "Main"
            policyType = "Datto EDR"
            policyName = "Standard EDR"
            enabled = $true
          }
        )
      })
      Expected = @{ StillMissing = 0; AssignmentStatus = "Compliant" }
    },
    @{
      Name = "ui fallback failure"
      Observed = New-ObservedState -OrganizationName "Org A" -LocationName "Main" -PolicyName "Standard EDR" -Enabled $true -IsolationAllowed $true -MissingAssignment -UiFallbackError
      Expected = @{ StillMissing = 3; ManualVerificationRequired = 3; AssignmentStatus = "ManualVerificationRequired" }
    }
  )

  $results = foreach ($case in $cases) {
    $rows = Get-AuditRows -NormalizedConfig $normalizedConfig -ObservedState $case.Observed
    Invoke-CaseAssertion -CaseName $case.Name -Rows $rows -Expected $case.Expected
    [pscustomobject]@{
      Test   = $case.Name
      Passed = $true
    }
  }

  $results | Format-Table -AutoSize | Out-Host
  Write-Host ("Self-test passed ({0} cases)." -f $results.Count)
}

if ($PSCmdlet.ParameterSetName -eq "SelfTest") {
  Invoke-DattoEdrPolicyAuditSelfTest
  return
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Config file not found: $ConfigPath"
}

$resolvedConfigPath = Resolve-AbsolutePath -Path $ConfigPath -BaseDirectory (Get-Location).Path
$configDirectory = Split-Path -Parent $resolvedConfigPath
$rawConfig = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$configHashtable = ConvertTo-PlainData -InputObject $rawConfig
$normalizedConfig = Normalize-BaselineConfig -Config $configHashtable -BaseDirectory $configDirectory

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $OutputCsvPath = Join-Path -Path $PSScriptRoot -ChildPath "artifacts\datto-edr\datto-edr-policy-audit.csv"
}
if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  $OutputJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "artifacts\datto-edr\datto-edr-policy-audit.json"
}

$resolvedCsvPath = Resolve-AbsolutePath -Path $OutputCsvPath -BaseDirectory $configDirectory
$resolvedJsonPath = Resolve-AbsolutePath -Path $OutputJsonPath -BaseDirectory $configDirectory

Write-Step "Starting Datto EDR policy audit."
$observedState = Get-NormalizedObservedStateFromApi -Config $configHashtable -UseUiFallbackRequested:$UseUiFallback

if ($UseUiFallback) {
  try {
    $uiSnapshot = Invoke-UiFallback -NormalizedConfig $normalizedConfig -ConfigPath $resolvedConfigPath
    $observedState = Merge-UiFallbackSnapshot -ObservedState $observedState -Snapshot $uiSnapshot
  } catch {
    $observedState.UiFallbackError = $_.Exception.Message
    Add-BlockingIssue -Message ("UI fallback failed. Manual verification is required for any unresolved assignments. {0}" -f $_.Exception.Message)
  }
}

$rows = Get-AuditRows -NormalizedConfig $normalizedConfig -ObservedState $observedState -OnlyOrganizations $OnlyOrganizations -OnlyLocations $OnlyLocations
$summary = Get-AuditSummary -Rows $rows
Write-AuditReport -Rows $rows -Summary $summary
Export-AuditOutputs -CsvPath $resolvedCsvPath -JsonPath $resolvedJsonPath -NormalizedConfig $normalizedConfig -ObservedState $observedState -Rows $rows -Summary $summary

Write-Step "CSV written to: $resolvedCsvPath"
Write-Step "JSON written to: $resolvedJsonPath"

if ($script:BlockingIssues.Count -gt 0) {
  throw ("Audit completed with blocking issues: {0}" -f ($script:BlockingIssues -join " | "))
}

$rows
