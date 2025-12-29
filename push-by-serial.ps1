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
$ContinueOnError   = $false

# File generated for you from your spreadsheet:
$AddressObjectsJsonPath = "C:\Path\To\sonicos-address-objects-ipv4.json"

# Most common NSM proxy base for SonicOS APIs (adjust if your tenant uses a different path)
$SonicosProxyBase  = "$NsmBaseUrl/api/manager/firewall/sonicos"

# SonicOS paths (these are stable on-box; NSM proxies them)
$CreateAddrObjectsPath = "/address-objects/ipv4"
$CommitPendingPath     = "/config/pending"

if ([string]::IsNullOrWhiteSpace($BearerToken) -or $BearerToken -eq "REPLACE_ME") {
  throw "Set `\$BearerToken` to a valid NSM bearer token before running."
}

$FirewallSerials = $FirewallSerials |
  ForEach-Object { $_.ToString().Trim() } |
  Where-Object { $_ -ne "" } |
  Select-Object -Unique

if (-not $FirewallSerials -or $FirewallSerials.Count -eq 0) {
  throw "Provide at least one firewall serial in `\$FirewallSerials`."
}

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
      return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $BodyJson -TimeoutSec 120 -ErrorAction Stop
    } else {
      return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -TimeoutSec 120 -ErrorAction Stop
    }
  } catch {
    $msg = $_.Exception.Message
    $details = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $details = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
      try {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $details = $reader.ReadToEnd()
        $reader.Dispose()
      } catch {
      }
    }
    if ($details) {
      $msg = "$msg :: $details"
    }
    throw "API call failed for serial [$FirewallSerial] $Method $Url :: $msg"
  }
}

# Load payload once
if (-not (Test-Path $AddressObjectsJsonPath)) {
  throw "JSON file not found: $AddressObjectsJsonPath"
}
$payloadJson = Get-Content -Raw -Path $AddressObjectsJsonPath
if ([string]::IsNullOrWhiteSpace($payloadJson)) {
  throw "JSON file is empty: $AddressObjectsJsonPath"
}
try {
  $null = $payloadJson | ConvertFrom-Json
} catch {
  throw "JSON file is invalid: $AddressObjectsJsonPath"
}

$failedSerials = New-Object System.Collections.Generic.List[string]

foreach ($serial in $FirewallSerials) {
  Write-Host "=== $serial ==="

  # 1) Create address objects (IPv4 hosts)
  $urlCreate = "$SonicosProxyBase$CreateAddrObjectsPath"
  Write-Host "Creating address objects: $urlCreate"
  try {
    Invoke-NsmFirewallApi -FirewallSerial $serial -Method "POST" -Url $urlCreate -BodyJson $payloadJson | Out-Null

    # 2) Commit pending config (save changes)
    $urlCommit = "$SonicosProxyBase$CommitPendingPath"
    Write-Host "Committing pending config: $urlCommit"
    Invoke-NsmFirewallApi -FirewallSerial $serial -Method "POST" -Url $urlCommit -BodyJson "" | Out-Null

    Write-Host "Done: $serial"
  } catch {
    Write-Warning "Failed: $serial :: $($_.Exception.Message)"
    $failedSerials.Add($serial)
    if (-not $ContinueOnError) {
      throw
    }
  }
}

if ($failedSerials.Count -gt 0) {
  Write-Warning ("Completed with {0} failure(s): {1}" -f $failedSerials.Count, ($failedSerials -join ", "))
} else {
  Write-Host "All complete."
}
