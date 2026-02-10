<#
.HardMatch-OptionA (AD + 365 GUI pickers)
  - Pick ONE on-prem AD user
  - Pick ONE Microsoft 365 (Entra ID) user via GUI search (or browse-all fallback)
  - Set onPremisesImmutableId on the cloud user via Microsoft Graph (hard match)

  Includes:
    - Silent NuGet/PSGallery bootstrap
    - Auto-install MS Graph (Authentication + Users) and RSAT AD module
    - Interactive Graph login (no device code)
    - CSV logging with timestamps

  After hard-matching, enable Entra Connect (sourceAnchor) and run:
    Start-ADSyncSyncCycle -PolicyType Delta
#>

[CmdletBinding()]
param()

function Write-Info   { param($m) Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Warn   { param($m) Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Error2 { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-Ok     { param($m) Write-Host "[ OK  ] $m" -ForegroundColor Green }

# --- CSV path ---
$DefaultCsv = Join-Path -Path $PSScriptRoot -ChildPath ("HardMatch_Results_{0:yyyyMMdd}.csv" -f (Get-Date))
$ResultsCsv = Read-Host -Prompt "Enter results CSV path (press Enter for default: $DefaultCsv)"
if ([string]::IsNullOrWhiteSpace($ResultsCsv)) { $ResultsCsv = $DefaultCsv }
if (-not (Test-Path (Split-Path $ResultsCsv -Parent))) { New-Item -ItemType Directory -Path (Split-Path $ResultsCsv -Parent) | Out-Null }
if (-not (Test-Path $ResultsCsv)) {
  "Timestamp,AdDisplayName,AdSam,AdUPN,CloudUPN,CloudId,AnchorBase64,Outcome,Details" | Out-File -FilePath $ResultsCsv -Encoding UTF8
  Write-Info "Created results CSV: $ResultsCsv"
} else {
  Write-Info "Appending to results CSV: $ResultsCsv"
}

function Add-ResultRow {
  param(
    [string]$Outcome, [string]$Details,
    [string]$AdDisplayName, [string]$AdSam, [string]$AdUPN,
    [string]$CloudUPN, [string]$CloudId, [string]$AnchorBase64
  )
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = '"' + ($ts -replace '"','""') + '",' +
          '"' + ($AdDisplayName -replace '"','""') + '",' +
          '"' + ($AdSam -replace '"','""') + '",' +
          '"' + ($AdUPN -replace '"','""') + '",' +
          '"' + ($CloudUPN -replace '"','""') + '",' +
          '"' + ($CloudId -replace '"','""') + '",' +
          '"' + ($AnchorBase64 -replace '"','""') + '",' +
          '"' + ($Outcome -replace '"','""') + '",' +
          '"' + ($Details -replace '"','""') + '"'
  Add-Content -Path $ResultsCsv -Value $line -Encoding UTF8
}

# --- Improve first-run reliability (TLS1.2 PS5.1) ---
if ($PSVersionTable.PSVersion.Major -eq 5) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

# --- Silent NuGet + PSGallery trust (avoid prompts) ---
try {
  $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
  if (-not $nuget) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false | Out-Null
  }
  $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
  if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  }
} catch { Write-Warn "NuGet/PSGallery bootstrap warning: $($_.Exception.Message)" }

# --- Ensure RSAT AD module (Win10/11 installs via Windows Capability) ---
function Ensure-ActiveDirectoryModule {
  try { Import-Module ActiveDirectory -ErrorAction Stop; return $true }
  catch {
    Write-Warn "ActiveDirectory module missing. Attempting RSAT AD install…"
    try {
      Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 | Out-Null
      Import-Module ActiveDirectory -ErrorAction Stop
      Write-Ok "ActiveDirectory module installed."
      return $true
    } catch {
      Write-Error2 "Could not install/load ActiveDirectory module. $($_.Exception.Message)"
      return $false
    }
  }
}
if (-not (Ensure-ActiveDirectoryModule)) { exit 1 }

# --- Ensure Microsoft Graph submodules (Authentication + Users) ---
function Ensure-GraphModule {
  try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Users          -ErrorAction Stop
    return $true
  } catch {
    Write-Warn "Microsoft Graph modules not found. Installing (CurrentUser)…"
    try {
      Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
      Install-Module Microsoft.Graph.Users          -Scope CurrentUser -Force -AllowClobber
      Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
      Import-Module Microsoft.Graph.Users          -ErrorAction Stop
      Write-Ok "Microsoft Graph modules installed and loaded."
      return $true
    } catch {
      Write-Error2 "Could not install/load Microsoft.Graph.*. $($_.Exception.Message)"
      Write-Host  "PSModulePath: $env:PSModulePath"
      return $false
    }
  }
}
if (-not (Ensure-GraphModule)) { exit 1 }

