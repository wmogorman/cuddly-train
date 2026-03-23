<#
.SYNOPSIS
Provision or reuse the Azure VM and supporting resources for DF Remote.

.DESCRIPTION
Creates or reuses the Azure resource group, networking, public IP, NSG, managed
data disk, and Ubuntu VM used for DF Remote. On first creation, the script sends
cloud-init that prepares `/srv/dfremote`, writes a `dfremote.service` unit, and
opens SSH plus UDP 1235.

Usage notes:
  - Run `Connect-AzAccount` first, then pass a valid `-SubscriptionId`.
  - Provide `-AdminPassword` directly or store one in
    `dfremote-password.txt` with `write-dfremote-password.ps1`.
  - `dfremote-password.txt` uses Windows DPAPI, so the same Windows user on the
    same workstation must create and read it.
  - Rerunning the script is safe for the Azure resources it manages. If the VM
    already exists, the script reuses it and skips VM creation.
  - Cloud-init only runs when the VM is first created. Rerunning the script does
    not replay package installs or recreate files inside an existing VM.
  - Optional install automation is available with `-InstallDfRemote`. Supply a
    workstation-local zip via `-DfRemoteZipPath` or a verified download URI via
    `-DfRemoteZipUri`, plus `-SshPrivateKeyPath` so the script can copy files
    and run remote install commands over SSH.
  - `-StartService` can be used alongside `-InstallDfRemote`, or by itself to
    enable and start an already-installed `dfremote` service over SSH.

.PARAMETER SubscriptionId
Azure subscription ID that owns the DF Remote resources.

.PARAMETER ResourceGroupName
Resource group to create or reuse.

.PARAMETER Location
Azure region, for example `eastus`.

.PARAMETER VmName
Name of the DF Remote VM.

.PARAMETER AdminUsername
Linux admin username created on the VM.

.PARAMETER AdminPassword
SecureString password for the VM admin user.

.PARAMETER AdminPasswordFile
Path to a DPAPI-protected password file created by `write-dfremote-password.ps1`.

.PARAMETER GithubUserForSsh
Optional GitHub username whose public keys are appended to `authorized_keys`.

.PARAMETER SshPublicKeyData
Optional raw SSH public key strings to inject into `authorized_keys`.

.PARAMETER VmSize
Azure VM size to provision, for example `Standard_B2s`.

.PARAMETER DataDiskSizeGB
Size in GB for the managed data disk mounted at `/srv/dfremote`.

.PARAMETER VNetName
Virtual network name to create or reuse.

.PARAMETER SubnetName
Subnet name inside the selected virtual network.

.PARAMETER AddressPrefix
Address space assigned to the virtual network.

.PARAMETER SubnetPrefix
Address prefix assigned to the subnet.

.PARAMETER PublicIpName
Public IP resource name to create or reuse.

.PARAMETER NicName
Network interface name to create or reuse.

.PARAMETER NsgName
Network security group name to create or reuse.

.PARAMETER DataDiskName
Managed data disk name to create, attach, or verify on reruns.

.PARAMETER InstallDfRemote
Copy or download the DF Remote zip and install it into `/opt/dfremote` over SSH
after the VM is reachable.

.PARAMETER DfRemoteZipPath
Path on the local workstation to the DF Remote zip file to copy to the VM.

.PARAMETER DfRemoteZipUri
HTTPS URI for the DF Remote zip file to download directly on the VM.

.PARAMETER DfRemoteZipSha256
Expected SHA-256 hash for the DF Remote zip. Required when `-DfRemoteZipUri` is
used and optional when `-DfRemoteZipPath` is used.

.PARAMETER SshPrivateKeyPath
Path to the SSH private key that matches a public key already authorized for the
VM admin user. Required for `-InstallDfRemote` and `-StartService`.

.PARAMETER SshPort
SSH port used for post-provisioning install and service actions.

.PARAMETER SshReadyTimeoutSeconds
How long to wait for SSH to become reachable before install/start steps fail.

.PARAMETER AllowInsecureDfRemoteDownload
Allow a non-HTTPS `-DfRemoteZipUri`. Intended only for trusted internal mirrors.

