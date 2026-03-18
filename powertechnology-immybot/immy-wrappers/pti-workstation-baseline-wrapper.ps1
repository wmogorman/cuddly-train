[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZip,

    [Parameter(DontShow = $true)]
    [string]$TenantName,

    [Parameter(DontShow = $true)]
    [string]$TenantSlug,

    [Parameter(DontShow = $true)]
    [string]$ComputerName,

    [Parameter(DontShow = $true)]
    [string]$ComputerSlug,

    [Parameter(DontShow = $true)]
    [string]$AzureTenantId,

    [Parameter(DontShow = $true)]
    [Guid]$PrimaryPersonAzurePrincipalId,

    [Parameter(DontShow = $true)]
    [string]$PrimaryPersonEmail,

    [Parameter(DontShow = $true)]
    [bool]$IsPortable,

    [string]$ApprovedSecurityProducts = '',

    [switch]$EnableUnauthorizedSecurityRemoval,

    [switch]$SkipUnauthorizedSecurityRemoval,

    [switch]$SkipDellCleanup,

    [switch]$SkipConsumerBloatwareRemoval,

    [switch]$SkipOneDriveRemoval,

    [switch]$SkipCortanaDisable,

    [switch]$SkipRemoteAssistance,

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-workstation-baseline.log',

    [Parameter(DontShow = $true, ValueFromRemainingArguments = $true)]
    [object[]]$ImmyRuntimeArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name 'Method' -ValueOnly -ErrorAction SilentlyContinue))) {
    $Method = 'Set'
}

function Resolve-PTIPayloadFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    $folderVariable = Get-Variable -Name 'PTIPayloadZipFolder' -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($folderVariable)) {
        return $folderVariable
    }

    if (Test-Path -LiteralPath $ZipPath -PathType Container) {
        return $ZipPath
    }

    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        $zipItem = Get-Item -LiteralPath $ZipPath -ErrorAction Stop
        $extractRoot = Join-Path -Path $env:TEMP -ChildPath ('pti-immy-payload-' + $zipItem.BaseName + '-' + $zipItem.LastWriteTimeUtc.Ticks)
        if (-not (Test-Path -LiteralPath $extractRoot)) {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
        }

        return $extractRoot
    }

    throw 'PTIPayloadZipFolder was not available at runtime. Ensure PTIPayloadZip is a File parameter that points to the PTI payload zip.'
}

function Get-PTIPayloadEntrypoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PayloadFolder,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $payloadRoot = Join-Path -Path $PayloadFolder -ChildPath 'payload'
    $scriptPath = Join-Path -Path $payloadRoot -ChildPath $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "PTI payload entrypoint not found: $scriptPath. Rebuild and re-upload the PTI payload zip."
    }

    return $scriptPath
}

function Get-InstalledPrograms {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $displayNameProperty = $_.PSObject.Properties['DisplayName']
            $null -ne $displayNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$displayNameProperty.Value)
        } |
        Select-Object DisplayName, Publisher
}

function Test-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedValue
    )

    try {
        $property = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return ([int]$property.$Name -eq $ExpectedValue)
    }
    catch {
        return $false
    }
}

function Test-AppxAbsent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $installed = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue)
    if ($installed.Count -gt 0) {
        return $false
    }

    $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $Pattern })
    return ($provisioned.Count -eq 0)
}

function Test-ScheduledTasksDisabled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskNamePattern
    )

    $tasks = @(Get-ScheduledTask -TaskName $TaskNamePattern -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        return $true
    }

    return (@($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
}

function Test-RemoteAssistanceFirewallEnabled {
    $rules = @(Get-NetFirewallRule -DisplayGroup 'Remote Assistance' -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) {
        return $false
    }

    return (@($rules | Where-Object { $_.Enabled -eq 'True' }).Count -gt 0)
}

function Get-PTILastBootTimeUtc {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([datetime]$os.LastBootUpTime).ToUniversalTime()
    }
    catch {
        return (Get-Date).ToUniversalTime()
    }
}

function Get-PTIPendingRebootState {
    $sources = [System.Collections.Generic.List[string]]::new()
    $markerPath = 'C:\ProgramData\PTI\State\pti-workstation-baseline.reboot.json'

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $sources.Add('Component Based Servicing') | Out-Null
    }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $sources.Add('Windows Update') | Out-Null
    }

    foreach ($propertyName in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
        try {
            $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name $propertyName -ErrorAction Stop
            if ($null -ne $sessionManager.$propertyName -and @($sessionManager.$propertyName).Count -gt 0) {
                $sources.Add("Session Manager:$propertyName") | Out-Null
            }
        }
        catch {
        }
    }

    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Get-Content -Path $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $currentBootTime = Get-PTILastBootTimeUtc
            $bootTimeAtRequest = if ($marker.BootTimeAtRequestUtc) {
                ([datetime]$marker.BootTimeAtRequestUtc).ToUniversalTime()
            }
            else {
                $null
            }

            if ($bootTimeAtRequest -and $currentBootTime -gt $bootTimeAtRequest.AddSeconds(5)) {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
            }
            else {
                $sources.Add('PTI baseline reboot marker') | Out-Null
            }
        }
        catch {
            $sources.Add('PTI baseline reboot marker') | Out-Null
        }
    }

    return [pscustomobject]@{
        IsPending = ($sources.Count -gt 0)
        Sources   = @($sources | Sort-Object -Unique)
        MarkerPath = $markerPath
    }
}

