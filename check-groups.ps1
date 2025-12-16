# Requires Connect-ExchangeOnline already run
$user = baswayze@alliance-rubber.com

# Get all DGs where Beau is a member (Exchange Online side)
$groups = Get-DistributionGroup -ResultSize Unlimited -Filter Members -eq '$user'

# Report moderation settings for just those groups
$report = foreach ($g in $groups) {
    $dg = Get-DistributionGroup $g.Identity

    [pscustomobject]@{
        GroupName          = $dg.DisplayName
        PrimarySmtpAddress = $dg.PrimarySmtpAddress
        ModerationEnabled  = $dg.ModerationEnabled
        ModeratedBy        = if ($dg.ModeratedBy) { ($dg.ModeratedBy -join ; ) } else {  }
        BypassModerationFromSendersOrMembers =
            if ($dg.BypassModerationFromSendersOrMembers) { ($dg.BypassModerationFromSendersOrMembers -join ; ) } else {  }
    }
}

# Show only moderated ones first
$report  Sort-Object ModerationEnabled -Descending, GroupName  Format-Table -AutoSize

# Optional export to CSV for ticket notes
# $report  Export-Csv $envUSERPROFILEDesktopBeau-GroupModerationReport.csv -NoTypeInformation
