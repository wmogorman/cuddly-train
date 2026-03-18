#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('DriverStage', 'SharedCopiers', 'Scheduling', 'Sales', 'Accounting', 'Hp5000', 'DepartmentBundle')]
    [string[]]$InstallSet = @('DepartmentBundle'),

    [ValidateSet('Sales', 'Marketing', 'Scheduling', 'Production', 'Procurement', 'Quality', 'Engineering', 'Accounting', 'Management')]
    [string]$PrimaryDepartment,

    [switch]$NeedsAccountingPrinter,

    [switch]$NeedsHp5000,

    [string]$LexmarkDriverSourcePath,

    [string]$LexmarkInfRelativePath,

    [string]$LexmarkDriverName,

    [string]$HpDriverSourcePath,

    [string]$HpInfRelativePath,

    [string]$HpDriverName,

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\PrinterDrivers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-printers.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

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

    return @($keys.ToArray() | Sort-Object)
}

function Get-DriverFamiliesForQueueKeys {
    param(
        [string[]]$QueueKeys
    )

    $families = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($queueKey in $QueueKeys) {
        switch ($queueKey) {
            'FrontCopier' { [void]$families.Add('Lexmark') }
            'Copier2' { [void]$families.Add('Lexmark') }
            'Scheduling' { [void]$families.Add('Lexmark') }
            'Sales' { [void]$families.Add('Lexmark') }
            'Accounting' { [void]$families.Add('Lexmark') }
            'Hp5000' { [void]$families.Add('HP') }
        }
    }

    return @($families.ToArray() | Sort-Object)
}

function Install-PTIPrinterDriverFamily {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Lexmark', 'HP')]
        [string]$Family,

        [string]$SourcePath,

        [string]$InfRelativePath,

        [string]$DriverName,

        [pscredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($InfRelativePath) -or [string]::IsNullOrWhiteSpace($DriverName)) {
        throw "Driver family [$Family] requires SourcePath, InfRelativePath, and DriverName."
    }

    if ($PSCmdlet.ShouldProcess($DriverName, "Stage and import $Family printer driver from [$SourcePath]")) {
        $familyStageRoot = Join-Path -Path $StageRoot -ChildPath $Family
        $stagedSource = Copy-PTISourceToCache -SourcePath $SourcePath -DestinationRoot $familyStageRoot -Credential $Credential -LogPath $LogPath
        $infPath = Resolve-PTIRelativePath -BasePath $stagedSource -RelativePath $InfRelativePath

        if (-not (Test-Path -LiteralPath $infPath)) {
            throw "INF path not found for [$Family]: $infPath"
        }

        $infDirectory = Split-Path -Path $infPath -Parent
        $pnputilPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\pnputil.exe'
        $pnputilArguments = '/add-driver "{0}\*.inf" /subdirs /install' -f $infDirectory
        Invoke-PTIProcess -FilePath $pnputilPath -ArgumentList $pnputilArguments -WorkingDirectory $infDirectory -LogPath $LogPath | Out-Null

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
        DriverGroup = 'Lexmark'
    }
    Copier2 = @{
        Name        = 'Lexmark XS658de Copier #2'
        IpAddress   = '192.168.1.65'
        DriverGroup = 'Lexmark'
    }
    Scheduling = @{
        Name        = 'Scheduling MS810dn'
        IpAddress   = '192.168.1.13'
        DriverGroup = 'Lexmark'
    }
    Sales = @{
        Name        = 'Sales MS810dn'
        IpAddress   = '192.168.1.55'
        DriverGroup = 'Lexmark'
    }
    Accounting = @{
        Name        = 'Accounting MS810dn'
        IpAddress   = '192.168.1.66'
        DriverGroup = 'Lexmark'
    }
    Hp5000 = @{
        Name        = 'HP LaserJet 5000DN'
        IpAddress   = '192.168.1.128'
        DriverGroup = 'HP'
    }
}

$requestedQueueKeys = Resolve-PrinterQueueKeys -RequestedSets $InstallSet -Department $PrimaryDepartment -InstallAccounting $NeedsAccountingPrinter.IsPresent -InstallHp5000 $NeedsHp5000.IsPresent
$requiredFamilies = Get-DriverFamiliesForQueueKeys -QueueKeys $requestedQueueKeys

if ($InstallSet -contains 'DriverStage' -and $requiredFamilies.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($LexmarkDriverSourcePath)) {
        $requiredFamilies += 'Lexmark'
    }

    if (-not [string]::IsNullOrWhiteSpace($HpDriverSourcePath)) {
        $requiredFamilies += 'HP'
    }
}

$credential = New-PTICredential -UserName $ShareUserName -Password $SharePassword

foreach ($family in ($requiredFamilies | Sort-Object -Unique)) {
    switch ($family) {
        'Lexmark' {
            Install-PTIPrinterDriverFamily -Family 'Lexmark' -SourcePath $LexmarkDriverSourcePath -InfRelativePath $LexmarkInfRelativePath -DriverName $LexmarkDriverName -Credential $credential
        }
        'HP' {
            Install-PTIPrinterDriverFamily -Family 'HP' -SourcePath $HpDriverSourcePath -InfRelativePath $HpInfRelativePath -DriverName $HpDriverName -Credential $credential
        }
    }
}

foreach ($queueKey in $requestedQueueKeys) {
    $queue = $queueDefinitions[$queueKey]
    if (-not $queue) {
        throw "Unknown queue key: $queueKey"
    }

    $driverName = switch ($queue.DriverGroup) {
        'Lexmark' { $LexmarkDriverName }
        'HP' { $HpDriverName }
        default { throw "Unknown driver group [$($queue.DriverGroup)] for queue [$queueKey]." }
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
