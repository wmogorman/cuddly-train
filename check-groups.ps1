[CmdletBinding()]
param(
    # User principal name (or alias) to check membership for.
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName,

    # Optional path to export the report as CSV.
    [string]$CsvPath
)

# This script assumes Connect-ExchangeOnline has already been run.

function Convert-RecipientIdsToName {
    param(
        [Parameter()]
        [object[]]$Ids
    )

    if (-not $Ids) { return $null }

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
        Sort-Object -Unique
}

# Resolve the user to a directory object so we can filter on DN (Members stores DNs, not UPNs).
$userRecipient = Get-Recipient -Identity $UserPrincipalName -ErrorAction Stop
$escapedDn = $userRecipient.DistinguishedName.Replace("'", "''")

# Get all DGs where the user is a member (Exchange Online side).
$groups = Get-DistributionGroup -ResultSize Unlimited -Filter "Members -eq '$escapedDn'" -ErrorAction Stop

# Report moderation settings for just those groups.
$report = foreach ($g in $groups) {
    $dg = Get-DistributionGroup -Identity $g.Identity -ErrorAction Stop

    [pscustomobject]@{
        GroupName          = $dg.DisplayName
        PrimarySmtpAddress = $dg.PrimarySmtpAddress
        ModerationEnabled  = $dg.ModerationEnabled
        ModeratedBy        = Convert-RecipientIdsToName -Ids $dg.ModeratedBy
        BypassModerationFromSendersOrMembers =
            Convert-RecipientIdsToName -Ids $dg.BypassModerationFromSendersOrMembers
    }
}

# Show only moderated ones first for quick review.
$report |
    Sort-Object -Property @{Expression='ModerationEnabled';Descending=$true}, @{Expression='GroupName';Descending=$false} |
    Format-Table -AutoSize

if ($CsvPath) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation
}
