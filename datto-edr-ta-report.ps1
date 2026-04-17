[CmdletBinding()]
param(
  [string] $ApiHost,

  [string] $ApiToken,

  [string] $TokenEnvVar = "DATTO_EDR_TOKEN",

  [string] $EnvFile,

  [string] $OutputCsvPath,

  [string] $OutputPoliciesCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

  try {
    return Invoke-RestMethod -Uri $fullUri -Method GET -ContentType 'application/json'
  } catch {
    if ($NoThrow) { return $null }
    $msg = $_.Exception.Message
    if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
      $msg = "{0} | Response: {1}" -f $msg, $_.ErrorDetails.Message
    }
    throw "API request failed for '/$relative': $msg"
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

    foreach ($item in $batch) { $results.Add($item) }
    if ($batch.Count -lt $PageSize) { break }

    $lastId = $batch[-1].id
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
    '^(datto\s+av|datto\s+antivirus|antivirus|av)$'    { return "Datto AV" }
    '^(ransomware|ransomware\s+detection)$'             { return "Ransomware" }
    '^(windows\s+defender|defender|microsoft\s+defender)$' { return "Windows Defender" }
    '^(automated\s+response|response)$'                 { return "Automated Response" }
    default                                             { return $text.Trim() }
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

# ---------------------------------------------------------------------------
# Resolve credentials (env file > parameters > environment variables)
# ---------------------------------------------------------------------------

$resolvedHost  = $ApiHost
$resolvedToken = $ApiToken

if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
  Write-Step "Loading credentials from: $EnvFile"
  $envVars = Read-EnvFile -Path $EnvFile
  if ([string]::IsNullOrWhiteSpace($resolvedHost)  -and $envVars.ContainsKey("DATTO_EDR_HOST"))  { $resolvedHost  = $envVars["DATTO_EDR_HOST"] }
  if ([string]::IsNullOrWhiteSpace($resolvedToken) -and $envVars.ContainsKey("DATTO_EDR_TOKEN")) { $resolvedToken = $envVars["DATTO_EDR_TOKEN"] }
} elseif (Test-Path (Join-Path (Split-Path $PSCommandPath -Parent) "datto-edr.env")) {
  $defaultEnv = Join-Path (Split-Path $PSCommandPath -Parent) "datto-edr.env"
  Write-Step "Loading credentials from: $defaultEnv"
  $envVars = Read-EnvFile -Path $defaultEnv
  if ([string]::IsNullOrWhiteSpace($resolvedHost)  -and $envVars.ContainsKey("DATTO_EDR_HOST"))  { $resolvedHost  = $envVars["DATTO_EDR_HOST"] }
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
$datestamp = (Get-Date).ToString("yyyy-MM-dd")

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $OutputCsvPath = Join-Path $artifactsDir "ta-report-enrollment-$datestamp.csv"
}
if ([string]::IsNullOrWhiteSpace($OutputPoliciesCsvPath)) {
  $OutputPoliciesCsvPath = Join-Path $artifactsDir "ta-report-policies-$datestamp.csv"
}

# ---------------------------------------------------------------------------
# Fetch data
# ---------------------------------------------------------------------------

Write-Step "Fetching organizations..."
$organizations = Get-EdrAll -BaseUrl $baseUrl -Token $resolvedToken -Endpoint "organizations"
if ($null -eq $organizations) { $organizations = @() }
Write-Step "  $($organizations.Count) organizations found."

Write-Step "Fetching locations/targets..."
$locations = Get-EdrAll -BaseUrl $baseUrl -Token $resolvedToken -Endpoint "targets" -NoThrow
if ($null -eq $locations) {
  $locations = Get-EdrAll -BaseUrl $baseUrl -Token $resolvedToken -Endpoint "locations" -NoThrow
}
if ($null -eq $locations) { $locations = @() }
Write-Step "  $($locations.Count) locations/targets found."

Write-Step "Fetching policies..."
$policies = Get-EdrAll -BaseUrl $baseUrl -Token $resolvedToken -Endpoint "policies" -NoThrow
if ($null -eq $policies) { $policies = @() }
Write-Step "  $($policies.Count) policies found."

# ---------------------------------------------------------------------------
# Build org lookup
# ---------------------------------------------------------------------------

$orgById = @{}
foreach ($o in $organizations) {
  $id = Get-StringProp -Obj $o -Names @("id")
  if ($id) { $orgById[$id] = $o }
}

# ---------------------------------------------------------------------------
# Build enrollment report (one row per org/location)
# ---------------------------------------------------------------------------

Write-Step ""
Write-Step "Building enrollment report..."