# --- Connect to Graph INTERACTIVE (avoid device-code policy blocks) ---
try {
  Write-Info "Connecting to Microsoft Graph (User.ReadWrite.All)…"
  Connect-MgGraph -Scopes "User.ReadWrite.All" -ErrorAction Stop | Out-Null
  $ctx = Get-MgContext
  Write-Info "Connected to tenant $($ctx.TenantId)."
} catch {
  Write-Error2 "Graph connection failed: $($_.Exception.Message)"
  exit 1
}

# --- SourceAnchor computation (mS-DS-ConsistencyGuid preferred; objectGUID fallback) ---
function Get-AnchorBase64 {
  param([Parameter(Mandatory)][Microsoft.ActiveDirectory.Management.ADUser]$AdUser)
  if ($AdUser.'mS-DS-ConsistencyGuid') { $bytes = $AdUser.'mS-DS-ConsistencyGuid' }
  else { $bytes = ([Guid]$AdUser.ObjectGUID).ToByteArray() }
  return [Convert]::ToBase64String($bytes)
}

# --- AD picker (Out-GridView or console) ---
function Select-AdUserInteractive {
  try {
    $adUsers = Get-ADUser -Filter * -Properties displayName,userPrincipalName,mS-DS-ConsistencyGuid,objectGUID |
               Select-Object Name, SamAccountName, UserPrincipalName, DisplayName, 'mS-DS-ConsistencyGuid', ObjectGUID |
               Sort-Object DisplayName, SamAccountName
  } catch { throw "Failed to enumerate AD users: $($_.Exception.Message)" }
  if (-not $adUsers) { return $null }
  if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    return $adUsers | Out-GridView -Title "Select ONE on-prem AD user to hard-match" -PassThru
  } else {
    Write-Warn "Out-GridView not available. Using console input."
    $sam = Read-Host "Enter sAMAccountName of the AD user"
    if ([string]::IsNullOrWhiteSpace($sam)) { return $null }
    return $adUsers | Where-Object { $_.SamAccountName -ieq $sam } | Select-Object -First 1
  }
}

# --- 365 picker (Search or Browse) ---
function Select-CloudUserGui {
  param([string]$Hint)

  $mode = Read-Host "Select 365 user by (S)earch or (B)rowse all? [S/B]"
  if ($mode -notin @('S','s','B','b')) { $mode = 'S' }

  if ($mode -in @('S','s')) {
    # ----- SEARCH MODE: server-side OData filter with startswith() -----
    $criteria = Read-Host ("Enter search text for 365 user (UPN, display name, mail){0}" -f (if ($Hint) { " [default: $Hint]" } else { "" }))
    if ([string]::IsNullOrWhiteSpace($criteria)) { $criteria = $Hint }
    if ([string]::IsNullOrWhiteSpace($criteria)) { Write-Warn "No search text entered."; return $null }

    $s = $criteria -replace "'", "''" # escape quotes for OData
    try {
      $users = Get-MgUser -Filter "startsWith(userPrincipalName,'$s') or startsWith(displayName,'$s') or startsWith(mail,'$s')" `
                          -Select "id,displayName,userPrincipalName,mail,onPremisesImmutableId,onPremisesSyncEnabled" `
                          -Top 200
    } catch {
      Write-Error2 "Cloud lookup failed: $($_.Exception.Message)"; return $null
    }
  }
  else {
    # ----- BROWSE MODE: load all users (paged) -----
    try {
      $users = Get-MgUser -All -Property "id,displayName,userPrincipalName,mail,onPremisesImmutableId,onPremisesSyncEnabled"
    } catch {
      Write-Error2 "Cloud user enumeration failed: $($_.Exception.Message)"; return $null
    }
  }

  if (-not $users) { Write-Warn "No 365 users found for your selection."; return $null }

  if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    return $users | Select-Object `
      @{n='Display';e={('{0}  ({1})  [{2}]' -f $_.DisplayName,$_.UserPrincipalName,$_.Mail)}}, `
      UserPrincipalName, Id, Mail, OnPremisesImmutableId, OnPremisesSyncEnabled |
      Out-GridView -Title "Select Microsoft 365 (Entra ID) user" -PassThru
  }
  else {
    # Console fallback: numbered pick
    $i = 0
    $menu = $users | ForEach-Object {
      $i++; [pscustomobject]@{ Index=$i; DisplayName=$_.DisplayName; UPN=$_.UserPrincipalName; Mail=$_.Mail; Id=$_.Id }
    }
    $menu | Format-Table -Auto Size
    $pick = Read-Host "Enter the Index of the 365 user"
    if ($pick -as [int] -and $menu[$pick-1]) {
      $upn = $menu[$pick-1].UPN
      return $users | Where-Object { $_.UserPrincipalName -ieq $upn } | Select-Object -First 1
    }
    Write-Warn "Invalid selection."; return $null
  }
}