function Test-PTIRemoteAssistanceEnabled {
    $controlEnabled = Test-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -ExpectedValue 1
    $policyEnabled = Test-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowToGetHelp' -ExpectedValue 1

    return ($controlEnabled -or $policyEnabled)
}

function Get-SecurityInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns
    )

    $inventory = [System.Collections.Generic.List[string]]::new()

    try {
        $securityCenterProducts = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntivirusProduct' -ErrorAction Stop
        foreach ($product in $securityCenterProducts) {
            if (-not [string]::IsNullOrWhiteSpace($product.displayName)) {
                $inventory.Add($product.displayName) | Out-Null
            }
        }
    }
    catch {
    }

    foreach ($program in Get-InstalledPrograms) {
        foreach ($pattern in $DisplayNamePatterns) {
            if ($program.DisplayName -match $pattern) {
                $inventory.Add($program.DisplayName) | Out-Null
                break
            }
        }
    }

    return @($inventory | Sort-Object -Unique)
}

function Test-PatternMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-PTIBaselineCompliance {
    param(
        [string[]]$ApprovedProducts
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $installedPrograms = @(Get-InstalledPrograms | Sort-Object DisplayName -Unique)

    if (-not $SkipConsumerBloatwareRemoval) {
        $programPatterns = @(
            '(?i)\bMicrosoft 365\b',
            '(?i)\bMicrosoft 365 Apps\b',
            '(?i)\bOffice 365\b',
            '(?i)^Microsoft Office Desktop Apps\b'
        )

        foreach ($program in $installedPrograms) {
            foreach ($pattern in $programPatterns) {
                if ($program.DisplayName -match $pattern) {
                    $issues.Add("Installed program still present: $($program.DisplayName)") | Out-Null
                    break
                }
            }
        }

        foreach ($pattern in @(
            'Microsoft.BingNews',
            'Microsoft.News',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.OutlookForWindows',
            'Microsoft.GamingApp',
            'Microsoft.Xbox.TCUI',
            'Microsoft.XboxApp',
            'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay',
            'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay'
        )) {
            if (-not (Test-AppxAbsent -Pattern $pattern)) {
                $issues.Add("Consumer AppX package still present: $pattern") | Out-Null
            }
        }
    }

    if (-not $SkipCortanaDisable) {
        if (-not (Test-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -ExpectedValue 0)) {
            $issues.Add('AllowCortana is not set to 0.') | Out-Null
        }

        if (-not (Test-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'DisableWebSearch' -ExpectedValue 1)) {
            $issues.Add('DisableWebSearch is not set to 1.') | Out-Null
        }

        if (-not (Test-AppxAbsent -Pattern 'Microsoft.549981C3F5F10')) {
            $issues.Add('Cortana AppX package is still present.') | Out-Null
        }
    }

    if (-not $SkipOneDriveRemoval) {
        foreach ($name in @(
            'DisableFileSyncNGSC',
            'DisableLibrariesDefaultSaveToOneDrive',
            'DisablePersonalSync',
            'PreventNetworkTrafficPreUserSignIn'
        )) {
            if (-not (Test-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name $name -ExpectedValue 1)) {
                $issues.Add("OneDrive policy is not enforced: $name") | Out-Null
            }
        }

        if (-not (Test-ScheduledTasksDisabled -TaskNamePattern 'OneDrive*')) {
            $issues.Add('OneDrive scheduled tasks are still enabled.') | Out-Null
        }

        if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\PTI-OneDriveCleanup')) {
            $issues.Add('PTI OneDrive Active Setup entry is missing.') | Out-Null
        }
    }

    if (-not $SkipDellCleanup) {
        foreach ($pattern in @(
            '(?i)^Dell Optimizer\b',
            '(?i)^Dell SupportAssist\b',
            '(?i)^Dell SupportAssist OS Recovery\b',
            '(?i)^Dell SupportAssist Remediation\b',
            '(?i)^Dell Digital Delivery\b',
            '(?i)^Dell Customer Connect\b',
            '(?i)^Dell Update\b',
            '(?i)^My Dell\b',
            '(?i)^Dell TechHub\b',
            '(?i)^Dell Power Manager\b'
        )) {
            foreach ($program in $installedPrograms) {
                if ($program.DisplayName -match $pattern) {
                    $issues.Add("Dell bloatware still present: $($program.DisplayName)") | Out-Null
                }
            }
        }
    }

    if (-not $SkipUnauthorizedSecurityRemoval -and $EnableUnauthorizedSecurityRemoval -and $ApprovedProducts.Count -gt 0) {
        $securityInventory = Get-SecurityInventory -DisplayNamePatterns @(
            'Antivirus',
            'Internet Security',
            'Endpoint Security',
            'Threat',
            'Malware',
            'EDR',
            'XDR',
            'AVG',
            'Avast',
            'Bitdefender',
            'CrowdStrike',
            'Cylance',
            'ESET',
            'Kaspersky',
            'McAfee',
            'Norton',
            'SentinelOne',
            'Sophos',
            'Trend Micro',
            'Webroot'
        )

        $approvedPatterns = @($ApprovedProducts + @('Microsoft Defender', 'Windows Defender', 'Defender for Endpoint'))
        foreach ($product in $securityInventory) {
            if (-not (Test-PatternMatch -Value $product -Patterns $approvedPatterns)) {
                $issues.Add("Unapproved security product detected: $product") | Out-Null
            }
        }
    }

    if (-not $SkipRemoteAssistance) {
        if (-not (Test-PTIRemoteAssistanceEnabled)) {
            $issues.Add('Remote Assistance is not enabled.') | Out-Null
        }

        if (-not (Test-RemoteAssistanceFirewallEnabled)) {
            $issues.Add('Remote Assistance firewall rules are not enabled.') | Out-Null
        }
    }

    $rebootState = Get-PTIPendingRebootState
    $uniqueIssues = @($issues | Sort-Object -Unique)
    $onlyDellResidualIssuesRemain = $uniqueIssues.Count -gt 0 -and @(
        $uniqueIssues | Where-Object { $_ -notmatch '^Dell bloatware still present:' }
    ).Count -eq 0

    if ($onlyDellResidualIssuesRemain -and $rebootState.IsPending) {
        Write-Warning ("PTI baseline is awaiting reboot before final Dell verification. Pending reboot sources: {0}. Remaining entries: {1}" -f ($rebootState.Sources -join '; '), ($uniqueIssues -join ' | '))
        return $true
    }

    if ($uniqueIssues.Count -gt 0) {
        Write-Warning ('PTI baseline is not compliant: ' + ($uniqueIssues -join ' | '))
        return $false
    }

    Write-Host 'PTI baseline is compliant.'
    return $true
}