.EXAMPLE
PS> .\dfremote-azure\write-dfremote-password.ps1
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william'

Creates the VM and related Azure resources, reading the admin password from
`dfremote-azure\dfremote-password.txt`.

.EXAMPLE
PS> $pw = ConvertTo-SecureString 'Str0ng!Passw0rd123' -AsPlainText -Force
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -AdminPassword $pw -GithubUserForSsh 'wmogorman'

Creates the VM using an explicit SecureString password and imports SSH keys from
GitHub.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william'

Reruns against an existing deployment. Existing shared resources are reused and
VM creation is skipped if `dfremote-vm` already exists.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -InstallDfRemote -DfRemoteZipPath 'C:\Installers\dfremote-complete-4705-Linux.zip' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -StartService

Copies a local DF Remote zip to the VM over SSH, extracts it into
`/opt/dfremote`, runs the library fixup script, and enables plus starts the
service.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -InstallDfRemote -DfRemoteZipUri 'https://example.invalid/dfremote.zip' -DfRemoteZipSha256 '<sha256>' -SshPrivateKeyPath "$HOME\.ssh\id_rsa"

Downloads a verified DF Remote zip directly on the VM and installs it without
starting the service.

.NOTES
Author: you + ChatGPT
Last updated: 2026-03-23
#>

param(
  [Parameter(Mandatory=$true)] [string] $SubscriptionId,
  [Parameter(Mandatory=$true)] [string] $ResourceGroupName,
  [Parameter(Mandatory=$true)] [string] $Location,                  # e.g. "eastus"
  [Parameter(Mandatory=$true)] [string] $VmName,                    # e.g. "dfremote-vm"
  [Parameter(Mandatory=$true)] [string] $AdminUsername,             # e.g. "william"
  [SecureString] $AdminPassword,
  [string] $AdminPasswordFile = (Join-Path -Path $PSScriptRoot -ChildPath 'dfremote-password.txt'),
  [string] $GithubUserForSsh,                                       # e.g. "wmogorman" to pull keys from https://github.com/<user>.keys
  [string[]] $SshPublicKeyData,                                     # Optional raw SSH public key strings
  [string] $VmSize = "Standard_B2s",                                # tweak as needed
  [int]    $DataDiskSizeGB = 64,                                    # persistence disk
  [string] $VNetName = "$($ResourceGroupName)-vnet",
  [string] $SubnetName = "default",
  [string] $AddressPrefix = "10.20.0.0/16",
  [string] $SubnetPrefix = "10.20.1.0/24",
  [string] $PublicIpName = "$($VmName)-pip",
  [string] $NicName = "$($VmName)-nic",
  [string] $NsgName = "$($VmName)-nsg",
  [string] $DataDiskName = "$($VmName)-data",
  [switch] $InstallDfRemote,
  [string] $DfRemoteZipPath,
  [string] $DfRemoteZipUri,
  [string] $DfRemoteZipSha256,
  [string] $SshPrivateKeyPath,
  [int] $SshPort = 22,
  [int] $SshReadyTimeoutSeconds = 180,
  [switch] $StartService,
  [switch] $AllowInsecureDfRemoteDownload
)

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory=$true)] [string] $Path,
    [Parameter(Mandatory=$true)] [string] $ParameterName
  )

  $resolved = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
  if (-not $resolved) {
    throw "$ParameterName not found at $Path"
  }
  return $resolved.ProviderPath
}

function ConvertTo-BashSingleQuotedString {
  param([AllowNull()] [string] $Value)

  if ($null -eq $Value) {
    return "''"
  }

  return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Invoke-ExternalCommand {
  param(
    [Parameter(Mandatory=$true)] [string] $FilePath,
    [string[]] $Arguments = @(),
    [Parameter(Mandatory=$true)] [string] $FailureMessage
  )

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "$FailureMessage (exit code $exitCode)."
  }
}

