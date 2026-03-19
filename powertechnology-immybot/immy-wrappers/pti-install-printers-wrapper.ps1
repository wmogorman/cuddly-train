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

    [ValidateSet('DriverStage', 'SharedCopiers', 'Scheduling', 'Sales', 'Accounting', 'Hp5000', 'DepartmentBundle')]
    [string[]]$InstallSet = @('DepartmentBundle'),

    [ValidateSet('Sales', 'Marketing', 'Scheduling', 'Production', 'Procurement', 'Quality', 'Engineering', 'Accounting', 'Management')]
    [string]$PrimaryDepartment,

    [switch]$NeedsAccountingPrinter,

    [switch]$NeedsHp5000,

    [string]$LexmarkCopierDriverSourcePath,

    [string]$LexmarkCopierInfRelativePath,

    [string]$LexmarkCopierDriverName,

    [string]$LexmarkMonoDriverSourcePath,

    [string]$LexmarkMonoInfRelativePath,

    [string]$LexmarkMonoDriverName,

    [string]$LexmarkDriverSourcePath,

    [string]$LexmarkInfRelativePath,

    [string]$LexmarkDriverName,

    [string]$HpDriverSourcePath,

    [string]$HpInfRelativePath,

    [string]$HpDriverName,

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\PrinterDrivers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-printers.log',

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

function Resolve-PrinterQueueKeys {
    param(
        [string[]]$RequestedSets,
        [string]$Department,
        [bool]$InstallAccounting,
        [bool]$InstallHp5000
    )

    $keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($setName in $RequestedSets) {
        switch ($setName) {
            'DriverStage' {
                continue
            }
            'SharedCopiers' {
                [void]$keys.Add('FrontCopier')
                [void]$keys.Add('Copier2')
            }
            'Scheduling' {
                [void]$keys.Add('Scheduling')
            }
            'Sales' {
                [void]$keys.Add('Sales')
            }
            'Accounting' {
                [void]$keys.Add('Accounting')
            }
            'Hp5000' {
                [void]$keys.Add('Hp5000')
            }
            'DepartmentBundle' {
                [void]$keys.Add('FrontCopier')
                [void]$keys.Add('Copier2')

                if ($Department -eq 'Scheduling') {
                    [void]$keys.Add('Scheduling')
                }

                if ($Department -eq 'Sales') {
                    [void]$keys.Add('Sales')
                }

                if ($InstallAccounting) {
                    [void]$keys.Add('Accounting')
                }

                if ($InstallHp5000 -or $Department -in @('Engineering', 'Marketing')) {
                    [void]$keys.Add('Hp5000')
                }
            }
        }
    }

    return @($keys | Sort-Object)
}

function Get-PTIPrinterDriverConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('LexmarkCopier', 'LexmarkMono', 'HP')]
        [string]$Family
    )

    switch ($Family) {
        'LexmarkCopier' {
            return [pscustomobject]@{
                Family          = $Family
                SourcePath      = if (-not [string]::IsNullOrWhiteSpace($LexmarkCopierDriverSourcePath)) { $LexmarkCopierDriverSourcePath } else { $LexmarkDriverSourcePath }
                InfRelativePath = if (-not [string]::IsNullOrWhiteSpace($LexmarkCopierInfRelativePath)) { $LexmarkCopierInfRelativePath } else { $LexmarkInfRelativePath }
                DriverName      = if (-not [string]::IsNullOrWhiteSpace($LexmarkCopierDriverName)) { $LexmarkCopierDriverName } else { $LexmarkDriverName }
            }
        }
        'LexmarkMono' {
            return [pscustomobject]@{
                Family          = $Family
                SourcePath      = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoDriverSourcePath)) { $LexmarkMonoDriverSourcePath } else { $LexmarkDriverSourcePath }
                InfRelativePath = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoInfRelativePath)) { $LexmarkMonoInfRelativePath } else { $LexmarkInfRelativePath }
                DriverName      = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoDriverName)) { $LexmarkMonoDriverName } else { $LexmarkDriverName }
            }
        }
        'HP' {
            return [pscustomobject]@{
                Family          = $Family
                SourcePath      = $HpDriverSourcePath
                InfRelativePath = $HpInfRelativePath
                DriverName      = $HpDriverName
            }
        }
    }
}

function Get-DriverFamiliesForQueueKeys {
    param(
        [string[]]$QueueKeys
    )

    $families = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($queueKey in $QueueKeys) {
        switch ($queueKey) {
            'FrontCopier' { [void]$families.Add('LexmarkCopier') }
            'Copier2' { [void]$families.Add('LexmarkCopier') }
            'Scheduling' { [void]$families.Add('LexmarkMono') }
            'Sales' { [void]$families.Add('LexmarkMono') }
            'Accounting' { [void]$families.Add('LexmarkMono') }
            'Hp5000' { [void]$families.Add('HP') }
        }
    }

    return @($families | Sort-Object)
}