while ($true) {
  # --- AD user selection
  try { $picked = Select-AdUserInteractive } catch {
    $msg = $_.Exception.Message
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName "" -AdSam "" -AdUPN "" -CloudUPN "" -CloudId "" -AnchorBase64 ""
    break
  }

  if (-not $picked) {
    Write-Warn "No AD user selected. Exiting."
    Add-ResultRow -Outcome "INFO" -Details "User cancelled selection" -AdDisplayName "" -AdSam "" -AdUPN "" -CloudUPN "" -CloudId "" -AnchorBase64 ""
    break
  }

  $adDisplay = $picked.DisplayName
  $adSam     = $picked.SamAccountName
  $adUpn     = $picked.UserPrincipalName
  Write-Info "Selected AD user: $adDisplay [$adSam] ($adUpn)"

  # Compute anchor
  $anchor = ""
  try {
    $adUser = Get-ADUser -Identity $adSam -Properties mS-DS-ConsistencyGuid,ObjectGUID,DisplayName,UserPrincipalName
    $anchor = Get-AnchorBase64 -AdUser $adUser
    Write-Info "Anchor (Base64): $anchor"
  } catch {
    $msg = "Could not compute anchor: $($_.Exception.Message)"
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN "" -CloudId "" -AnchorBase64 ""
    continue
  }

  # --- 365 user selection (Search or Browse, no typing UPN)
  $hint = if ($adUpn) { $adUpn.Split('@')[0] } else { "" }
  $cloudPick = $null
  do {
    $cloudPick = Select-CloudUserGui -Hint $hint
    if (-not $cloudPick) {
      $tryAgain = Read-Host "No 365 user selected. Try another search/browse? (Y/N)"
      if ($tryAgain -notin @('Y','y','Yes','yes')) { break }
    }
  } while (-not $cloudPick)

  if (-not $cloudPick) {
    Write-Warn "Skipping; no 365 user chosen."
    Add-ResultRow -Outcome "SKIPPED" -Details "No cloud user selected" -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN "" -CloudId "" -AnchorBase64 $anchor
    $again = Read-Host "Process another user? (Y/N)"
    if ($again -notin @('Y','y','Yes','yes')) { break }
    continue
  }

  $cloudUpn = $cloudPick.UserPrincipalName
  $cloudId  = $cloudPick.Id

  # Final safety & write
  try {
    $cloud = Get-MgUser -UserId $cloudUpn -Property 'userPrincipalName,id,onPremisesImmutableId,onPremisesSyncEnabled'
  } catch {
    $msg = "Cloud user '$cloudUpn' not accessible: $($_.Exception.Message)"
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    goto ContinueLoop
  }

  if ($cloud.onPremisesSyncEnabled -eq $true) {
    $msg = "Cloud user already synced (onPremisesSyncEnabled = true). Skipping."
    Write-Warn $msg
    Add-ResultRow -Outcome "SKIPPED" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    goto ContinueLoop
  }

  try {
    Update-MgUser -UserId $cloudUpn -OnPremisesImmutableId $anchor -ErrorAction Stop
    Start-Sleep -Milliseconds 300
    $verify = Get-MgUser -UserId $cloudUpn -Property 'onPremisesImmutableId,onPremisesSyncEnabled'
    if ($verify.onPremisesImmutableId -eq $anchor) {
      Write-Ok "ImmutableId set for $($cloud.userPrincipalName)."
      Add-ResultRow -Outcome "SUCCESS" -Details "ImmutableId set" -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    } else {
      $msg = "Verification failed; value not reflected as expected."
      Write-Error2 $msg
      Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    }
  } catch {
    $msg = "Failed to set immutableId: $($_.Exception.Message)"
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
  }

  :ContinueLoop
  $again = Read-Host "Process another user? (Y/N)"
  if ($again -notin @('Y','y','Yes','yes')) { break }
}

Write-Info "Done. Results saved to: $ResultsCsv"
Write-Info "After enabling Entra Connect, run:  Start-ADSyncSyncCycle -PolicyType Delta"