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
  - `-AdminPassword` is only needed when the script might have to create a VM.
    SSH-only reruns such as install, update, start, and QR operations do not
    need the password file.
  - Optional install automation is available with `-InstallDfRemote`. Supply a
    workstation-local zip via `-DfRemoteZipPath` or a verified download URI via
    `-DfRemoteZipUri`, plus `-SshPrivateKeyPath` so the script can copy files
    and run remote install commands over SSH.
  - `-UpdateDfRemoteServer` downloads the upstream server update delta over SSH,
    backs up the current `remote.plug.so` and `hack/lua/remote`, installs the
    new files, and restarts the service.
  - `-StartService` can be used alongside `-InstallDfRemote`, or by itself to
    enable and start an already-installed `dfremote` service over SSH.
  - `-ShowRemoteQr` can be used after the service is running to execute
    `./dfhack-run remote connect` over SSH and print the QR code in your local
    terminal.
  - If the VM already exists and you only want the SSH-based install/start
    steps, use `-SkipAzureProvisioning -VmHost <ip-or-hostname>` to bypass the
    Az PowerShell dependency entirely.

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

.PARAMETER UpdateDfRemoteServer
Download and apply the upstream DF Remote server update over SSH by replacing
`hack/plugins/remote.plug.so` and `hack/lua/remote`, then restarting the
service.

.PARAMETER DfRemoteUpdateUri
URI for the DF Remote server update archive. Defaults to mifki's `latest`
delta feed, which currently uses HTTP.

.PARAMETER SshPrivateKeyPath
Path to the SSH private key that matches a public key already authorized for the
VM admin user. Required for SSH-based install, update, start, and QR actions.

.PARAMETER SshPort
SSH port used for post-provisioning install and service actions.

.PARAMETER SshReadyTimeoutSeconds
How long to wait for SSH to become reachable before install/start steps fail.

.PARAMETER AllowInsecureDfRemoteDownload
Allow a non-HTTPS `-DfRemoteZipUri`. Intended only for trusted internal mirrors.

.PARAMETER SkipAzureProvisioning
Skip all Azure resource discovery and provisioning steps. Use this for
install/start-only runs against an already reachable VM.

.PARAMETER VmHost
SSH hostname or IP address to use for install/start-only runs when Azure
resource lookup is skipped.

.PARAMETER ShowRemoteQr
After the SSH-based start/install flow completes, run `./dfhack-run remote
connect` on the VM and display the resulting QR code in the local terminal.

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

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -SkipAzureProvisioning -VmHost '20.120.109.152' -InstallDfRemote -DfRemoteZipPath 'C:\Installers\dfremote-complete-4705-Linux.zip' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -StartService

Skips all Azure cmdlets and performs only the SSH-based install/start work
against the existing VM at the supplied host or IP.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -SkipAzureProvisioning -VmHost '20.120.109.152' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -ShowRemoteQr

Runs `./dfhack-run remote connect` over SSH and prints the QR code for the
already-running DF Remote service.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -SkipAzureProvisioning -VmHost '20.120.109.152' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -UpdateDfRemoteServer

Downloads the upstream DF Remote server update archive on the VM, backs up the
current plugin and Lua files, installs the updated files, and restarts the
service.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -SkipAzureProvisioning -VmHost '20.120.109.152' -InstallDfRemote -DfRemoteZipPath 'C:\Installers\dfremote-complete-4705-Linux.zip' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -StartService -ShowRemoteQr

Installs the classic DF Remote bundle, starts the service, and then runs
`./dfhack-run remote connect` so the QR code is printed as part of the same
automation flow.

.EXAMPLE
PS> .\dfremote-azure\dfremote.ps1 -SubscriptionId '<subscription-guid>' -ResourceGroupName 'dfremote-rg' -Location 'eastus' -VmName 'dfremote-vm' -AdminUsername 'william' -SkipAzureProvisioning -VmHost '20.120.109.152' -SshPrivateKeyPath "$HOME\.ssh\id_rsa" -UpdateDfRemoteServer -ShowRemoteQr