function Test-PTIPrinterCompliance {
    $issues = [System.Collections.Generic.List[string]]::new()
    $queueDefinitions = @{
        FrontCopier = @{
            Name        = 'Lexmark XS658de Front Copier'
            IpAddress   = '192.168.1.64'
            DriverGroup = 'LexmarkCopier'
        }
        Copier2 = @{
            Name        = 'Lexmark XS658de Copier #2'
            IpAddress   = '192.168.1.65'
            DriverGroup = 'LexmarkCopier'
        }
        Scheduling = @{
            Name        = 'Scheduling MS810dn'
            IpAddress   = '192.168.1.13'
            DriverGroup = 'LexmarkMono'
        }
        Sales = @{
            Name        = 'Sales MS810dn'
            IpAddress   = '192.168.1.55'
            DriverGroup = 'LexmarkMono'
        }
        Accounting = @{
            Name        = 'Accounting MS810dn'
            IpAddress   = '192.168.1.66'
            DriverGroup = 'LexmarkMono'
        }
        Hp5000 = @{
            Name        = 'HP LaserJet 5000DN'
            IpAddress   = '192.168.1.128'
            DriverGroup = 'HP'
        }
    }

    $queueKeys = @(Resolve-PrinterQueueKeys -RequestedSets $InstallSet -Department $PrimaryDepartment -InstallAccounting $NeedsAccountingPrinter.IsPresent -InstallHp5000 $NeedsHp5000.IsPresent)
    $requiredFamilies = @(Get-DriverFamiliesForQueueKeys -QueueKeys $queueKeys)

    if ($InstallSet -contains 'DriverStage' -and $requiredFamilies.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace((Get-PTIPrinterDriverConfiguration -Family 'LexmarkCopier').DriverName)) {
            $requiredFamilies += 'LexmarkCopier'
        }

        if (-not [string]::IsNullOrWhiteSpace((Get-PTIPrinterDriverConfiguration -Family 'LexmarkMono').DriverName)) {
            $requiredFamilies += 'LexmarkMono'
        }

        if (-not [string]::IsNullOrWhiteSpace($HpDriverName)) {
            $requiredFamilies += 'HP'
        }
    }

    foreach ($family in ($requiredFamilies | Sort-Object -Unique)) {
        $driverName = (Get-PTIPrinterDriverConfiguration -Family $family).DriverName

        if ([string]::IsNullOrWhiteSpace($driverName)) {
            $issues.Add("Driver name is missing for family [$family].") | Out-Null
            continue
        }

        if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
            $issues.Add("Printer driver is missing: $driverName") | Out-Null
        }
    }

    foreach ($queueKey in $queueKeys) {
        $queue = $queueDefinitions[$queueKey]
        if (-not $queue) {
            $issues.Add("Unknown queue key requested: $queueKey") | Out-Null
            continue
        }

        $expectedDriver = (Get-PTIPrinterDriverConfiguration -Family $queue.DriverGroup).DriverName

        $printer = Get-Printer -Name $queue.Name -ErrorAction SilentlyContinue
        if (-not $printer) {
            $issues.Add("Printer queue is missing: $($queue.Name)") | Out-Null
            continue
        }

        $expectedPort = 'IP_{0}' -f $queue.IpAddress
        if ($printer.PortName -ne $expectedPort) {
            $issues.Add("Printer queue [$($queue.Name)] is on [$($printer.PortName)] instead of [$expectedPort].") | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($expectedDriver) -and $printer.DriverName -ne $expectedDriver) {
            $issues.Add("Printer queue [$($queue.Name)] uses driver [$($printer.DriverName)] instead of [$expectedDriver].") | Out-Null
        }
    }

    if ($issues.Count -gt 0) {
        Write-Warning ('PTI printer configuration is not compliant: ' + ($issues -join ' | '))
        return $false
    }

    Write-Host 'PTI printer configuration is compliant.'
    return $true
}

function Get-PTIPrinterState {
    $queueKeys = @(Resolve-PrinterQueueKeys -RequestedSets $InstallSet -Department $PrimaryDepartment -InstallAccounting $NeedsAccountingPrinter.IsPresent -InstallHp5000 $NeedsHp5000.IsPresent)
    $requiredFamilies = @(Get-DriverFamiliesForQueueKeys -QueueKeys $queueKeys)
    $isCompliant = Test-PTIPrinterCompliance

    return [pscustomobject]@{
        Compliant         = $isCompliant
        InstallSet        = @($InstallSet)
        PrimaryDepartment = $PrimaryDepartment
        QueueKeys         = $queueKeys
        DriverFamilies    = $requiredFamilies
        TenantName        = $TenantName
        TenantSlug        = $TenantSlug
        ComputerName      = $ComputerName
        ComputerSlug      = $ComputerSlug
        LogPath           = $LogPath
    }
}

$payloadFolder = Resolve-PTIPayloadFolder -ZipPath $PTIPayloadZip
$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $payloadFolder -ScriptName 'pti-install-printers.ps1'

switch -Regex ($Method) {
    '^(?i)Get$' {
        Get-PTIPrinterState
    }
    '^(?i)Test$' {
        Test-PTIPrinterCompliance
    }
    '^(?i)Set$' {
        & $entrypoint `
            -InstallSet $InstallSet `
            -PrimaryDepartment $PrimaryDepartment `
            -NeedsAccountingPrinter:$NeedsAccountingPrinter.IsPresent `
            -NeedsHp5000:$NeedsHp5000.IsPresent `
            -LexmarkCopierDriverSourcePath $LexmarkCopierDriverSourcePath `
            -LexmarkCopierInfRelativePath $LexmarkCopierInfRelativePath `
            -LexmarkCopierDriverName $LexmarkCopierDriverName `
            -LexmarkMonoDriverSourcePath $LexmarkMonoDriverSourcePath `
            -LexmarkMonoInfRelativePath $LexmarkMonoInfRelativePath `
            -LexmarkMonoDriverName $LexmarkMonoDriverName `
            -LexmarkDriverSourcePath $LexmarkDriverSourcePath `
            -LexmarkInfRelativePath $LexmarkInfRelativePath `
            -LexmarkDriverName $LexmarkDriverName `
            -HpDriverSourcePath $HpDriverSourcePath `
            -HpInfRelativePath $HpInfRelativePath `
            -HpDriverName $HpDriverName `
            -ShareUserName $ShareUserName `
            -SharePassword $SharePassword `
            -StageRoot $StageRoot `
            -LogPath $LogPath
        return $true
    }
    default {
        throw "Unsupported Immy combined-script method: $Method"
    }
}
