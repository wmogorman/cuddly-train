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

function Import-ActiveDirectoryModuleCompat {
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    try {
      Import-Module ActiveDirectory -SkipEditionCheck -ErrorAction Stop
      return
    } catch {
      Write-Warn "Native ActiveDirectory import failed; using Windows PowerShell compatibility. $($_.Exception.Message)"
    }
  }

  Import-Module ActiveDirectory -ErrorAction Stop
}

# --- Ensure RSAT AD module (Win10/11 installs via Windows Capability) ---
function Ensure-ActiveDirectoryModule {
  try { Import-ActiveDirectoryModuleCompat; return $true }
  catch {
    Write-Warn "ActiveDirectory module missing. Attempting RSAT AD install…"
    try {
      if (-not (Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue)) {
        Write-Warn "Add-WindowsCapability not found. Attempting WindowsCompatibility fallback…"
        try {
          if (-not (Get-Module -ListAvailable -Name WindowsCompatibility)) {
            Write-Warn "WindowsCompatibility module not found. Installing (CurrentUser)…"
            Install-Module WindowsCompatibility -Scope CurrentUser -Force -AllowClobber
          }
          Import-Module WindowsCompatibility -ErrorAction Stop
          Import-WinModule DISM -ErrorAction Stop
        } catch {
          Write-Warn "WindowsCompatibility fallback failed: $($_.Exception.Message)"
        }
      }
      if (-not (Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue)) {
        throw "Add-WindowsCapability is unavailable. Run in Windows PowerShell 5.1 or install WindowsCompatibility."
      }
      Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 | Out-Null
      Import-ActiveDirectoryModuleCompat
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
function Test-HasAnchorValue {
  param($Value)

  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace($Value)) }
  if ($Value -is [byte[]]) { return ($Value.Length -gt 0) }
  if ($Value -is [array]) { return ($Value.Count -gt 0) }
  return $true
}

function Convert-AnchorValueToByteArray {
  param(
    [Parameter(Mandatory)]$Value,
    [Parameter(Mandatory)][string]$PropertyName
  )

  if ($Value -is [byte[]]) { return $Value }
  if ($Value -is [Guid]) { return $Value.ToByteArray() }

  try {
    return [byte[]]$Value
  } catch {}

  $text = [string]$Value
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    try { return ([Guid]$text).ToByteArray() } catch {}
    try { return [Convert]::FromBase64String($text) } catch {}
  }

  throw "Unsupported $PropertyName value type '$($Value.GetType().FullName)'."
}

function Get-AnchorBase64 {
  param([Parameter(Mandatory)]$AdUser)

  $consistencyGuid = $AdUser.PSObject.Properties['mS-DS-ConsistencyGuid']
  $objectGuid      = $AdUser.PSObject.Properties['ObjectGUID']

  if ($consistencyGuid -and (Test-HasAnchorValue $consistencyGuid.Value)) {
    $bytes = Convert-AnchorValueToByteArray -Value $consistencyGuid.Value -PropertyName 'mS-DS-ConsistencyGuid'
  } elseif ($objectGuid -and (Test-HasAnchorValue $objectGuid.Value)) {
    $bytes = Convert-AnchorValueToByteArray -Value $objectGuid.Value -PropertyName 'ObjectGUID'
  } else {
    throw "Neither mS-DS-ConsistencyGuid nor ObjectGUID was available on the AD user object."
  }

  return [Convert]::ToBase64String($bytes)
}

$script:AdUserCache     = $null
$script:AdUsersByAnchor = @{}

function Format-AdUserLabel {
  param([Parameter(Mandatory)]$AdUser)

  $label = ""
  if ($AdUser.DisplayName) { $label = [string]$AdUser.DisplayName }
  elseif ($AdUser.Name) { $label = [string]$AdUser.Name }
  elseif ($AdUser.SamAccountName) { $label = [string]$AdUser.SamAccountName }
  elseif ($AdUser.UserPrincipalName) { $label = [string]$AdUser.UserPrincipalName }
  else { $label = "<unknown AD user>" }

  if ($AdUser.SamAccountName) { $label = "$label [$($AdUser.SamAccountName)]" }
  if ($AdUser.UserPrincipalName) { $label = "$label ($($AdUser.UserPrincipalName))" }

  return $label
}

function Format-CloudUserLabel {
  param([Parameter(Mandatory)]$CloudUser)

  $label = ""
  if ($CloudUser.DisplayName) { $label = [string]$CloudUser.DisplayName }
  elseif ($CloudUser.UserPrincipalName) { $label = [string]$CloudUser.UserPrincipalName }
  else { $label = "<unknown cloud user>" }

  if ($CloudUser.UserPrincipalName -and $label -ne $CloudUser.UserPrincipalName) {
    $label = "$label [$($CloudUser.UserPrincipalName)]"
  }
  if ($CloudUser.Mail) { $label = "$label <$($CloudUser.Mail)>" }

  return $label
}

