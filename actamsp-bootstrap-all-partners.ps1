[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
  [Parameter(Mandatory)] [string] $ConfigTemplatePath,
  [string] $BootstrapScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath "actamsp-bootstrap.ps1"),
  [string] $OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath ("actamsp-bootstrap-batch-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
  [string] $PartnerTenantId,
  [string[]] $IncludeTenantId,
  [string[]] $ExcludeTenantId,
  [switch] $StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[actamsp-bootstrap-all-partners] $Message"
}

function Get-ConfigValue {
  param(
    [object] $Config,
    [string] $Name
  )

  $value = $Config.$Name
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required config value in template: $Name"
  }
  return $value
}

function Get-GraphCollection {
  param([string] $Uri)

  $items = @()
  $next = $Uri
  while (-not [string]::IsNullOrWhiteSpace($next)) {
    $response = Invoke-MgGraphRequest -Method GET -Uri $next
    if ($response.value) {
      $items += @($response.value)
    }
    $next = $response.'@odata.nextLink'
  }

  return $items
}

function Get-ActiveGdapCustomers {
  $uri = "https://graph.microsoft.com/v1.0/tenantRelationships/delegatedAdminRelationships?`$filter=status eq 'active'&`$select=id,displayName,status,endDateTime,customer"
  $relationships = @(Get-GraphCollection -Uri $uri)

  $byTenant = @{}
  foreach ($relationship in $relationships) {
    if (-not $relationship.customer) { continue }
    $tenantId = $relationship.customer.tenantId
    if ([string]::IsNullOrWhiteSpace($tenantId)) { continue }

    $tenantKey = $tenantId.ToLowerInvariant()
    if (-not $byTenant.ContainsKey($tenantKey)) {
      $byTenant[$tenantKey] = [pscustomobject]@{
        TenantId = $tenantId
        CustomerDisplayName = $relationship.customer.displayName
        RelationshipId = $relationship.id
        RelationshipDisplayName = $relationship.displayName
        RelationshipEndDateTime = $relationship.endDateTime
      }
    }
  }

  return @($byTenant.Values | Sort-Object -Property CustomerDisplayName, TenantId)
}

if (-not (Test-Path -Path $ConfigTemplatePath -PathType Leaf)) {
  throw "Config template file not found: $ConfigTemplatePath"
}
if (-not (Test-Path -Path $BootstrapScriptPath -PathType Leaf)) {
  throw "Bootstrap script file not found: $BootstrapScriptPath"
}

$templateConfig = Get-Content -Path $ConfigTemplatePath -Raw | ConvertFrom-Json
[void](Get-ConfigValue -Config $templateConfig -Name "IntegrationGroupName")
[void](Get-ConfigValue -Config $templateConfig -Name "PilotGroupName")
[void](Get-ConfigValue -Config $templateConfig -Name "AppDisplayName")

$discoveryScopes = @("DelegatedAdminRelationship.Read.All")
Write-Step "Connecting to Microsoft Graph for GDAP discovery"
if ([string]::IsNullOrWhiteSpace($PartnerTenantId)) {
  Connect-MgGraph -Scopes $discoveryScopes | Out-Null
} else {
  Connect-MgGraph -TenantId $PartnerTenantId -Scopes $discoveryScopes | Out-Null
}
Select-MgProfile -Name "v1.0" | Out-Null

$context = Get-MgContext
Write-Step "Connected Graph tenant: $($context.TenantId)"

Write-Step "Discovering active GDAP customer relationships"
$customers = @(Get-ActiveGdapCustomers)
Write-Step "Discovered $($customers.Count) active GDAP customer tenant(s)"

if ($IncludeTenantId -and $IncludeTenantId.Count -gt 0) {
  $includeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($tenant in $IncludeTenantId) { [void]$includeSet.Add($tenant) }
  $customers = @($customers | Where-Object { $includeSet.Contains($_.TenantId) })
  Write-Step "After include filter: $($customers.Count) tenant(s)"
}

if ($ExcludeTenantId -and $ExcludeTenantId.Count -gt 0) {
  $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($tenant in $ExcludeTenantId) { [void]$excludeSet.Add($tenant) }
  $customers = @($customers | Where-Object { -not $excludeSet.Contains($_.TenantId) })
  Write-Step "After exclude filter: $($customers.Count) tenant(s)"
}

if ($customers.Count -eq 0) {
  Write-Step "No customers to process."
  return
}