function Get-PTIBaselineState {
    param(
        [string[]]$ApprovedProducts
    )

    $isCompliant = Test-PTIBaselineCompliance -ApprovedProducts $ApprovedProducts
    $rebootState = Get-PTIPendingRebootState
    return [pscustomobject]@{
        Compliant                      = $isCompliant
        ApprovedSecurityProductCount   = @($ApprovedProducts).Count
        SkipDellCleanup                = $SkipDellCleanup.IsPresent
        SkipConsumerBloatwareRemoval   = $SkipConsumerBloatwareRemoval.IsPresent
        SkipOneDriveRemoval            = $SkipOneDriveRemoval.IsPresent
        SkipCortanaDisable             = $SkipCortanaDisable.IsPresent
        SkipRemoteAssistance           = $SkipRemoteAssistance.IsPresent
        EnableUnauthorizedSecurityRemoval = $EnableUnauthorizedSecurityRemoval.IsPresent
        TenantName                     = $TenantName
        TenantSlug                     = $TenantSlug
        ComputerName                   = $ComputerName
        ComputerSlug                   = $ComputerSlug
        PendingReboot                  = $rebootState.IsPending
        PendingRebootSources           = $rebootState.Sources
        LogPath                        = $LogPath
    }
}

$approvedProductList = @(
    $ApprovedSecurityProducts -split ';' |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$payloadFolder = Resolve-PTIPayloadFolder -ZipPath $PTIPayloadZip
$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $payloadFolder -ScriptName 'pti-workstation-baseline.ps1'

switch -Regex ($Method) {
    '^(?i)Get$' {
        Get-PTIBaselineState -ApprovedProducts $approvedProductList
    }
    '^(?i)Test$' {
        Test-PTIBaselineCompliance -ApprovedProducts $approvedProductList
    }
    '^(?i)Set$' {
        & $entrypoint `
            -ApprovedSecurityProducts $approvedProductList `
            -EnableUnauthorizedSecurityRemoval:$EnableUnauthorizedSecurityRemoval.IsPresent `
            -SkipUnauthorizedSecurityRemoval:$SkipUnauthorizedSecurityRemoval.IsPresent `
            -SkipDellCleanup:$SkipDellCleanup.IsPresent `
            -SkipConsumerBloatwareRemoval:$SkipConsumerBloatwareRemoval.IsPresent `
            -SkipOneDriveRemoval:$SkipOneDriveRemoval.IsPresent `
            -SkipCortanaDisable:$SkipCortanaDisable.IsPresent `
            -SkipRemoteAssistance:$SkipRemoteAssistance.IsPresent `
            -LogPath $LogPath
        return $true
    }
    default {
        throw "Unsupported Immy combined-script method: $Method"
    }
}
