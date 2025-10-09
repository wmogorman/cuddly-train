<# ======================================================================
DF Remote Server on Azure VM (Linux, no containers) + Attached Data Disk
Author: you + ChatGPT
Last updated: 2025-10-02
Prereqs:
  - Az PowerShell modules installed and logged in (Connect-AzAccount)
  - Admin password available as a SecureString parameter or stored in dfremote-password.txt (DPAPI-protected SecureString)
What it does:
  1) Creates/uses a Resource Group, VNet/Subnet, Public IP, NSG (UDP 1235 + SSH)
  2) Builds Ubuntu VM, injects cloud-init to prep /srv/dfremote and systemd unit
  3) Creates & attaches a managed data disk, formats & mounts it persistently
  4) Leaves a systemd service ready to run your DF Remote Server binary
====================================================================== #>

param(
  [Parameter(Mandatory=$true)] [string] $SubscriptionId,
  [Parameter(Mandatory=$true)] [string] $ResourceGroupName,
  [Parameter(Mandatory=$true)] [string] $Location,                  # e.g. "eastus"
  [Parameter(Mandatory=$true)] [string] $VmName,                    # e.g. "dfremote-vm"
  [Parameter(Mandatory=$true)] [string] $AdminUsername,             # e.g. "william"
  [SecureString] $AdminPassword,
  [string] $AdminPasswordFile = (Join-Path -Path $PSScriptRoot -ChildPath 'dfremote-password.txt'),
  [string] $VmSize = "Standard_B2s",                                # tweak as needed
  [int]    $DataDiskSizeGB = 64,                                    # persistence disk
  [string] $VNetName = "$($ResourceGroupName)-vnet",
  [string] $SubnetName = "default",
  [string] $AddressPrefix = "10.20.0.0/16",
  [string] $SubnetPrefix = "10.20.1.0/24",
  [string] $PublicIpName = "$($VmName)-pip",
  [string] $NicName = "$($VmName)-nic",
  [string] $NsgName = "$($VmName)-nsg",
  [string] $DataDiskName = "$($VmName)-data"
)

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

users:
  - name: __ADMIN_USERNAME__
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [ adm, sudo ]
    shell: /bin/bash

write_files:
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
        DF Remote plugin targets DF 0.47.05 + DFHack.
        Download DF 0.47.05 (Linux) from Bay12 older versions,
        add DFHack 0.47.05, then the DF Remote plugin files.
        See:
          - DF older versions (Linux tarball): https://www.bay12games.com/dwarves/older_versions.html
          - DFHack 0.47.05 docs: https://docs.dfhack.org/en/0.47.05-r8/docs/Installing.html
          - DF Remote server code: https://github.com/mifki/dfremote

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
      if ! lsblk -no FSTYPE "$DISK_DEV" | grep -q .; then
        # Partition & format if blank
        parted -s "$DISK_DEV" mklabel gpt
        parted -s "$DISK_DEV" mkpart primary ext4 0% 100%
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

# ---------- VM Config ----------
$vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize |
  Set-AzVMOperatingSystem -Linux -ComputerName $VmName -Credential $adminCredential -DisablePasswordAuthentication:$false |
  Set-AzVMSourceImage @ubuntuImage |
  Add-AzVMNetworkInterface -Id $nic.Id

# Add cloud-init (custom data)
$vmConfig.OSProfile.CustomData = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cloudInit))

# OS Disk (managed)
$vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage -StorageAccountType "Premium_LRS"

# ---------- Create VM ----------
$null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig

# ---------- Data Disk (managed) ----------
$diskConfig = New-AzDiskConfig -SkuName Premium_LRS -Location $Location -CreateOption Empty -DiskSizeGB $DataDiskSizeGB
$dataDisk = New-AzDisk -DiskName $DataDiskName -Disk $diskConfig -ResourceGroupName $ResourceGroupName

# Attach as LUN 0
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName
$vm = Add-AzVMDataDisk -VM $vm -Name $DataDiskName -CreateOption Attach -ManagedDiskId $dataDisk.Id -Lun 0
$null = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm

# ---------- Output ----------
$pubIp = (Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName).IpAddress
Write-Host ""
Write-Host "==================== DEPLOYMENT COMPLETE ====================" -ForegroundColor Green
Write-Host "SSH:        ssh $AdminUsername@$pubIp"
Write-Host "UDP Port:   1235 (opened in NSG + UFW)"
Write-Host "Data dir:   /srv/dfremote (on attached disk, persistent)"
Write-Host "Binary dir: /opt/dfremote/bin (put 'dfremote-server' here, chmod +x)"
Write-Host "Service:    sudo systemctl enable --now dfremote"
Write-Host "IP Address: $pubIp"
Write-Host "============================================================="
