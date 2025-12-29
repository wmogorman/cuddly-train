<#
Push IPv4 host address objects to many NSM-managed firewalls (by serial) via NSM API.

Requires:
- NSM Bearer token
- Firewall serials (X-device-id header)
- JSON payload in SonicOS format (address_objects array)

Docs reference:
- NSM uses X-device-id header for firewall-specific calls. (SonicWall KB)  https://www.sonicwall.com/support/knowledge-base/nsm-cloud-getting-token-for-msw-and-nsm-apis/kA1VN0000000IwO0AU
- SonicOS address objects POST /api/sonicos/address-objects/ipv4 and commit /api/sonicos/config/pending. (SonicWall KB) https://www.sonicwall.com/support/knowledge-base/adding-multiple-address-objects-using-sonicos-api/kA1VN0000000OLi0AM
#>

$NsmBaseUrl        = "https://nsm-uswest.sonicwall.com"   # <-- change if needed
$BearerToken       = "REPLACE_ME"
$FirewallSerials   = @(
  "SERIAL1",
  "SERIAL2"
  # ...
)

# File generated for you from your spreadsheet:
$AddressObjectsJsonPath = "C:\Path\To\sonicos-address-objects-ipv4.json"

# Most common NSM proxy base for SonicOS APIs (adjust if your tenant uses a different path)
$SonicosProxyBase  = "$NsmBaseUrl/api/manager/firewall/sonicos"

# SonicOS paths (these are stable on-box; NSM proxies them)
$CreateAddrObjectsPath = "/address-objects/ipv4"
$CommitPendingPath     = "/config/pending"

function Invoke-NsmFirewallApi {
  param(
    [Parameter(Mandatory=$true)][string]$FirewallSerial,
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PUT","PATCH","DELETE")][string]$Method,
    [Parameter(Mandatory=$true)][string]$Url,
    [string]$BodyJson
  )

  $headers = @{
    "Authorization" = "Bearer $BearerToken"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
    "X-device-id"   = $FirewallSerial
  }

  try {
    if ($null -ne $BodyJson -and $BodyJson.Trim().Length -gt 0) {
      return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $BodyJson -TimeoutSec 120
    } else {
      return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -TimeoutSec 120
    }
  } catch {
    $msg = $_.Exception.Message
    throw "API call failed for serial [$FirewallSerial] $Method $Url :: $msg"
  }
}

# Load payload once
if (-not (Test-Path $AddressObjectsJsonPath)) {
  throw "JSON file not found: $AddressObjectsJsonPath"
}
$payloadJson = Get-Content -Raw -Path $AddressObjectsJsonPath

foreach ($serial in $FirewallSerials) {
  Write-Host "=== $serial ==="

  # 1) Create address objects (IPv4 hosts)
  $urlCreate = "$SonicosProxyBase$CreateAddrObjectsPath"
  Write-Host "Creating address objects: $urlCreate"
  Invoke-NsmFirewallApi -FirewallSerial $serial -Method "POST" -Url $urlCreate -BodyJson $payloadJson | Out-Null

  # 2) Commit pending config (save changes)
  $urlCommit = "$SonicosProxyBase$CommitPendingPath"
  Write-Host "Committing pending config: $urlCommit"
  Invoke-NsmFirewallApi -FirewallSerial $serial -Method "POST" -Url $urlCommit -BodyJson "" | Out-Null

  Write-Host "Done: $serial"
}

Write-Host "All complete."