function Get-AdUserCache {
  if ($null -ne $script:AdUserCache) { return $script:AdUserCache }

  Write-Info "Loading AD users and computing anchor index for match checks…"

  try {
    $rawAdUsers = Get-ADUser -Filter * -Properties displayName,userPrincipalName,mS-DS-ConsistencyGuid,objectGUID |
                  Sort-Object DisplayName, SamAccountName
  } catch {
    throw "Failed to enumerate AD users: $($_.Exception.Message)"
  }

  $cache = foreach ($adUser in $rawAdUsers) {
    $anchor = ""
    try { $anchor = Get-AnchorBase64 -AdUser $adUser } catch {}

    [pscustomobject]@{
      Name                          = $adUser.Name
      SamAccountName                = $adUser.SamAccountName
      UserPrincipalName             = $adUser.UserPrincipalName
      DisplayName                   = $adUser.DisplayName
      'mS-DS-ConsistencyGuid'       = $adUser.'mS-DS-ConsistencyGuid'
      ObjectGUID                    = $adUser.ObjectGUID
      AnchorBase64                  = $anchor
      AdLabel                       = Format-AdUserLabel -AdUser $adUser
    }
  }

  $script:AdUsersByAnchor = @{}
  foreach ($entry in $cache) {
    if ([string]::IsNullOrWhiteSpace($entry.AnchorBase64)) { continue }
    if (-not $script:AdUsersByAnchor.ContainsKey($entry.AnchorBase64)) {
      $script:AdUsersByAnchor[$entry.AnchorBase64] = @()
    }
    $script:AdUsersByAnchor[$entry.AnchorBase64] += $entry
  }

  $script:AdUserCache = $cache
  return $script:AdUserCache
}

function Get-CloudMatchInfo {
  param(
    [Parameter(Mandatory)]$CloudUser,
    [string]$SelectedAnchor
  )

  Get-AdUserCache | Out-Null

  $currentAnchor = ""
  if ($CloudUser.PSObject.Properties['OnPremisesImmutableId']) {
    $currentAnchor = [string]$CloudUser.OnPremisesImmutableId
  } elseif ($CloudUser.PSObject.Properties['onPremisesImmutableId']) {
    $currentAnchor = [string]$CloudUser.onPremisesImmutableId
  }

  $isSynced = $false
  if ($CloudUser.PSObject.Properties['OnPremisesSyncEnabled']) {
    $isSynced = ($CloudUser.OnPremisesSyncEnabled -eq $true)
  } elseif ($CloudUser.PSObject.Properties['onPremisesSyncEnabled']) {
    $isSynced = ($CloudUser.onPremisesSyncEnabled -eq $true)
  }

  $matchedAdUsers = @()
  if (-not [string]::IsNullOrWhiteSpace($currentAnchor) -and $script:AdUsersByAnchor.ContainsKey($currentAnchor)) {
    $matchedAdUsers = @($script:AdUsersByAnchor[$currentAnchor])
  }

  $matchedAdUser = ""
  if ($matchedAdUsers.Count -eq 1) {
    $matchedAdUser = $matchedAdUsers[0].AdLabel
  } elseif ($matchedAdUsers.Count -gt 1) {
    $matchedAdUser = ($matchedAdUsers | Select-Object -First 3 -ExpandProperty AdLabel) -join "; "
    if ($matchedAdUsers.Count -gt 3) {
      $matchedAdUser = "$matchedAdUser (+$($matchedAdUsers.Count - 3) more)"
    }
  }

  $matchedToSelectedAd = (
    -not [string]::IsNullOrWhiteSpace($SelectedAnchor) -and
    -not [string]::IsNullOrWhiteSpace($currentAnchor) -and
    $currentAnchor -eq $SelectedAnchor
  )
  $hasExistingMatch = (-not [string]::IsNullOrWhiteSpace($currentAnchor))

  if ($matchedToSelectedAd) {
    $matchStatus = "Matches selected AD"
  } elseif (-not $hasExistingMatch) {
    if ($isSynced) { $matchStatus = "Synced; no ImmutableId shown" }
    else { $matchStatus = "Unmatched" }
  } elseif ($matchedAdUsers.Count -eq 1) {
    $matchStatus = "Matched to different AD"
  } elseif ($matchedAdUsers.Count -gt 1) {
    $matchStatus = "Matched to multiple AD users"
  } else {
    $matchStatus = "Matched; AD target not found"
  }

  return [pscustomobject]@{
    MatchStatus         = $matchStatus
    MatchedAdUser       = $matchedAdUser
    CurrentImmutableId  = $currentAnchor
    HasExistingMatch    = $hasExistingMatch
    MatchedToSelectedAd = $matchedToSelectedAd
    IsSynced            = $isSynced
    SyncState           = (if ($isSynced) { "Synced" } else { "Cloud-only" })
  }
}