function Wait-ForTcpPort {
  param(
    [Parameter(Mandatory=$true)] [string] $HostName,
    [int] $Port = 22,
    [int] $TimeoutSeconds = 180
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
      $async = $client.BeginConnect($HostName, $Port, $null, $null)
      if ($async.AsyncWaitHandle.WaitOne(3000, $false) -and $client.Connected) {
        $client.EndConnect($async)
        return
      }
    } catch {
      # Retry until the timeout expires.
    } finally {
      if ($async -and $async.AsyncWaitHandle) {
        $async.AsyncWaitHandle.Close()
      }
      $client.Close()
      $client.Dispose()
    }
    Start-Sleep -Seconds 3
  }

  throw "Timed out waiting for TCP $Port on $HostName after $TimeoutSeconds seconds."
}

function Get-OpenSshCommandPath {
  param([Parameter(Mandatory=$true)] [string] $CommandName)

  $command = Get-Command $CommandName -ErrorAction SilentlyContinue
  if (-not $command) {
    throw "Required command '$CommandName' was not found in PATH. Install OpenSSH client tooling first."
  }
  return $command.Source
}

function Copy-FileToVmOverScp {
  param(
    [Parameter(Mandatory=$true)] [string] $LocalPath,
    [Parameter(Mandatory=$true)] [string] $RemotePath,
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $UserName,
    [Parameter(Mandatory=$true)] [string] $PrivateKeyPath,
    [int] $Port = 22
  )

  $scpPath = Get-OpenSshCommandPath -CommandName 'scp'
  $arguments = @(
    '-i', $PrivateKeyPath,
    '-P', [string]$Port,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=15',
    $LocalPath,
    "${UserName}@${HostName}:$RemotePath"
  )
  Invoke-ExternalCommand -FilePath $scpPath -Arguments $arguments -FailureMessage "SCP upload to $HostName failed"
}

function Invoke-SshCommandOnVm {
  param(
    [Parameter(Mandatory=$true)] [string] $CommandText,
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $UserName,
    [Parameter(Mandatory=$true)] [string] $PrivateKeyPath,
    [int] $Port = 22
  )

  $sshPath = Get-OpenSshCommandPath -CommandName 'ssh'
  $arguments = @(
    '-i', $PrivateKeyPath,
    '-p', [string]$Port,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=15',
    "${UserName}@${HostName}",
    $CommandText
  )
  Invoke-ExternalCommand -FilePath $sshPath -Arguments $arguments -FailureMessage "SSH command on $HostName failed"
}