$enrollmentRows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($loc in $locations) {
  $locId   = Get-StringProp -Obj $loc -Names @("id")
  $locName = Get-StringProp -Obj $loc -Names @("name", "displayName")
  $orgId   = Get-StringProp -Obj $loc -Names @("organizationId", "orgId")

  $orgName = "(unresolved)"
  if ($orgId -and $orgById.ContainsKey($orgId)) {
    $orgName = Get-StringProp -Obj $orgById[$orgId] -Names @("name", "displayName")
    if (-not $orgName) { $orgName = $orgId }
  } elseif ($orgId) {
    $orgName = $orgId
  }

  $agentCount       = Get-NumProp -Obj $loc -Names @("agentCount")
  $activeAgentCount = Get-NumProp -Obj $loc -Names @("activeAgentCount")
  $alertCount       = Get-NumProp -Obj $loc -Names @("alertCount")
  $lastScan         = Format-Date (Get-StringProp -Obj $loc -Names @("lastScannedOn", "lastScan", "lastActivity"))
  $status           = Get-EnrollmentStatus -AgentCount $agentCount -ActiveAgentCount $activeAgentCount
  $rmmUid           = $null
  try { $rmmUid = $loc.data.rmmUid } catch {}
  if (-not $rmmUid) { $rmmUid = "" }

  $enrollmentRows.Add([pscustomobject][ordered]@{
    Organization      = if ($orgName) { $orgName } else { "(unresolved)" }
    Location          = if ($locName) { $locName } else { $locId }
    EnrollmentStatus  = $status
    AgentCount        = $agentCount
    ActiveAgentCount  = $activeAgentCount
    AlertCount        = $alertCount
    LastScanDate      = $lastScan
    RmmSiteId         = $rmmUid
    LocationId        = if ($locId) { $locId } else { "" }
    OrganizationId    = if ($orgId) { $orgId } else { "" }
  })
}

# Orgs with no matching location (no location record yet)
$locOrgIds = @($locations | ForEach-Object { Get-StringProp -Obj $_ -Names @("organizationId", "orgId") } | Where-Object { $_ })
foreach ($o in $organizations) {
  $orgId   = Get-StringProp -Obj $o -Names @("id")
  $orgName = Get-StringProp -Obj $o -Names @("name", "displayName")
  if (-not $orgName) { $orgName = $orgId }
  if ($orgId -and $locOrgIds -notcontains $orgId) {
    $enrollmentRows.Add([pscustomobject][ordered]@{
      Organization      = $orgName
      Location          = "(no location record)"
      EnrollmentStatus  = "Not Enrolled"
      AgentCount        = 0
      ActiveAgentCount  = 0
      AlertCount        = 0
      LastScanDate      = ""
      RmmSiteId         = ""
      LocationId        = ""
      OrganizationId    = if ($orgId) { $orgId } else { "" }
    })
  }
}

$sortedEnrollment = @($enrollmentRows | Sort-Object Organization, Location)

# ---------------------------------------------------------------------------
# Build policy inventory
# ---------------------------------------------------------------------------

Write-Step "Building policy inventory..."

$policyRows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($p in $policies) {
  $policyType = ConvertTo-CanonicalPolicyType (Get-StringProp -Obj $p -Names @("type", "policyType", "typeName"))
  $typeName   = Get-StringProp -Obj $p -Names @("typeName")
  $active     = $null
  try { $active = $p.active } catch {}
  $disabled   = $null
  try { $disabled = $p.disabled } catch {}
  $isDefault  = $null
  try { $isDefault = $p.isDefault } catch {}

  $effectiveStatus = "Active"
  if ($active -eq $false) { $effectiveStatus = "Inactive" }
  if ($disabled -eq $true) { $effectiveStatus = "Disabled" }

  $policyRows.Add([pscustomobject][ordered]@{
    PolicyType      = $policyType
    TypeName        = if ($typeName) { $typeName } else { "" }
    PolicyName      = Get-StringProp -Obj $p -Names @("name", "displayName")
    Status          = $effectiveStatus
    Active          = if ($null -ne $active) { [string]$active } else { "" }
    Disabled        = if ($null -ne $disabled) { [string]$disabled } else { "" }
    IsDefault       = if ($null -ne $isDefault) { [string]$isDefault } else { "" }
    Description     = Get-StringProp -Obj $p -Names @("description")
    LastUpdated     = Format-Date (Get-StringProp -Obj $p -Names @("updatedOn", "updatedAt", "modifiedOn"))
    PolicyId        = Get-StringProp -Obj $p -Names @("id")
  })
}

$sortedPolicies = @($policyRows | Sort-Object PolicyType, PolicyName)

# ---------------------------------------------------------------------------
# Write CSVs
# ---------------------------------------------------------------------------

$sortedEnrollment | Export-Csv -Path $OutputCsvPath          -NoTypeInformation -Encoding UTF8
$sortedPolicies   | Export-Csv -Path $OutputPoliciesCsvPath  -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------

$notEnrolled  = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -eq "Not Enrolled" }).Count
$enrolled     = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -ne "Not Enrolled" }).Count
$withAlerts   = @($sortedEnrollment | Where-Object { $_.AlertCount -gt 0 }).Count
$activePols   = @($sortedPolicies   | Where-Object { $_.Status -eq "Active" }).Count

Write-Step ""
Write-Step "=== Summary ==="
Write-Step "  Organizations:    $($organizations.Count)"
Write-Step "  Locations:        $($locations.Count)"
Write-Step "  Enrolled:         $enrolled  |  Not Enrolled: $notEnrolled"
Write-Step "  Locations w/ open alerts: $withAlerts"
Write-Step "  Active policies:  $activePols of $($policies.Count) total"
Write-Step ""
Write-Step "Enrollment report: $OutputCsvPath"
Write-Step "Policy inventory:  $OutputPoliciesCsvPath"

# Show not-enrolled locations inline
$gaps = @($sortedEnrollment | Where-Object { $_.EnrollmentStatus -eq "Not Enrolled" })
if ($gaps.Count -gt 0) {
  Write-Step ""
  Write-Step "Locations with no enrolled agents ($($gaps.Count)):"
  foreach ($g in $gaps) {
    Write-Step "  - $($g.Organization) / $($g.Location)"
  }
}