function Expand-CloudUsersForSelection {
  param(
    [Parameter(Mandatory)]$Users,
    [string]$SelectedAnchor
  )

  return $Users | ForEach-Object {
    $matchInfo = Get-CloudMatchInfo -CloudUser $_ -SelectedAnchor $SelectedAnchor

    [pscustomobject]@{
      DisplayName            = $_.DisplayName
      Display                = ('{0}  ({1})  [{2}]' -f $_.DisplayName,$_.UserPrincipalName,$_.Mail)
      UserPrincipalName      = $_.UserPrincipalName
      Id                     = $_.Id
      Mail                   = $_.Mail
      MatchStatus            = $matchInfo.MatchStatus
      MatchedAdUser          = $matchInfo.MatchedAdUser
      SyncState              = $matchInfo.SyncState
      OnPremisesImmutableId  = $_.OnPremisesImmutableId
      OnPremisesSyncEnabled  = $_.OnPremisesSyncEnabled
    }
  }
}

function Get-HardMatchDecision {
  param(
    [Parameter(Mandatory)]$AdUser,
    [Parameter(Mandatory)][string]$Anchor,
    [Parameter(Mandatory)]$CloudUser
  )

  $adLabel    = Format-AdUserLabel -AdUser $AdUser
  $cloudLabel = Format-CloudUserLabel -CloudUser $CloudUser
  $matchInfo  = Get-CloudMatchInfo -CloudUser $CloudUser -SelectedAnchor $Anchor

  Write-Info "Review proposed hard match:"
  Write-Host "  AD user      : $adLabel"
  Write-Host "  AD anchor    : $Anchor"
  Write-Host "  Cloud user   : $cloudLabel"
  Write-Host "  Cloud status : $($matchInfo.MatchStatus)"
  Write-Host "  Sync state   : $($matchInfo.SyncState)"
  if ($matchInfo.MatchedAdUser) {
    Write-Host "  Matched AD   : $($matchInfo.MatchedAdUser)"
  }
  if ($matchInfo.CurrentImmutableId) {
    Write-Host "  Current ID   : $($matchInfo.CurrentImmutableId)"
  } else {
    Write-Host "  Current ID   : <blank>"
  }

  if ($matchInfo.IsSynced) {
    $details = "Cloud user already synced (onPremisesSyncEnabled = true)."
    if ($matchInfo.MatchedAdUser) { $details += " Current AD match: $($matchInfo.MatchedAdUser)." }
    return [pscustomobject]@{ Approved = $false; Details = $details }
  }

  if ($matchInfo.MatchedToSelectedAd) {
    return [pscustomobject]@{
      Approved = $false
      Details  = "Cloud user already matches the selected AD user."
    }
  }

  if ($matchInfo.HasExistingMatch) {
    if ($matchInfo.MatchedAdUser) {
      $prompt = "Type OVERWRITE to replace '$($matchInfo.MatchedAdUser)' with '$adLabel'"
    } else {
      $prompt = "Type OVERWRITE to replace the existing ImmutableId with '$adLabel'"
    }

    $confirm = Read-Host $prompt
    if ($confirm -ne "OVERWRITE") {
      return [pscustomobject]@{
        Approved = $false
        Details  = "Skipped: overwrite not confirmed."
      }
    }

    return [pscustomobject]@{ Approved = $true; Details = "Overwrite confirmed." }
  }

  $confirm = Read-Host "Type MATCH to hard-match this cloud user to '$adLabel'"
  if ($confirm -ne "MATCH") {
    return [pscustomobject]@{
      Approved = $false
      Details  = "Skipped: match not confirmed."
    }
  }

  return [pscustomobject]@{ Approved = $true; Details = "Match confirmed." }
}

# --- AD picker (Out-GridView or console) ---
function Select-AdUserInteractive {
  try { $adUsers = Get-AdUserCache } catch { throw $_.Exception.Message }
  if (-not $adUsers) { return $null }
  if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    return $adUsers |
      Select-Object DisplayName, SamAccountName, UserPrincipalName |
      Out-GridView -Title "Select ONE on-prem AD user to hard-match" -PassThru
  } else {
    Write-Warn "Out-GridView not available. Using console input."
    $sam = Read-Host "Enter sAMAccountName of the AD user"
    if ([string]::IsNullOrWhiteSpace($sam)) { return $null }
    return $adUsers | Where-Object { $_.SamAccountName -ieq $sam } | Select-Object -First 1
  }
}

