#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('DriverStage', 'SharedCopiers', 'Scheduling', 'Sales', 'Accounting', 'Hp5000', 'DepartmentBundle')]
    [string[]]$InstallSet = @('DepartmentBundle'),

    [ValidateSet('Sales', 'Marketing', 'Scheduling', 'Production', 'Procurement', 'Quality', 'Engineering', 'Accounting', 'Management')]
    [string]$PrimaryDepartment,

    [switch]$NeedsAccountingPrinter,

    [switch]$NeedsHp5000,

    [string]$LexmarkCopierDriverSourcePath,

    [string]$LexmarkCopierInfRelativePath,

    [string]$LexmarkCopierInstallArguments,

    [string]$LexmarkCopierDriverName,

    [string]$LexmarkMonoDriverSourcePath,

    [string]$LexmarkMonoInfRelativePath,

    [string]$LexmarkMonoInstallArguments,

    [string]$LexmarkMonoDriverName,

    [string]$LexmarkDriverSourcePath,

    [string]$LexmarkInfRelativePath,

    [string]$LexmarkDriverName,

    [string]$HpDriverSourcePath,

    [string]$HpInfRelativePath,

    [string]$HpInstallArguments,

    [string]$HpDriverName,

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\PrinterDrivers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-printers.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

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
                InstallArguments = $LexmarkCopierInstallArguments
                DriverName      = if (-not [string]::IsNullOrWhiteSpace($LexmarkCopierDriverName)) { $LexmarkCopierDriverName } else { $LexmarkDriverName }
            }
        }
        'LexmarkMono' {
            return [pscustomobject]@{
                Family          = $Family
                SourcePath      = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoDriverSourcePath)) { $LexmarkMonoDriverSourcePath } else { $LexmarkDriverSourcePath }
                InfRelativePath = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoInfRelativePath)) { $LexmarkMonoInfRelativePath } else { $LexmarkInfRelativePath }
                InstallArguments = $LexmarkMonoInstallArguments
                DriverName      = if (-not [string]::IsNullOrWhiteSpace($LexmarkMonoDriverName)) { $LexmarkMonoDriverName } else { $LexmarkDriverName }
            }
        }
        'HP' {
            return [pscustomobject]@{
                Family          = $Family
                SourcePath      = $HpDriverSourcePath
                InfRelativePath = $HpInfRelativePath
                InstallArguments = $HpInstallArguments
                DriverName      = $HpDriverName
            }
        }
    }
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

function Install-PTIPrinterDriverFamily {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('LexmarkCopier', 'LexmarkMono', 'HP')]
        [string]$Family,

        [string]$SourcePath,

        [string]$InfRelativePath,

        [string]$InstallArguments,

        [string]$DriverName,

        [pscredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DriverName)) {
        throw "Driver family [$Family] requires SourcePath and DriverName."
    }

    if ($PSCmdlet.ShouldProcess($DriverName, "Stage and import $Family printer driver from [$SourcePath]")) {
        $familyStageRoot = Join-Path -Path $StageRoot -ChildPath $Family
        $stagedSource = Copy-PTISourceToCache -SourcePath $SourcePath -DestinationRoot $familyStageRoot -Credential $Credential -LogPath $LogPath
        $resolvedSourceRoot = $stagedSource

        if ((Test-Path -LiteralPath $stagedSource -PathType Leaf) -and ([System.IO.Path]::GetExtension($stagedSource) -ieq '.zip')) {
            $expandedRoot = Join-Path -Path $familyStageRoot -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($stagedSource))
            if (Test-Path -LiteralPath $expandedRoot) {
                Remove-Item -LiteralPath $expandedRoot -Recurse -Force
            }

            Write-PTILog -Message "Expanding ZIP printer package [$stagedSource] to [$expandedRoot]." -LogPath $LogPath
            Expand-Archive -LiteralPath $stagedSource -DestinationPath $expandedRoot -Force
            $resolvedSourceRoot = $expandedRoot
        }

        $packagePath = if ([string]::IsNullOrWhiteSpace($InfRelativePath)) {
            $resolvedSourceRoot
        }
        else {
            Resolve-PTIRelativePath -BasePath $resolvedSourceRoot -RelativePath $InfRelativePath
        }

        if (-not (Test-Path -LiteralPath $packagePath)) {
            throw "Driver package path not found for [$Family]: $packagePath"
        }

        $packageExtension = [System.IO.Path]::GetExtension($packagePath)
        if ($packageExtension -ieq '.msi') {
            $msiexecPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\msiexec.exe'
            $msiArguments = '/i "{0}" /qn /norestart' -f $packagePath
            Invoke-PTIProcess -FilePath $msiexecPath -ArgumentList $msiArguments -WorkingDirectory (Split-Path -Path $packagePath -Parent) -LogPath $LogPath | Out-Null
        }
        elseif ($packageExtension -ieq '.inf') {
            $infDirectory = Split-Path -Path $packagePath -Parent
            $pnputilPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\pnputil.exe'
            $pnputilArguments = '/add-driver "{0}\*.inf" /subdirs /install' -f $infDirectory
            Invoke-PTIProcess -FilePath $pnputilPath -ArgumentList $pnputilArguments -WorkingDirectory $infDirectory -LogPath $LogPath | Out-Null
        }
        elseif ($packageExtension -ieq '.exe') {
            if ([string]::IsNullOrWhiteSpace($InstallArguments)) {
                throw "Driver family [$Family] requires InstallArguments when SourcePath or package path points to an .exe installer."
            }

            Invoke-PTIProcess -FilePath $packagePath -ArgumentList $InstallArguments -WorkingDirectory (Split-Path -Path $packagePath -Parent) -LogPath $LogPath | Out-Null
        }
        else {
            throw "Unsupported driver package type for [$Family]: $packagePath"
        }

        $existingDriver = Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue
        if (-not $existingDriver -and $PSCmdlet.ShouldProcess($DriverName, 'Register printer driver')) {
            Add-PrinterDriver -Name $DriverName -ErrorAction Stop
        }
    }

    Write-PTILog -Message "Driver family [$Family] is ready with driver name [$DriverName]." -LogPath $LogPath
}