Updates the running DF Remote server over SSH and then prints a fresh QR code in
the local terminal.

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
  [switch] $UpdateDfRemoteServer,
  [string] $DfRemoteUpdateUri = 'http://mifki.com/df/update/dfremote-latest.zip',
  [string] $SshPrivateKeyPath,
  [int] $SshPort = 22,
  [int] $SshReadyTimeoutSeconds = 180,
  [switch] $StartService,
  [switch] $AllowInsecureDfRemoteDownload,
  [switch] $SkipAzureProvisioning,
  [string] $VmHost,
  [switch] $ShowRemoteQr
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
    [int] $Port = 22,
    [switch] $AllocateTty
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
  if ($AllocateTty) {
    $arguments = @(
      '-i', $PrivateKeyPath,
      '-p', [string]$Port,
      '-tt',
      '-o', 'BatchMode=yes',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'ConnectTimeout=15',
      "${UserName}@${HostName}",
      $CommandText
    )
  }
  Invoke-ExternalCommand -FilePath $sshPath -Arguments $arguments -FailureMessage "SSH command on $HostName failed"
}

function Invoke-RemoteScriptOnVm {
  param(
    [Parameter(Mandatory=$true)] [string] $ScriptText,
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $UserName,
    [Parameter(Mandatory=$true)] [string] $PrivateKeyPath,
    [int] $Port = 22,
    [switch] $AllocateTty,
    [string] $RemoteScriptPrefix = 'dfremote-remote'
  )

  $runId = [Guid]::NewGuid().ToString('N')
  $remoteScriptPath = "/tmp/$RemoteScriptPrefix-$runId.sh"
  $localScriptPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$RemoteScriptPrefix-$runId.sh"

  try {
    [System.IO.File]::WriteAllText($localScriptPath, ($ScriptText -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    Copy-FileToVmOverScp -LocalPath $localScriptPath -RemotePath $remoteScriptPath -HostName $HostName -UserName $UserName -PrivateKeyPath $PrivateKeyPath -Port $Port

    $quotedRemoteScriptPath = ConvertTo-BashSingleQuotedString -Value $remoteScriptPath
    $remoteCommand = "bash $quotedRemoteScriptPath; status=`$?; rm -f $quotedRemoteScriptPath; exit `$status"
    Invoke-SshCommandOnVm -CommandText $remoteCommand -HostName $HostName -UserName $UserName -PrivateKeyPath $PrivateKeyPath -Port $Port -AllocateTty:$AllocateTty
  } finally {
    Remove-Item -Path $localScriptPath -Force -ErrorAction SilentlyContinue
  }
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
  if [ -f "$INSTALL_ROOT/bin/dfremote-server" ]; then
    sudo chmod 0755 "$INSTALL_ROOT/bin/dfremote-server"
  elif [ -f "$INSTALL_ROOT/dfhack" ]; then
    sudo chmod 0755 "$INSTALL_ROOT/dfhack"
    [ ! -f "$INSTALL_ROOT/df" ] || sudo chmod 0755 "$INSTALL_ROOT/df"
    [ ! -f "$INSTALL_ROOT/dfhack-run" ] || sudo chmod 0755 "$INSTALL_ROOT/dfhack-run"
    if [ -f "$INSTALL_ROOT/dfhack-config/init/default.dfhack.init" ] && ! grep -qx 'remote connect' "$INSTALL_ROOT/dfhack-config/init/default.dfhack.init"; then
      echo 'remote connect' | sudo tee -a "$INSTALL_ROOT/dfhack-config/init/default.dfhack.init" >/dev/null
    fi
  else
    echo "No supported DF Remote entrypoint found after unzip. Expected $INSTALL_ROOT/bin/dfremote-server or $INSTALL_ROOT/dfhack." >&2
    exit 1
  fi
fi

sudo tee /usr/local/sbin/dfremote-launch.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_ROOT='/opt/dfremote'
DATA_DIR='/srv/dfremote'
TERM="${TERM:-xterm}"
export TERM

mkdir -p "$DATA_DIR"

if [ -x "$INSTALL_ROOT/bin/dfremote-server" ]; then
  exec "$INSTALL_ROOT/bin/dfremote-server" --data-dir "$DATA_DIR" --port 1235 --host 0.0.0.0
fi

if [ -x "$INSTALL_ROOT/dfhack" ]; then
  INIT_FILE="$INSTALL_ROOT/data/init/init.txt"
  SAVE_ROOT="$DATA_DIR/save"
  mkdir -p "$SAVE_ROOT"
  if [ -f "$INIT_FILE" ]; then
    sed -i 's/^\[PRINT_MODE:.*\]/[PRINT_MODE:TEXT]/' "$INIT_FILE"
  fi
  if [ -e "$INSTALL_ROOT/data/save" ] && [ ! -L "$INSTALL_ROOT/data/save" ]; then
    if [ -d "$INSTALL_ROOT/data/save" ]; then
      cp -a "$INSTALL_ROOT/data/save/." "$SAVE_ROOT/" 2>/dev/null || true
      rm -rf "$INSTALL_ROOT/data/save"
    else
      rm -f "$INSTALL_ROOT/data/save"
    fi
  fi
  ln -sfn "$SAVE_ROOT" "$INSTALL_ROOT/data/save"
  exec "$INSTALL_ROOT/dfhack"
fi

echo "No supported DF Remote entrypoint found under $INSTALL_ROOT" >&2
exit 1
EOF
sudo chmod 0755 /usr/local/sbin/dfremote-launch.sh

sudo tee /etc/systemd/system/dfremote.service >/dev/null <<'EOF'
[Unit]
Description=DF Remote Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=DATA_DIR=/srv/dfremote
Environment=TERM=xterm
WorkingDirectory=/opt/dfremote
ExecStart=/usr/local/sbin/dfremote-launch.sh
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

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
    Invoke-RemoteScriptOnVm `
      -ScriptText $remoteScript `
      -HostName $HostName `
      -UserName $UserName `
      -PrivateKeyPath $PrivateKeyPath `
      -Port $Port `
      -RemoteScriptPrefix 'dfremote-postprovision'
  } finally {
  }
}

function Invoke-DfRemoteServerUpdate {
  param(
    [Parameter(Mandatory=$true)] [string] $HostName,
    [Parameter(Mandatory=$true)] [string] $UserName,
    [Parameter(Mandatory=$true)] [string] $PrivateKeyPath,
    [Parameter(Mandatory=$true)] [string] $UpdateUri,
    [int] $Port = 22,
    [int] $ReadyTimeoutSeconds = 180
  )

  Write-Host "Updating DF Remote server files on $HostName..." -ForegroundColor Cyan
  Wait-ForTcpPort -HostName $HostName -Port $Port -TimeoutSeconds $ReadyTimeoutSeconds

  $remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

UPDATE_URI=__UPDATE_URI__
INSTALL_ROOT='/opt/dfremote'
TMP_ROOT=$(mktemp -d /tmp/dfremote-update.XXXXXX)
ZIP_PATH="$TMP_ROOT/dfremote-latest.zip"
EXTRACT_ROOT="$TMP_ROOT/extract"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || { echo 'curl is required but not installed.' >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo 'unzip is required but not installed.' >&2; exit 1; }

mkdir -p "$EXTRACT_ROOT"
curl -fsSL "$UPDATE_URI" -o "$ZIP_PATH"
unzip -o "$ZIP_PATH" -d "$EXTRACT_ROOT" >/dev/null

PLUGIN_SRC=$(find "$EXTRACT_ROOT" -path '*/linux/remote.plug.so' -type f | head -n 1)
LUA_SRC="$EXTRACT_ROOT/remote"
PLUGIN_DST="$INSTALL_ROOT/hack/plugins/remote.plug.so"
LUA_DST="$INSTALL_ROOT/hack/lua/remote"

[ -n "$PLUGIN_SRC" ] || { echo "Could not locate linux/remote.plug.so in update archive." >&2; exit 1; }
[ -d "$LUA_SRC" ] || { echo "Could not locate remote Lua directory in update archive." >&2; exit 1; }
[ -f "$PLUGIN_DST" ] || { echo "Existing plugin not found at $PLUGIN_DST" >&2; exit 1; }
[ -d "$LUA_DST" ] || { echo "Existing Lua directory not found at $LUA_DST" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ROOT="$INSTALL_ROOT/update-backups/$STAMP"
sudo mkdir -p "$BACKUP_ROOT"
sudo cp "$PLUGIN_DST" "$BACKUP_ROOT/remote.plug.so"
sudo cp -a "$LUA_DST" "$BACKUP_ROOT/remote"

sudo systemctl stop dfremote || true
sudo install -m 0755 "$PLUGIN_SRC" "$PLUGIN_DST"
sudo rm -rf "$LUA_DST"
sudo cp -a "$LUA_SRC" "$LUA_DST"
sudo chown -R root:root "$LUA_DST"
sudo systemctl start dfremote
sudo systemctl --no-pager --full status dfremote
echo "Backup saved to $BACKUP_ROOT"
'@

  $remoteScript = $remoteScript.Replace('__UPDATE_URI__', (ConvertTo-BashSingleQuotedString -Value $UpdateUri))
  Invoke-RemoteScriptOnVm `
    -ScriptText $remoteScript `
    -HostName $HostName `
    -UserName $UserName `
    -PrivateKeyPath $PrivateKeyPath `
    -Port $Port `
    -RemoteScriptPrefix 'dfremote-update'
}

function Import-AzModulesIfAvailable {
  $modules = @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute')
  foreach ($moduleName in $modules) {
    if (Get-Module -Name $moduleName) {
      continue
    }
    if (Get-Module -ListAvailable -Name $moduleName) {
      Import-Module $moduleName -ErrorAction SilentlyContinue | Out-Null
    }
  }
}

function Assert-AzCmdletsAvailable {
  $requiredCommands = @(
    'Select-AzSubscription',
    'Get-AzResourceGroup',
    'Get-AzVirtualNetwork',
    'Get-AzPublicIpAddress',
    'Get-AzNetworkInterface',
    'Get-AzDisk',
    'Get-AzVM'
  )
  $missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
  if ($missingCommands.Count -gt 0) {
    throw @"
Az PowerShell cmdlets are not available in this session.
Missing commands: $($missingCommands -join ', ')

Install or import the Az modules, then run:
  Install-Module Az -Scope CurrentUser
  Connect-AzAccount

If you only want to run SSH-based DF Remote actions on an existing VM, rerun with:
  -SkipAzureProvisioning -VmHost <ip-or-hostname>
"@
  }
}

function New-AdminCredential {
  param(
    [Parameter(Mandatory=$true)] [string] $AdminUsername,
    [SecureString] $AdminPassword,
    [Parameter(Mandatory=$true)] [string] $AdminPasswordFile
  )

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

  return New-Object -TypeName PSCredential -ArgumentList $AdminUsername, $AdminPassword
}

if ($InstallDfRemote -and [string]::IsNullOrWhiteSpace($DfRemoteZipPath) -and [string]::IsNullOrWhiteSpace($DfRemoteZipUri)) {
  throw "InstallDfRemote requires either -DfRemoteZipPath or -DfRemoteZipUri."
}

if ($InstallDfRemote -and $DfRemoteZipPath -and $DfRemoteZipUri) {
  throw "Specify only one of -DfRemoteZipPath or -DfRemoteZipUri."
}

if (($InstallDfRemote -or $UpdateDfRemoteServer -or $StartService) -and [string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
  throw "-SshPrivateKeyPath is required when using -InstallDfRemote, -UpdateDfRemoteServer, or -StartService."
}

if ($SkipAzureProvisioning -and [string]::IsNullOrWhiteSpace($VmHost)) {
  throw "-VmHost is required when using -SkipAzureProvisioning."
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

if ($DfRemoteUpdateUri -and -not $UpdateDfRemoteServer) {
  # Allow the default value to exist without forcing update mode.
  if ($DfRemoteUpdateUri -ne 'http://mifki.com/df/update/dfremote-latest.zip') {
    throw "-DfRemoteUpdateUri is only valid with -UpdateDfRemoteServer."
  }
}

if ($DfRemoteZipPath) {
  $DfRemoteZipPath = Resolve-ExistingPath -Path $DfRemoteZipPath -ParameterName 'DfRemoteZipPath'
}

if ($SshPrivateKeyPath) {
  $SshPrivateKeyPath = Resolve-ExistingPath -Path $SshPrivateKeyPath -ParameterName 'SshPrivateKeyPath'
}

# ---------- Admin Password ----------
$adminCredential = $null

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

$vmCreated = $false
$pubIp = $null

if ($SkipAzureProvisioning) {
  $pubIp = $VmHost
  Write-Host "Skipping Azure provisioning and resource lookup; using SSH target $pubIp." -ForegroundColor Yellow
} else {
  Import-AzModulesIfAvailable
  Assert-AzCmdletsAvailable

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

  - path: /usr/local/sbin/dfremote-launch.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      INSTALL_ROOT='/opt/dfremote'
      DATA_DIR='/srv/dfremote'
      TERM="${TERM:-xterm}"
      export TERM

      mkdir -p "$DATA_DIR"

      if [ -x "$INSTALL_ROOT/bin/dfremote-server" ]; then
        exec "$INSTALL_ROOT/bin/dfremote-server" --data-dir "$DATA_DIR" --port 1235 --host 0.0.0.0
      fi

      if [ -x "$INSTALL_ROOT/dfhack" ]; then
        INIT_FILE="$INSTALL_ROOT/data/init/init.txt"
        SAVE_ROOT="$DATA_DIR/save"
        mkdir -p "$SAVE_ROOT"
        if [ -f "$INIT_FILE" ]; then
          sed -i 's/^\[PRINT_MODE:.*\]/[PRINT_MODE:TEXT]/' "$INIT_FILE"
        fi
        if [ -e "$INSTALL_ROOT/data/save" ] && [ ! -L "$INSTALL_ROOT/data/save" ]; then
          if [ -d "$INSTALL_ROOT/data/save" ]; then
            cp -a "$INSTALL_ROOT/data/save/." "$SAVE_ROOT/" 2>/dev/null || true
            rm -rf "$INSTALL_ROOT/data/save"
          else
            rm -f "$INSTALL_ROOT/data/save"
          fi
        fi
        ln -sfn "$SAVE_ROOT" "$INSTALL_ROOT/data/save"
        exec "$INSTALL_ROOT/dfhack"
      fi

      echo "No supported DF Remote entrypoint found under $INSTALL_ROOT" >&2
      exit 1

  - path: /opt/dfremote/README-FIRST.txt
    permissions: '0644'
    content: |
      Welcome to DF Remote VM (no containers).
      Persistent data lives in: /srv/dfremote
      Install root lives in: /opt/dfremote
      Systemd launcher: /usr/local/sbin/dfremote-launch.sh
      Supported entrypoints:
        - /opt/dfremote/bin/dfremote-server
        - /opt/dfremote/dfhack

      Quick start once binary is in place:
        sudo systemctl daemon-reload
        sudo systemctl enable --now dfremote

      Logs:
        journalctl -u dfremote -f

      NOTE (Dwarf Fortress Remote):
        Use the all-in-one package (DF 0.47.05 + DFHack + Remote Server):
          http://mifki.com/df/update/dfremote-complete-4705-Linux.zip
        Download and extract to /opt/dfremote.
        After extraction, run:
          sudo /usr/local/sbin/dfremote-fix-libs.sh
        This removes the bundled libstdc++.so.6 so the system lib is used.
        The launcher will use /opt/dfremote/dfhack for the classic all-in-one package.
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
      Environment=TERM=xterm
      WorkingDirectory=/opt/dfremote
      ExecStart=/usr/local/sbin/dfremote-launch.sh
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
  # service is disabled until you place a supported DF Remote install under /opt/dfremote
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

if (-not $SkipAzureProvisioning) {
  # ---------- Existing VM Handling ----------
  $existingVm = Get-AzVM -Name $VmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

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
    $adminCredential = New-AdminCredential -AdminUsername $AdminUsername -AdminPassword $AdminPassword -AdminPasswordFile $AdminPasswordFile
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
}

if (($InstallDfRemote -or $UpdateDfRemoteServer -or $StartService) -and -not $pubIp) {
  throw "Could not determine the VM public IP address needed for SSH-based post-provisioning steps."
}

if ($ShowRemoteQr -and [string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
  throw "-SshPrivateKeyPath is required when using -ShowRemoteQr."
}

if ($ShowRemoteQr -and -not $pubIp) {
  throw "Could not determine the VM public IP address needed for -ShowRemoteQr."
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

if ($UpdateDfRemoteServer) {
  Invoke-DfRemoteServerUpdate `
    -HostName $pubIp `
    -UserName $AdminUsername `
    -PrivateKeyPath $SshPrivateKeyPath `
    -UpdateUri $DfRemoteUpdateUri `
    -Port $SshPort `
    -ReadyTimeoutSeconds $SshReadyTimeoutSeconds
}

if ($ShowRemoteQr) {
  Write-Host "Requesting DF Remote QR code from $pubIp..." -ForegroundColor Cyan
  $qrCommand = @'
#!/usr/bin/env bash
set -euo pipefail
for _ in $(seq 1 15); do
  if systemctl is-active --quiet dfremote; then
    break
  fi
  sleep 1
done
if ! systemctl is-active --quiet dfremote; then
  echo "dfremote service is not active; cannot run ./dfhack-run remote connect." >&2
  exit 1
fi
cd /opt/dfremote
if [ ! -x ./dfhack-run ]; then
  echo "/opt/dfremote/dfhack-run was not found or is not executable." >&2
  exit 1
fi
export TERM="${TERM:-xterm}"
exec ./dfhack-run remote connect
'@
  Invoke-RemoteScriptOnVm `
    -ScriptText $qrCommand `
    -HostName $pubIp `
    -UserName $AdminUsername `
    -PrivateKeyPath $SshPrivateKeyPath `
    -Port $SshPort `
    -AllocateTty `
    -RemoteScriptPrefix 'dfremote-show-qr'
}

Write-Host ""
Write-Host "==================== DEPLOYMENT COMPLETE ====================" -ForegroundColor Green
Write-Host "VM Action:   $(if ($SkipAzureProvisioning) { 'Skipped Azure provisioning' } elseif ($vmCreated) { 'Created' } else { 'Reused existing VM' })"
Write-Host "SSH:        ssh $AdminUsername@$pubIp"
Write-Host "UDP Port:   1235 (opened in NSG + UFW)"
Write-Host "Data dir:   /srv/dfremote (on attached disk, persistent)"
if ($InstallDfRemote) {
  Write-Host "Install dir: /opt/dfremote (DF Remote package installed)"
} else {
  Write-Host "Install dir: /opt/dfremote (launcher auto-detects dfremote-server or dfhack)"
}
if ($UpdateDfRemoteServer) {
  Write-Host "Update:     Applied DF Remote server delta from $DfRemoteUpdateUri"
}
if ($StartService) {
  Write-Host "Service:    dfremote was enabled and started over SSH"
} elseif ($UpdateDfRemoteServer) {
  Write-Host "Service:    dfremote was restarted after updating server files"
} else {
  Write-Host "Service:    sudo systemctl enable --now dfremote"
}
if ($sshPublicKeys.Count -gt 0) {
  Write-Host "SSH Keys:   Added $($sshPublicKeys.Count) key(s) to /home/$AdminUsername/.ssh/authorized_keys"
}
Write-Host "IP Address: $pubIp"
Write-Host "============================================================="