# --- 365 picker (Search or Browse) ---
function Select-CloudUserGui {
  param(
    [string]$Hint,
    [string]$SelectedAnchor,
    [string]$SelectedAdLabel
  )

  $mode = Read-Host "Select 365 user by (S)earch or (B)rowse all? [S/B]"
  if ($mode -notin @('S','s','B','b')) { $mode = 'S' }

  if ($mode -in @('S','s')) {
    # ----- SEARCH MODE: server-side OData filter with startswith() -----
    $defaultHintText = ""
    if ($Hint) { $defaultHintText = " [default: $Hint]" }
    $criteria = Read-Host ("Enter search text for 365 user (UPN, display name, mail){0}" -f $defaultHintText)
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

  $selectionUsers = Expand-CloudUsersForSelection -Users $users -SelectedAnchor $SelectedAnchor
  $title = "Select Microsoft 365 (Entra ID) user"
  if ($SelectedAdLabel) { $title = "$title for $SelectedAdLabel" }

  if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    return $selectionUsers | Select-Object `
      Display, MatchStatus, MatchedAdUser, SyncState, UserPrincipalName, Mail, OnPremisesImmutableId, Id |
      Out-GridView -Title $title -PassThru
  }
  else {
    # Console fallback: numbered pick
    $i = 0
    $menu = $selectionUsers | ForEach-Object {
      $i++; [pscustomobject]@{
        Index              = $i
        DisplayName        = $_.DisplayName
        UserPrincipalName  = $_.UserPrincipalName
        MatchStatus        = $_.MatchStatus
        MatchedAdUser      = $_.MatchedAdUser
        SyncState          = $_.SyncState
        Mail               = $_.Mail
        Id                 = $_.Id
      }
    }
    $menu | Format-Table Index, DisplayName, UserPrincipalName, MatchStatus, MatchedAdUser, SyncState -AutoSize
    $pick = Read-Host "Enter the Index of the 365 user"
    if ($pick -as [int] -and $menu[$pick-1]) {
      return $menu[$pick-1]
    }
    Write-Warn "Invalid selection."; return $null
  }
}

function Confirm-ProcessAnotherUser {
  $again = Read-Host "Process another user? (Y/N)"
  return ($again -in @('Y','y','Yes','yes'))
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

  # Compute anchor
  $anchor = ""
  $adUser = $null
  try {
    $adUser = Get-ADUser -Identity $adSam -Properties mS-DS-ConsistencyGuid,ObjectGUID,DisplayName,UserPrincipalName
    $anchor = Get-AnchorBase64 -AdUser $adUser
  } catch {
    $msg = "Could not compute anchor: $($_.Exception.Message)"
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN "" -CloudId "" -AnchorBase64 ""
    continue
  }

  $adLabel = Format-AdUserLabel -AdUser $adUser
  Write-Info "Selected AD user: $adLabel"
  Write-Info "Anchor (Base64): $anchor"

  # --- 365 user selection (Search or Browse, no typing UPN)
  $hint = if ($adUpn) { $adUpn.Split('@')[0] } else { "" }
  $cloudPick = $null
  do {
    $cloudPick = Select-CloudUserGui -Hint $hint -SelectedAnchor $anchor -SelectedAdLabel $adLabel
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
    $cloud = Get-MgUser -UserId $cloudUpn -Property 'displayName,mail,userPrincipalName,id,onPremisesImmutableId,onPremisesSyncEnabled'
  } catch {
    $msg = "Cloud user '$cloudUpn' not accessible: $($_.Exception.Message)"
    Write-Error2 $msg
    Add-ResultRow -Outcome "ERROR" -Details $msg -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    if (-not (Confirm-ProcessAnotherUser)) { break }
    continue
  }

  $decision = Get-HardMatchDecision -AdUser $adUser -Anchor $anchor -CloudUser $cloud
  if (-not $decision.Approved) {
    Write-Warn $decision.Details
    Add-ResultRow -Outcome "SKIPPED" -Details $decision.Details -AdDisplayName $adDisplay -AdSam $adSam -AdUPN $adUpn -CloudUPN $cloudUpn -CloudId $cloudId -AnchorBase64 $anchor
    if (-not (Confirm-ProcessAnotherUser)) { break }
    continue
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

  if (-not (Confirm-ProcessAnotherUser)) { break }
}

Write-Info "Done. Results saved to: $ResultsCsv"
Write-Info "After enabling Entra Connect, run:  Start-ADSyncSyncCycle -PolicyType Delta"