function Ensure-PTIPrinterQueue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$IpAddress,

        [Parameter(Mandatory = $true)]
        [string]$DriverName
    )

    $portName = 'IP_{0}' -f $IpAddress
    $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
    if (-not $existingPort -and $PSCmdlet.ShouldProcess($portName, "Create TCP/IP port for $IpAddress")) {
        Add-PrinterPort -Name $portName -PrinterHostAddress $IpAddress -ErrorAction Stop
    }

    $existingPrinter = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    if ($existingPrinter) {
        Write-PTILog -Message "Printer queue [$Name] already exists on port [$($existingPrinter.PortName)]." -LogPath $LogPath
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create printer queue on [$portName]")) {
        Add-Printer -Name $Name -DriverName $DriverName -PortName $portName -ErrorAction Stop
    }
}

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

$requestedQueueKeys = @(Resolve-PrinterQueueKeys -RequestedSets $InstallSet -Department $PrimaryDepartment -InstallAccounting $NeedsAccountingPrinter.IsPresent -InstallHp5000 $NeedsHp5000.IsPresent)
$requiredFamilies = @(Get-DriverFamiliesForQueueKeys -QueueKeys $requestedQueueKeys)

if ($InstallSet -contains 'DriverStage' -and $requiredFamilies.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace((Get-PTIPrinterDriverConfiguration -Family 'LexmarkCopier').SourcePath)) {
        $requiredFamilies += 'LexmarkCopier'
    }

    if (-not [string]::IsNullOrWhiteSpace((Get-PTIPrinterDriverConfiguration -Family 'LexmarkMono').SourcePath)) {
        $requiredFamilies += 'LexmarkMono'
    }

    if (-not [string]::IsNullOrWhiteSpace($HpDriverSourcePath)) {
        $requiredFamilies += 'HP'
    }
}

$credential = New-PTICredential -UserName $ShareUserName -Password $SharePassword

foreach ($family in ($requiredFamilies | Sort-Object -Unique)) {
    $driverConfiguration = Get-PTIPrinterDriverConfiguration -Family $family
    Install-PTIPrinterDriverFamily -Family $family -SourcePath $driverConfiguration.SourcePath -InfRelativePath $driverConfiguration.InfRelativePath -InstallArguments $driverConfiguration.InstallArguments -DriverName $driverConfiguration.DriverName -Credential $credential
}

foreach ($queueKey in $requestedQueueKeys) {
    $queue = $queueDefinitions[$queueKey]
    if (-not $queue) {
        throw "Unknown queue key: $queueKey"
    }

    $driverConfiguration = Get-PTIPrinterDriverConfiguration -Family $queue.DriverGroup
    $driverName = $driverConfiguration.DriverName
    if ([string]::IsNullOrWhiteSpace($driverName)) {
        throw "Driver name is missing for queue [$queueKey] and family [$($queue.DriverGroup)]."
    }

    Ensure-PTIPrinterQueue -Name $queue.Name -IpAddress $queue.IpAddress -DriverName $driverName
}

[pscustomobject]@{
    InstallSet        = $InstallSet
    PrimaryDepartment = $PrimaryDepartment
    QueueKeys         = $requestedQueueKeys
    DriverFamilies    = $requiredFamilies
    LogPath           = $LogPath
}