if ($PSCmdlet.ShouldProcess($OutputDirectory, "Create output directory")) {
  New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$results = @()
$batchStart = Get-Date

foreach ($customer in $customers) {
  $tenantId = $customer.TenantId
  $safeName = if ([string]::IsNullOrWhiteSpace($customer.CustomerDisplayName)) { "unknown" } else { ($customer.CustomerDisplayName -replace '[^a-zA-Z0-9._-]', "_") }
  $tenantConfigPath = Join-Path -Path $OutputDirectory -ChildPath ("tenant-" + $tenantId + ".config.json")
  $tenantStart = Get-Date

  $result = [ordered]@{
    TenantId = $tenantId
    CustomerDisplayName = $customer.CustomerDisplayName
    RelationshipId = $customer.RelationshipId
    RelationshipDisplayName = $customer.RelationshipDisplayName
    RelationshipEndDateTime = $customer.RelationshipEndDateTime
    ConfigPath = $tenantConfigPath
    StartTime = $tenantStart.ToString("o")
    EndTime = $null
    DurationSeconds = $null
    Status = "Pending"
    Error = $null
    AuditPath = $null
    Controls = $null
    AlreadyCompliant = $null
    MissingControls = $null
    RemediatedNow = $null
    StillMissing = $null
  }

  try {
    $tenantConfig = $templateConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $tenantConfig.TenantId = $tenantId

    $configWritten = $false
    if ($PSCmdlet.ShouldProcess($tenantConfigPath, "Write tenant config for $tenantId ($safeName)")) {
      $tenantConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $tenantConfigPath -Encoding UTF8
      $configWritten = $true
    } elseif (Test-Path -Path $tenantConfigPath -PathType Leaf) {
      $configWritten = $true
    }

    if (-not $configWritten) {
      $result.Status = "Skipped"
      $result.Error = "Tenant config file was not written."
      $tenantEnd = Get-Date
      $result.EndTime = $tenantEnd.ToString("o")
      $result.DurationSeconds = [Math]::Round(($tenantEnd - $tenantStart).TotalSeconds, 2)
      $results += [pscustomobject]$result
      continue
    }

    if ($PSCmdlet.ShouldProcess($tenantId, "Run tenant bootstrap script")) {
      Write-Step "Running bootstrap for tenant $tenantId ($($customer.CustomerDisplayName))"
      & $BootstrapScriptPath -ConfigPath $tenantConfigPath -Confirm:$false
      $result.Status = "Success"

      $auditPath = [System.IO.Path]::ChangeExtension($tenantConfigPath, ".audit.json")
      $result.AuditPath = $auditPath
      if (Test-Path -Path $auditPath -PathType Leaf) {
        $audit = Get-Content -Path $auditPath -Raw | ConvertFrom-Json
        if ($audit.Summary) {
          $result.Controls = $audit.Summary.Controls
          $result.AlreadyCompliant = $audit.Summary.AlreadyCompliant
          $result.MissingControls = $audit.Summary.Missing
          $result.RemediatedNow = $audit.Summary.RemediatedNow
          $result.StillMissing = $audit.Summary.StillMissing
        }
      }
    } else {
      $result.Status = "Skipped"
    }
  } catch {
    $result.Status = "Failed"
    $result.Error = $_.Exception.Message
    Write-Warning "Bootstrap failed for tenant $tenantId ($($customer.CustomerDisplayName)): $($result.Error)"
    if ($StopOnError) {
      $tenantEnd = Get-Date
      $result.EndTime = $tenantEnd.ToString("o")
      $result.DurationSeconds = [Math]::Round(($tenantEnd - $tenantStart).TotalSeconds, 2)
      $results += [pscustomobject]$result
      break
    }
  }

  $tenantEnd = Get-Date
  $result.EndTime = $tenantEnd.ToString("o")
  $result.DurationSeconds = [Math]::Round(($tenantEnd - $tenantStart).TotalSeconds, 2)
  $results += [pscustomobject]$result
}

$batchEnd = Get-Date
$totalControls = (@($results | Where-Object { $_.Controls -ne $null } | Measure-Object -Property Controls -Sum).Sum)
$totalMissingControls = (@($results | Where-Object { $_.MissingControls -ne $null } | Measure-Object -Property MissingControls -Sum).Sum)
$totalRemediatedControls = (@($results | Where-Object { $_.RemediatedNow -ne $null } | Measure-Object -Property RemediatedNow -Sum).Sum)
$totalStillMissingControls = (@($results | Where-Object { $_.StillMissing -ne $null } | Measure-Object -Property StillMissing -Sum).Sum)

$summary = [ordered]@{
  PartnerTenantId = $context.TenantId
  BatchStartTime = $batchStart.ToString("o")
  BatchEndTime = $batchEnd.ToString("o")
  DurationSeconds = [Math]::Round(($batchEnd - $batchStart).TotalSeconds, 2)
  Total = $results.Count
  Success = @($results | Where-Object { $_.Status -eq "Success" }).Count
  Failed = @($results | Where-Object { $_.Status -eq "Failed" }).Count
  Skipped = @($results | Where-Object { $_.Status -eq "Skipped" }).Count
  ControlsEvaluated = if ($null -eq $totalControls) { 0 } else { [int]$totalControls }
  MissingControls = if ($null -eq $totalMissingControls) { 0 } else { [int]$totalMissingControls }
  RemediatedControls = if ($null -eq $totalRemediatedControls) { 0 } else { [int]$totalRemediatedControls }
  StillMissingControls = if ($null -eq $totalStillMissingControls) { 0 } else { [int]$totalStillMissingControls }
}

$resultsJsonPath = Join-Path -Path $OutputDirectory -ChildPath "batch-results.json"
$resultsCsvPath = Join-Path -Path $OutputDirectory -ChildPath "batch-results.csv"
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath "batch-summary.json"

if ($PSCmdlet.ShouldProcess($resultsJsonPath, "Write batch results JSON")) {
  $results | ConvertTo-Json -Depth 10 | Set-Content -Path $resultsJsonPath -Encoding UTF8
}
if ($PSCmdlet.ShouldProcess($resultsCsvPath, "Write batch results CSV")) {
  $results | Export-Csv -Path $resultsCsvPath -NoTypeInformation -Encoding UTF8
}
if ($PSCmdlet.ShouldProcess($summaryPath, "Write batch summary JSON")) {
  $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8
}

Write-Step "Batch complete. Success: $($summary.Success), Failed: $($summary.Failed), Skipped: $($summary.Skipped), Total: $($summary.Total)"
Write-Step "Audit totals. Controls: $($summary.ControlsEvaluated), Missing: $($summary.MissingControls), Remediated: $($summary.RemediatedControls), Still missing: $($summary.StillMissingControls)"
Write-Step "Output directory: $OutputDirectory"
