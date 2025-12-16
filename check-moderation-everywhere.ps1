[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$UserPrincipalName,

  # Optional label so you can run once in EXO, once on-prem, and compare.
  [string]$Environment = "EXO",

  # Optional CSV export path.
  [string]$CsvPath
)

# Assumes you are already connected (Connect-ExchangeOnline / on-prem session).

function Convert-RecipientIdsToName {
  param(
    [Parameter()]
    [object[]]$Ids
  )

  if (-not $Ids) { return "" }

  $Ids |
    ForEach-Object {
      $recipient = Get-Recipient -Identity $_ -ErrorAction SilentlyContinue
      if ($recipient.PrimarySmtpAddress) {
        $recipient.PrimarySmtpAddress.ToString()
      }
      elseif ($recipient.DisplayName) {
        $recipient.DisplayName
      }
      else {
        $_.ToString()
      }
    } |
    Sort-Object -Unique |
    ForEach-Object { $_ } -join "; "
}

Write-Host "[$Environment] Checking moderation related to: $UserPrincipalName" -ForegroundColor Cyan

$results = @()

# Resolve the user once to filter DG membership correctly (Members stores DNs, not UPNs).
$userRecipient = $null
try {
  $userRecipient = Get-Recipient -Identity $UserPrincipalName -ErrorAction Stop
} catch {
  Write-Verbose "Could not resolve recipient for membership filter: $($_.Exception.Message)"
}

# 1) Mailbox moderation (if mailbox exists in this environment)
try {
  $mbx = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop
  $results += [pscustomobject]@{
    Environment       = $Environment
    ObjectType        = "Mailbox"
    Name              = $mbx.DisplayName
    PrimarySmtp       = $mbx.PrimarySmtpAddress
    ModerationEnabled = $mbx.ModerationEnabled
    ModeratedBy       = Convert-RecipientIdsToName -Ids $mbx.ModeratedBy
    Notes             = ""
  }
} catch {
  $results += [pscustomobject]@{
    Environment       = $Environment
    ObjectType        = "Mailbox"
    Name              = $UserPrincipalName
    PrimarySmtp       = ""
    ModerationEnabled = ""
    ModeratedBy       = ""
    Notes             = "Mailbox not found in this environment"
  }
}

# 2) DGs where user is a member + moderation state
try {
  if ($userRecipient) {
    $escapedDn = $userRecipient.DistinguishedName.Replace("'", "''")
    $groups = Get-DistributionGroup -ResultSize Unlimited -Filter "Members -eq '$escapedDn'"
  }
  else {
    # Fallback to UPN match if we could not resolve the recipient.
    $groups = Get-DistributionGroup -ResultSize Unlimited -Filter "Members -eq '$UserPrincipalName'"
  }

  foreach ($g in $groups) {
    $dg = Get-DistributionGroup $g.Identity
    $results += [pscustomobject]@{
      Environment       = $Environment
      ObjectType        = "DistributionGroup"
      Name              = $dg.DisplayName
      PrimarySmtp       = $dg.PrimarySmtpAddress
      ModerationEnabled = $dg.ModerationEnabled
      ModeratedBy       = Convert-RecipientIdsToName -Ids $dg.ModeratedBy
      Notes             = ""
    }
  }
} catch {
  $results += [pscustomobject]@{
    Environment       = $Environment
    ObjectType        = "DistributionGroup"
    Name              = ""
    PrimarySmtp       = ""
    ModerationEnabled = ""
    ModeratedBy       = ""
    Notes             = "Failed to enumerate DG membership: $($_.Exception.Message)"
  }
}

# 3) Global "who is moderated" lists (useful for on-prem hunting)
# Moderated DGs
try {
  Get-DistributionGroup -ResultSize Unlimited |
    Where-Object { $_.ModerationEnabled -eq $true } |
    ForEach-Object {
      $results += [pscustomobject]@{
        Environment       = $Environment
        ObjectType        = "ModeratedDG"
        Name              = $_.DisplayName
        PrimarySmtp       = $_.PrimarySmtpAddress
        ModerationEnabled = $_.ModerationEnabled
        ModeratedBy       = Convert-RecipientIdsToName -Ids $_.ModeratedBy
        Notes             = ""
      }
    }
} catch {}

# Moderated Mailboxes
try {
  Get-Mailbox -ResultSize Unlimited -Filter "ModerationEnabled -eq 'True'" |
    ForEach-Object {
      $results += [pscustomobject]@{
        Environment       = $Environment
        ObjectType        = "ModeratedMailbox"
        Name              = $_.DisplayName
        PrimarySmtp       = $_.PrimarySmtpAddress
        ModerationEnabled = $_.ModerationEnabled
        ModeratedBy       = Convert-RecipientIdsToName -Ids $_.ModeratedBy
        Notes             = ""
      }
    }
} catch {}

# Transport rules (on-prem may have weird ones)
try {
  Get-TransportRule | ForEach-Object {
    # No universal "ModerationEnabled" on all rule types, so just list rules that might touch approvals.
    if ($_.Name -match "approve|approval|moder|oab|quarantine|dlp|journal|hold|redirect|relay" -or
        ($_.Comments -match "approve|approval|moder")) {
      $results += [pscustomobject]@{
        Environment       = $Environment
        ObjectType        = "TransportRule"
        Name              = $_.Name
        PrimarySmtp       = ""
        ModerationEnabled = ""
        ModeratedBy       = ""
        Notes             = "Rule may be relevant; inspect conditions/actions"
      }
    }
  }
} catch {}

$results |
  Sort-Object ObjectType, Name |
  Format-Table -AutoSize

if ($CsvPath) {
  $results | Export-Csv -Path $CsvPath -NoTypeInformation
}