function Invoke-DfRemotePostProvisioning {
  param(
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $UserName,
    [Parameter(Mandatory=$true)] [string] $PrivateKeyPath,
    [int] $Port = 22,
    [int] $ReadyTimeoutSeconds = 180,
    [switch] $InstallPackage,
    [string] $LocalZipPath,
    [string] $ZipUri,
    [string] $ZipSha256,
    [switch] $AllowInsecureDownload,
    [switch] $StartDfRemoteService
  )

  Write-Host "Waiting for SSH on ${HostName}:$Port..." -ForegroundColor Cyan
  Wait-ForTcpPort -HostName $HostName -Port $Port -TimeoutSeconds $ReadyTimeoutSeconds

  $runId = [Guid]::NewGuid().ToString('N')
  $remoteZipPath = if ($InstallPackage) { "/tmp/dfremote-package-$runId.zip" } else { '' }
  $remoteScriptPath = "/tmp/dfremote-postprovision-$runId.sh"
  $localScriptPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "dfremote-postprovision-$runId.sh"

  try {
    if ($InstallPackage -and $LocalZipPath) {
      Write-Host "Uploading DF Remote package to $HostName..." -ForegroundColor Cyan
      Copy-FileToVmOverScp -LocalPath $LocalZipPath -RemotePath $remoteZipPath -HostName $HostName -UserName $UserName -PrivateKeyPath $PrivateKeyPath -Port $Port
    }

    $remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_PACKAGE=__INSTALL_PACKAGE__
DOWNLOAD_URI=__DOWNLOAD_URI__
DOWNLOAD_SHA256=__DOWNLOAD_SHA256__
ALLOW_INSECURE_DOWNLOAD=__ALLOW_INSECURE_DOWNLOAD__
START_SERVICE=__START_SERVICE__
REMOTE_ZIP_PATH=__REMOTE_ZIP_PATH__
INSTALL_ROOT='/opt/dfremote'

cleanup() {
  if [ -n "$REMOTE_ZIP_PATH" ] && [[ "$REMOTE_ZIP_PATH" == /tmp/* ]]; then
    rm -f "$REMOTE_ZIP_PATH"
  fi
}
trap cleanup EXIT

if command -v cloud-init >/dev/null 2>&1; then
  sudo cloud-init status --wait >/dev/null
fi

if [ "$INSTALL_PACKAGE" = 'true' ]; then
  if [ -n "$DOWNLOAD_URI" ]; then
    if [ "$ALLOW_INSECURE_DOWNLOAD" != 'true' ] && [[ "$DOWNLOAD_URI" != https://* ]]; then
      echo "Refusing non-HTTPS DF Remote zip URI: $DOWNLOAD_URI" >&2
      exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo 'curl is required but not installed.' >&2; exit 1; }
    curl -fsSL "$DOWNLOAD_URI" -o "$REMOTE_ZIP_PATH"
  fi

  [ -f "$REMOTE_ZIP_PATH" ] || { echo "DF Remote zip not found at $REMOTE_ZIP_PATH" >&2; exit 1; }
  command -v unzip >/dev/null 2>&1 || { echo 'unzip is required but not installed.' >&2; exit 1; }

  if [ -n "$DOWNLOAD_SHA256" ]; then
    command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required but not installed.' >&2; exit 1; }
    echo "$DOWNLOAD_SHA256  $REMOTE_ZIP_PATH" | sha256sum -c -
  fi

  sudo mkdir -p "$INSTALL_ROOT"
  sudo unzip -o "$REMOTE_ZIP_PATH" -d "$INSTALL_ROOT"
  if [ -x /usr/local/sbin/dfremote-fix-libs.sh ]; then
    sudo /usr/local/sbin/dfremote-fix-libs.sh
  fi
  [ -f "$INSTALL_ROOT/bin/dfremote-server" ] || { echo "Expected $INSTALL_ROOT/bin/dfremote-server after unzip." >&2; exit 1; }
  sudo chmod 0755 "$INSTALL_ROOT/bin/dfremote-server"
fi

sudo systemctl daemon-reload
if [ "$START_SERVICE" = 'true' ]; then
  sudo systemctl enable --now dfremote
else
  sudo systemctl enable dfremote >/dev/null 2>&1 || true
fi

sudo systemctl --no-pager --full status dfremote || true
'@

    $remoteScript = $remoteScript.Replace('__INSTALL_PACKAGE__', (ConvertTo-BashSingleQuotedString -Value ([string]$InstallPackage.IsPresent).ToLowerInvariant()))
    $remoteScript = $remoteScript.Replace('__DOWNLOAD_URI__', (ConvertTo-BashSingleQuotedString -Value $ZipUri))
    $remoteScript = $remoteScript.Replace('__DOWNLOAD_SHA256__', (ConvertTo-BashSingleQuotedString -Value $ZipSha256))
    $remoteScript = $remoteScript.Replace('__ALLOW_INSECURE_DOWNLOAD__', (ConvertTo-BashSingleQuotedString -Value ([string]$AllowInsecureDownload.IsPresent).ToLowerInvariant()))
    $remoteScript = $remoteScript.Replace('__START_SERVICE__', (ConvertTo-BashSingleQuotedString -Value ([string]$StartDfRemoteService.IsPresent).ToLowerInvariant()))
    $remoteScript = $remoteScript.Replace('__REMOTE_ZIP_PATH__', (ConvertTo-BashSingleQuotedString -Value $remoteZipPath))

    [System.IO.File]::WriteAllText($localScriptPath, ($remoteScript -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    Copy-FileToVmOverScp -LocalPath $localScriptPath -RemotePath $remoteScriptPath -HostName $HostName -UserName $UserName -PrivateKeyPath $PrivateKeyPath -Port $Port

    $quotedRemoteScriptPath = ConvertTo-BashSingleQuotedString -Value $remoteScriptPath
    $remoteCommand = "bash $quotedRemoteScriptPath; status=`$?; rm -f $quotedRemoteScriptPath; exit `$status"
    Invoke-SshCommandOnVm -CommandText $remoteCommand -HostName $HostName -UserName $UserName -PrivateKeyPath $PrivateKeyPath -Port $Port
  } finally {
    Remove-Item -Path $localScriptPath -Force -ErrorAction SilentlyContinue
  }
}

if ($InstallDfRemote -and [string]::IsNullOrWhiteSpace($DfRemoteZipPath) -and [string]::IsNullOrWhiteSpace($DfRemoteZipUri)) {
  throw "InstallDfRemote requires either -DfRemoteZipPath or -DfRemoteZipUri."
}

if ($InstallDfRemote -and $DfRemoteZipPath -and $DfRemoteZipUri) {
  throw "Specify only one of -DfRemoteZipPath or -DfRemoteZipUri."
}

if (($InstallDfRemote -or $StartService) -and [string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
  throw "-SshPrivateKeyPath is required when using -InstallDfRemote or -StartService."
}

if ($DfRemoteZipUri -and -not $InstallDfRemote) {
  throw "-DfRemoteZipUri is only valid with -InstallDfRemote."
}

if ($DfRemoteZipPath -and -not $InstallDfRemote) {
  throw "-DfRemoteZipPath is only valid with -InstallDfRemote."
}

if ($DfRemoteZipSha256 -and -not $InstallDfRemote) {
  throw "-DfRemoteZipSha256 is only valid with -InstallDfRemote."
}

if ($DfRemoteZipUri -and -not $DfRemoteZipSha256) {
  throw "-DfRemoteZipSha256 is required when using -DfRemoteZipUri."
}

if ($DfRemoteZipUri -and -not $AllowInsecureDfRemoteDownload -and ($DfRemoteZipUri -notmatch '^https://')) {
  throw "-DfRemoteZipUri must use HTTPS unless -AllowInsecureDfRemoteDownload is specified."
}

if ($DfRemoteZipPath) {
  $DfRemoteZipPath = Resolve-ExistingPath -Path $DfRemoteZipPath -ParameterName 'DfRemoteZipPath'
}

if ($SshPrivateKeyPath) {
  $SshPrivateKeyPath = Resolve-ExistingPath -Path $SshPrivateKeyPath -ParameterName 'SshPrivateKeyPath'
}

# ---------- Login / Context ----------
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null

# ---------- Resource Group ----------
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
  New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

# ---------- Networking ----------
$vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $vnet) {
  $subnetCfg = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetPrefix
  $vnet = New-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $AddressPrefix -Subnet $subnetCfg
}
$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }

# Public IP (Standard / static)
$pip = Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $pip) {
  $pip = New-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard
}

# NSG with SSH (22) and DF Remote UDP (1235)
$nsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $nsg) {
  $nsg = New-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $ResourceGroupName -Location $Location
  # SSH
  $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-SSH" -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange 22 -Access Allow | Out-Null
  # DF Remote UDP 1235
  $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-DFRemote-UDP-1235" -Protocol Udp -Direction Inbound -Priority 1010 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange 1235 -Access Allow | Out-Null
  Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
}

# NIC
$nic = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $nic) {
  $nic = New-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -Location $Location `
          -SubnetId $subnet.Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id
}

# ---------- Data Disk (create first so cloud-init can see it on first boot) ----------
$expectedVmId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName"
$dataDisk = Get-AzDisk -Name $DataDiskName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $dataDisk) {
  $diskConfig = New-AzDiskConfig -SkuName Premium_LRS -Location $Location -CreateOption Empty -DiskSizeGB $DataDiskSizeGB
  $dataDisk = New-AzDisk -DiskName $DataDiskName -Disk $diskConfig -ResourceGroupName $ResourceGroupName
} elseif ($dataDisk.ManagedBy -and ($dataDisk.ManagedBy -ne $expectedVmId)) {
  throw "Data disk $DataDiskName is already attached to another VM ($($dataDisk.ManagedBy)). Choose a different -DataDiskName."
}

# ---------- Admin Password ----------
if (-not $AdminPassword) {
  if (-not (Test-Path -Path $AdminPasswordFile)) {
    throw "Admin password file not found at $AdminPasswordFile. Create it with ConvertFrom-SecureString (DPAPI) on this machine."
  }
  $encryptedAdminPassword = (Get-Content -Path $AdminPasswordFile -Raw).Trim()
  if (-not $encryptedAdminPassword) {
    throw "Admin password file at $AdminPasswordFile is empty."
  }
  try {
    $AdminPassword = ConvertTo-SecureString -String $encryptedAdminPassword
  } catch {
    throw "Failed to convert admin password from $AdminPasswordFile. Regenerate it on the same account that will run this script."
  }
}

if (-not $AdminPassword) {
  throw "Admin password not provided. Pass -AdminPassword or ensure dfremote-password.txt exists."
}

$adminCredential = New-Object -TypeName PSCredential -ArgumentList $AdminUsername, $AdminPassword

# ---------- SSH Keys (optional) ----------
$sshPublicKeys = @()

if ($GithubUserForSsh) {
  $githubKeysUri = "https://github.com/$GithubUserForSsh.keys"
  # GitHub requires TLS 1.2
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    $githubKeysContent = (Invoke-WebRequest -Uri $githubKeysUri -UseBasicParsing -ErrorAction Stop).Content
  } catch {
    throw "Failed to download SSH keys for GitHub user '$GithubUserForSsh' from $githubKeysUri. $($_.Exception.Message)"
  }
  $githubKeys = $githubKeysContent -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if (-not $githubKeys) {
    throw "No SSH public keys found for GitHub user '$GithubUserForSsh' at $githubKeysUri."
  }
  $sshPublicKeys += $githubKeys
}

if ($SshPublicKeyData) {
  $sshPublicKeys += $SshPublicKeyData | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# ---------- Cloud-Init (user-data) ----------
# Prepares:
#  - user/group
#  - UFW rules (22/tcp, 1235/udp)
#  - formats/ mounts the attached data disk at /srv/dfremote (by UUID in /etc/fstab)
#  - creates /opt/dfremote and a systemd unit `dfremote.service` that runs $BIN with --data-dir
#  - puts a README with next steps
$cloudInit = @'
#cloud-config
package_update: true
packages:
  - unzip
  - curl
  - jq
  - xfsprogs
  - ufw
  - libgtk2.0-0
  - libglu1-mesa
  - libsdl1.2debian
  - libsdl-image1.2
  - libsdl-ttf2.0-0
  - libxcursor1
  - libxinerama1
  - libxxf86vm1
  - libopenal1
  - libsndfile1
  - libncurses5
  - libncursesw5
  - libtinfo5
  - libstdc++6

users:
  - name: __ADMIN_USERNAME__
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [ adm, sudo ]
    shell: /bin/bash

write_files:
  - path: /usr/local/sbin/dfremote-fix-libs.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      ROOT="/opt/dfremote"
      LIB="$ROOT/libs/libstdc++.so.6"
      if [ -f "$LIB" ]; then
        mv -f "$LIB" "$LIB.bundled"
      fi

  - path: /etc/profile.d/dfremote.sh
    permissions: '0644'
    content: |
      # Prefer system libstdc++ over bundled for DFHack/DF Remote
      export DFHACK_NO_RENAME_LIBSTDCXX=1

  - path: /opt/dfremote/README-FIRST.txt
    permissions: '0644'
    content: |
      Welcome to DF Remote VM (no containers).
      Persistent data lives in: /srv/dfremote
      Place your server binary/scripts in: /opt/dfremote/bin
      Systemd service expects: /opt/dfremote/bin/dfremote-server

      Quick start once binary is in place:
        sudo systemctl daemon-reload
        sudo systemctl enable --now dfremote

      Logs:
        journalctl -u dfremote -f

      NOTE (Dwarf Fortress Remote):
        Use the all-in-one package (DF 0.47.05 + DFHack + Remote Server):
          http://mifki.com/df/update/dfremote-complete-4705-Linux.zip
        Download and extract to /opt/dfremote, ensure dfremote-server is executable.
        After extraction, run:
          sudo /usr/local/sbin/dfremote-fix-libs.sh
        This removes the bundled libstdc++.so.6 so the system lib is used.
        You can automate the copy/install/start steps from dfremote.ps1 by using:
          -InstallDfRemote -DfRemoteZipPath <local zip> -SshPrivateKeyPath <key> [-StartService]

  - path: /etc/systemd/system/dfremote.service
    permissions: '0644'
    content: |
      [Unit]
      Description=DF Remote Server (no container)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      User=root
      Environment=DATA_DIR=/srv/dfremote
      WorkingDirectory=/opt/dfremote
      ExecStart=/opt/dfremote/bin/dfremote-server --data-dir ${DATA_DIR} --port 1235 --host 0.0.0.0
      Restart=on-failure
      RestartSec=5s
      # Hardening (tune as needed)
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectSystem=full

      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/sbin/azure-disk-mount.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      DISK_DEV=""
      # Find the first data disk (LUN0) on Azure SCSI bus
      for d in /dev/disk/azure/scsi1/*; do
        if [ -e "$d" ]; then
          DISK_DEV=$(readlink -f "$d")
          break
        fi
      done

      if [ -z "$DISK_DEV" ]; then
        echo "No Azure data disk found under /dev/disk/azure/scsi1" >&2
        exit 0
      fi

      PART=${DISK_DEV}1
      if [ ! -b "$PART" ]; then
        # Partition blank disks and wait for the kernel to surface the new partition node.
        parted -s "$DISK_DEV" mklabel gpt
        parted -s "$DISK_DEV" mkpart primary ext4 0% 100%
        partprobe "$DISK_DEV"
        udevadm settle || true
        for _ in $(seq 1 10); do
          if [ -b "$PART" ]; then
            break
          fi
          sleep 1
        done
      fi

      if [ ! -b "$PART" ]; then
        echo "Partition $PART did not appear after partitioning $DISK_DEV" >&2
        exit 1
      fi

      if ! lsblk -no FSTYPE "$PART" | grep -q .; then
        mkfs.ext4 -F "$PART"
      fi

      mkdir -p /srv/dfremote
      # Get UUID and mount persistently
      UUID=$(blkid -s UUID -o value "$PART")
      grep -q "$UUID" /etc/fstab || echo "UUID=$UUID  /srv/dfremote  ext4  defaults,nofail  0  2" >> /etc/fstab
      mount -a
      chown -R root:root /srv/dfremote
      chmod 0777 /srv/dfremote

runcmd:
  - mkdir -p /opt/dfremote/bin
  - chmod 0755 /opt/dfremote /opt/dfremote/bin
  - bash /usr/local/sbin/dfremote-fix-libs.sh
  - ufw allow 22/tcp
  - ufw allow 1235/udp
  - yes | ufw enable
  - bash /usr/local/sbin/azure-disk-mount.sh
  - systemctl daemon-reload
  # service is disabled until you place a real binary at /opt/dfremote/bin/dfremote-server
  # enable it later with: systemctl enable --now dfremote
'@
$cloudInit = $cloudInit.Replace('__ADMIN_USERNAME__', $AdminUsername)

# ---------- VM Image ----------
$ubuntuImage = @{
  PublisherName = "Canonical"
  Offer         = "0001-com-ubuntu-server-jammy"
  Skus          = "22_04-lts-gen2"
  Version       = "latest"
}

# ---------- Existing VM Handling ----------
$existingVm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
$vmCreated = $false

if ($existingVm) {
  $attachedDataDisk = $existingVm.StorageProfile.DataDisks | Where-Object {
    $_.Name -eq $DataDiskName -or ($_.ManagedDisk -and $_.ManagedDisk.Id -eq $dataDisk.Id)
  }
  if (-not $attachedDataDisk) {
    throw "VM $VmName already exists, but data disk $DataDiskName is not attached. Attach and mount it manually or deploy a different VM name."
  }
  Write-Host "VM $VmName already exists in resource group $ResourceGroupName; skipping VM creation." -ForegroundColor Yellow
  Write-Host "Cloud-init only runs on first boot, so existing VM configuration is left in place." -ForegroundColor Yellow
} else {
  # ---------- VM Config ----------
  $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize |
    Set-AzVMOperatingSystem -Linux -ComputerName $VmName -Credential $adminCredential -DisablePasswordAuthentication:$false |
    Set-AzVMSourceImage @ubuntuImage |
    Add-AzVMNetworkInterface -Id $nic.Id

  if ($sshPublicKeys.Count -gt 0) {
    foreach ($key in $sshPublicKeys) {
      $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $key -Path "/home/$AdminUsername/.ssh/authorized_keys"
    }
  }

  # Attach data disk at creation (LUN0) so cloud-init can format/mount it on first boot
  $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $DataDiskName -Lun 0 -CreateOption Attach -ManagedDiskId $dataDisk.Id

  # Add cloud-init (custom data)
  $vmConfig.OSProfile.CustomData = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cloudInit))

  # OS Disk (managed)
  $vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage -StorageAccountType "Premium_LRS"

  # ---------- Create VM ----------
  $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig
  $vmCreated = $true
}

# ---------- Output ----------
$vmForOutput = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
$pubIp = $null
$primaryNicId = $vmForOutput.NetworkProfile.NetworkInterfaces[0].Id
if ($primaryNicId) {
  $primaryNicName = Split-Path -Path $primaryNicId -Leaf
  $primaryNic = Get-AzNetworkInterface -Name $primaryNicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
  if ($primaryNic -and $primaryNic.IpConfigurations.Count -gt 0) {
    $publicIpId = $primaryNic.IpConfigurations[0].PublicIpAddress.Id
    if ($publicIpId) {
      $resolvedPublicIpName = Split-Path -Path $publicIpId -Leaf
      $pubIp = (Get-AzPublicIpAddress -Name $resolvedPublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue).IpAddress
    }
  }
}
if (-not $pubIp) {
  $pubIp = (Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue).IpAddress
}

if (($InstallDfRemote -or $StartService) -and -not $pubIp) {
  throw "Could not determine the VM public IP address needed for SSH-based post-provisioning steps."
}

if ($InstallDfRemote -or $StartService) {
  Invoke-DfRemotePostProvisioning `
    -HostName $pubIp `
    -UserName $AdminUsername `
    -PrivateKeyPath $SshPrivateKeyPath `
    -Port $SshPort `
    -ReadyTimeoutSeconds $SshReadyTimeoutSeconds `
    -InstallPackage:$InstallDfRemote `
    -LocalZipPath $DfRemoteZipPath `
    -ZipUri $DfRemoteZipUri `
    -ZipSha256 $DfRemoteZipSha256 `
    -AllowInsecureDownload:$AllowInsecureDfRemoteDownload `
    -StartDfRemoteService:$StartService
}

Write-Host ""
Write-Host "==================== DEPLOYMENT COMPLETE ====================" -ForegroundColor Green
Write-Host "VM Action:   $(if ($vmCreated) { 'Created' } else { 'Reused existing VM' })"
Write-Host "SSH:        ssh $AdminUsername@$pubIp"
Write-Host "UDP Port:   1235 (opened in NSG + UFW)"
Write-Host "Data dir:   /srv/dfremote (on attached disk, persistent)"
if ($InstallDfRemote) {
  Write-Host "Binary dir: /opt/dfremote/bin (DF Remote package installed)"
} else {
  Write-Host "Binary dir: /opt/dfremote/bin (put 'dfremote-server' here, chmod +x)"
}
if ($StartService) {
  Write-Host "Service:    dfremote was enabled and started over SSH"
} else {
  Write-Host "Service:    sudo systemctl enable --now dfremote"
}
if ($sshPublicKeys.Count -gt 0) {
  Write-Host "SSH Keys:   Added $($sshPublicKeys.Count) key(s) to /home/$AdminUsername/.ssh/authorized_keys"
}
Write-Host "IP Address: $pubIp"
Write-Host "============================================================="
