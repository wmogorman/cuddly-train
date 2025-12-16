param(
  [Parameter(Mandatory=$true)]
  [string]$UserPrincipalName,

  # Optional label so you can run once in EXO, once on-prem, and compare
  [string]$Environment = "EXO"
)

Write-Host "[$Environment] Checking moderation related to: $UserPrincipalName" -ForegroundColor Cyan

$results = @()

# 1) Mailbox moderation (if mailbox exists in this environment)
try {
  $mbx = Get-Mailbox -Identity $UserPrincipalName -ErrorAction Stop
  $results += [pscustomobject]@{
    Environment = $Environment
    ObjectType  = "Mailbox"
    Name        = $mbx.DisplayName
    PrimarySmtp = $mbx.PrimarySmtpAddress
    ModerationEnabled = $mbx.ModerationEnabled
    ModeratedBy = if ($mbx.ModeratedBy) { ($mbx.ModeratedBy -join "; ") } else { "" }
    Notes = ""
  }
} catch {
  $results += [pscustomobject]@{
    Environment = $Environment
    ObjectType  = "Mailbox"
    Name        = $UserPrincipalName
    PrimarySmtp = ""
    ModerationEnabled = ""
    ModeratedBy = ""
    Notes = "Mailbox not found in this environment"
  }
}

# 2) DGs where user is a member + moderation state
try {
  $groups = Get-DistributionGroup -ResultSize Unlimited -Filter "Members -eq '$UserPrincipalName'"
  foreach ($g in $groups) {
    $dg = Get-DistributionGroup $g.Identity
    $results += [pscustomobject]@{
      Environment = $Environment
      ObjectType  = "DistributionGroup"
      Name        = $dg.DisplayName
      PrimarySmtp = $dg.PrimarySmtpAddress
      ModerationEnabled = $dg.ModerationEnabled
      ModeratedBy = if ($dg.ModeratedBy) { ($dg.ModeratedBy -join "; ") } else { "" }
      Notes = ""
    }
  }
} catch {
  $results += [pscustomobject]@{
    Environment = $Environment
    ObjectType  = "DistributionGroup"
    Name        = ""
    PrimarySmtp = ""
    ModerationEnabled = ""
    ModeratedBy = ""
    Notes = "Failed to enumerate DG membership: $($_.Exception.Message)"
  }
}

# 3) Global “who is moderated” lists (useful for on-prem hunting)
# Moderated DGs
try {
  Get-DistributionGroup -ResultSize Unlimited | Where-Object {$_.ModerationEnabled -eq $true} | ForEach-Object {
    $results += [pscustomobject]@{
      Environment = $Environment
      ObjectType  = "ModeratedDG"
      Name        = $_.DisplayName
      PrimarySmtp = $_.PrimarySmtpAddress
      ModerationEnabled = $_.ModerationEnabled
      ModeratedBy = if ($_.ModeratedBy) { ($_.ModeratedBy -join "; ") } else { "" }
      Notes = ""
    }
  }
} catch {}

# Moderated Mailboxes
try {
  Get-Mailbox -ResultSize Unlimited -Filter "ModerationEnabled -eq 'True'" | ForEach-Object {
    $results += [pscustomobject]@{
      Environment = $Environment
      ObjectType  = "ModeratedMailbox"
      Name        = $_.DisplayName
      PrimarySmtp = $_.PrimarySmtpAddress
      ModerationEnabled = $_.ModerationEnabled
      ModeratedBy = if ($_.ModeratedBy) { ($_.ModeratedBy -join "; ") } else { "" }
      Notes = ""
    }
  }
} catch {}

# Transport rules (on-prem may have weird ones)
try {
  Get-TransportRule | ForEach-Object {
    # No universal "ModerationEnabled" on all rule types, so just list rules that might touch approvals
    if ($_.Name -match "approve|approval|moder|oab|quarantine|dlp|journal|hold|redirect|relay" -or
        ($_.Comments -match "approve|approval|moder")) {
      $results += [pscustomobject]@{
        Environment = $Environment
        ObjectType  = "TransportRule"
        Name        = $_.Name
        PrimarySmtp = ""
        ModerationEnabled = ""
        ModeratedBy = ""
        Notes = "Rule may be relevant; inspect conditions/actions"
      }
    }
  }
} catch {}

$results |
  Sort-Object ObjectType, Name |
  Format-Table -AutoSize

# Optional: CSV
# $results | Export-Csv ".\moderation-scan-$($Environment)-$($UserPrincipalName.Replace('@','_')).csv" -NoTypeInformation
