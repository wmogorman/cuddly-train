# =========================
# DF Remote on Azure (VM)
# =========================
# Prereqs: Az PowerShell modules installed; you're logged in: Connect-AzAccount
# Recommended: SSH key pair ready (use ssh-keygen if needed)

# --------- EDIT ME ----------
$SubscriptionId   = "41f7fcbd-3674-4137-abc8-55d963ac109d"
$Rg               = "rg-dfremote"
$Location         = "eastus"
$VmName           = "dfremote-vm"
$DnsLabel         = "dfremote-$(Get-Random)"   # or set your own lowercase unique label
$VmSize           = "Standard_B2s"
$OsDiskSizeGB     = 64
$DataDiskSizeGB   = 64
$AdminUsername    = "azureuser"
$SshPublicKeyPath = "$HOME\.ssh\id_rsa.pub"     # path to your public key
# Allow only these IPs/CIDRs (add your home/work IPs). Use "x.x.x.x/32" for single IPs.
$AllowedCidrs     = @("64.183.220.138/32")  # <-- CHANGE THIS
# ----------------------------

Select-AzSubscription -SubscriptionId $SubscriptionId

# 0) Read SSH public key
$SshKey = Get-Content -LiteralPath $SshPublicKeyPath -Raw

# 1) Resource group
$rgObj = Get-AzResourceGroup -Name $Rg -ErrorAction SilentlyContinue
if (-not $rgObj) { $rgObj = New-AzResourceGroup -Name $Rg -Location $Location }

# 2) Networking: vnet, subnet, NSG with tight rules, public IP (static with DNS label)
$vnetName  = "$VmName-vnet"
$subnetName= "subnet1"
$nsgName   = "$VmName-nsg"
$nicName   = "$VmName-nic"
$pipName   = "$VmName-pip"

# Public IP
$pubIp = New-AzPublicIpAddress -Name $pipName -ResourceGroupName $Rg -Location $Location `
  -AllocationMethod Static -Sku Standard -DomainNameLabel $DnsLabel

# NSG
$nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $Rg -Location $Location

# Inbound: SSH 22 from your IPs
$prio = 1000
foreach ($cidr in $AllowedCidrs) {
  $ruleName = "allow-ssh-from-" + ($cidr -replace '[^a-zA-Z0-9]','-')
  $nsg | Add-AzNetworkSecurityRuleConfig -Name $ruleName `
    -Access Allow -Protocol Tcp -Direction Inbound -Priority $prio `
    -SourceAddressPrefix $cidr -SourcePortRange * -DestinationAddressPrefix * `
    -DestinationPortRange 22 | Out-Null
  $prio++
}

# Inbound: DF Remote UDP 1235 from your IPs
foreach ($cidr in $AllowedCidrs) {
  $ruleName = "allow-dfremote-udp1235-from-" + ($cidr -replace '[^a-zA-Z0-9]','-')
  $nsg | Add-AzNetworkSecurityRuleConfig -Name $ruleName `
    -Access Allow -Protocol Udp -Direction Inbound -Priority $prio `
    -SourceAddressPrefix $cidr -SourcePortRange * -DestinationAddressPrefix * `
    -DestinationPortRange 1235 | Out-Null
  $prio++
}

# (Optional) Deny-all-low priority is implicit; no need to add extra rule
$nsg = $nsg | Set-AzNetworkSecurityGroup

# VNet/Subnet
$subnetCfg = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.10.0.0/24" -NetworkSecurityGroup $nsg
$vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $Rg -Location $Location `
  -AddressPrefix "10.10.0.0/16" -Subnet $subnetCfg

  Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- REQUIRED VARIABLES (edit as needed) ----
$SubscriptionId = "<your-subscription-guid>"
$Rg            = "rg-dfremote"
$Location      = "southcentralus"
$VnetName      = "vnet-dfremote"
$SubnetName    = "subnet-dfremote"
$NsgName       = "nsg-dfremote"
$PipName       = "pip-dfremote"
$NicName       = "nic-dfremote"
$VmName        = "dfremote-vm"
# --------------------------------------------

# 1) RG
$rgObj = Get-AzResourceGroup -Name $Rg -ErrorAction SilentlyContinue
if (-not $rgObj) { $rgObj = New-AzResourceGroup -Name $Rg -Location $Location }

# 2) VNet + Subnet
$vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $vnet) {
  $vnet = New-AzVirtualNetwork -Name $VnetName -ResourceGroupName $Rg -Location $Location -AddressPrefix "10.20.0.0/16"
  Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix "10.20.1.0/24" -VirtualNetwork $vnet | Out-Null
  $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
}
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
if (-not $subnet) { throw "Subnet '$SubnetName' not found in VNet '$VnetName'." }

# 3) NSG + UDP 1235
$nsg = Get-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $nsg) {
  $nsg = New-AzNetworkSecurityGroup -Name $NsgName -ResourceGroupName $Rg -Location $Location
  $rule = New-AzNetworkSecurityRuleConfig -Name "Allow-DFRemote-UDP-1235" -Access Allow -Protocol Udp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 1235
  $nsg.SecurityRules.Add($rule)
  $nsg | Set-AzNetworkSecurityGroup | Out-Null
}
# Associate NSG to subnet (safer than per-NIC)
if (-not $subnet.NetworkSecurityGroup -or $subnet.NetworkSecurityGroup.Id -ne $nsg.Id) {
  $vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $Rg
  Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $subnet.AddressPrefix -NetworkSecurityGroup $nsg | Out-Null
  $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
  $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
}

# 4) Public IP
$pip = Get-AzPublicIpAddress -Name $PipName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $pip) {
  $pip = New-AzPublicIpAddress -Name $PipName -ResourceGroupName $Rg -Location $Location -AllocationMethod Static -Sku Standard
}

# 5) NIC (with explicit IDs to avoid nulls)
$nic = Get-AzNetworkInterface -Name $NicName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $nic) {
  $nic = New-AzNetworkInterface -Name $NicName -ResourceGroupName $Rg -Location $Location `
         -SubnetId $subnet.Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id
}
if (-not $nic -or -not $nic.Id) { throw "NIC creation failed; check subnet/pip/nsg IDs." }

# 6) VM config (Ubuntu LTS Gen2; good base for Docker)
$cred = Get-Credential -Message "Enter local admin for the VM (Linux user)"
$vmConfig = New-AzVMConfig -VMName $VmName -VMSize "Standard_B2s" |
            Set-AzVMOperatingSystem -Linux -ComputerName $VmName -Credential $cred |
            Set-AzVMSourceImage -PublisherName "Canonical" -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest" |
            Add-AzVMNetworkInterface -Id $nic.Id

# Optional: data disk for persistence (attach later inside the OS to /var/dfremote)
$diskName = "$VmName-data"
$disk = Get-AzDisk -DiskName $diskName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $disk) {
  $diskConfig = New-AzDiskConfig -Location $Location -CreateOption Empty -DiskSizeGB 16 -SkuName StandardSSD_LRS
  $disk = New-AzDisk -ResourceGroupName $Rg -DiskName $diskName -Disk $diskConfig
}
$vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $disk.Name -ManagedDiskId $disk.Id -Lun 0 -CreateOption Attach

# 7) Create the VM (zones/availability can be added if desired)
New-AzVM -ResourceGroupName $Rg -Location $Location -VM $vmConfig


# NIC
$nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $Rg -Location $Location `
  -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pubIp.Id

# 3) Cloud-init to:
# - Partition/format/mount the data disk at /srv/dfremote
# - Install Docker
# - Add azureuser to docker group
# - Create a systemd service for DF Remote container with persistent save mount
$cloudInit = @'
#cloud-config
package_update: true
packages:
  - docker.io
users:
  - name: {ADMINUSER}
    groups: [ docker ]
disk_setup:
  /dev/disk/azure/scsi1/lun0:
    table_type: gpt
    layout: true
    overwrite: false
fs_setup:
  - label: dfremote
    filesystem: ext4
    device: /dev/disk/azure/scsi1/lun0
    overwrite: false
mounts:
  - [ /dev/disk/azure/scsi1/lun0, /srv/dfremote, "ext4", "defaults,nofail", "0", "2" ]
write_files:
  - path: /etc/systemd/system/dfremote.service
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      Description=DF Remote (Docker)
      After=network-online.target docker.service
      Wants=network-online.target

      [Service]
      Type=simple
      ExecStartPre=/usr/bin/mkdir -p /srv/dfremote/save
      ExecStart=/usr/bin/docker run --rm --name dfremote -p 1235:1235/udp -v /srv/dfremote/save:/df/data/save mifki/dfremote
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl daemon-reload
  - systemctl enable docker
  - systemctl start docker
  - systemctl enable dfremote
  - systemctl start dfremote
'@

$cloudInit = $cloudInit.Replace("{ADMINUSER}", $AdminUsername)

# 4) VM config + data disk
$cred = New-Object System.Management.Automation.PSCredential ($AdminUsername,(ConvertTo-SecureString "unused" -AsPlainText -Force))
$vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize |
  Set-AzVMOperatingSystem -Linux -ComputerName $VmName -Credential $cred -DisablePasswordAuthentication |
  Set-AzVMSourceImage -PublisherName Canonical -Offer 0001-com-ubuntu-server-jammy -Skus 22_04-lts-gen2 -Version latest |
  Add-AzVMNetworkInterface -Id $nic.Id |
  Set-AzVMOSDisk -Name "$VmName-osdisk" -DiskSizeInGB $OsDiskSizeGB -CreateOption FromImage

# Data disk (LUN 0)
$dataDiskCfg = New-AzDiskConfig -Location $Location -CreateOption Empty -DiskSizeGB $DataDiskSizeGB -SkuName "StandardSSD_LRS"
$dataDisk    = New-AzDisk -DiskName "$VmName-data" -Disk $dataDiskCfg -ResourceGroupName $Rg
$vmConfig    = Add-AzVMDataDisk -VM $vmConfig -Name "$VmName-data" -CreateOption Attach -ManagedDiskId $dataDisk.Id -Lun 0 -Caching ReadWrite

# 5) Create the VM with cloud-init
New-AzVM -ResourceGroupName $Rg -Location $Location -VM $vmConfig `
  -PublicIpAddressName $pipName -VirtualNetworkName $vnetName -SubnetName $subnetName `
  -SecurityGroupName $nsgName -OpenPorts 22 `
  -SshKeyName "$VmName-ssh" -SshKeyValue $SshKey `
  -CustomData $cloudInit | Out-Null

# 6) (Optional) Auto-shutdown at 1:00 AM Central using Azure CLI fallback (works across SKUs)
try {
  # If you have Azure CLI, this will set it; otherwise you can skip or set in Portal
  az vm auto-shutdown -g $Rg -n $VmName --time 0100 --email "" | Out-Null
} catch { Write-Host "Auto-shutdown via az CLI not set (CLI missing?). You can set it in the Portal (Operations -> Auto-shutdown)." -ForegroundColor Yellow }

# 7) Output connection details
$pub = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $Rg
"DF Remote public DNS: $($pub.DnsSettings.Fqdn)"
"DF Remote public IP:  $($pub.IpAddress)"
"UDP Port:             1235 (allowed only from: $($AllowedCidrs -join ', '))"
"SSH:                  ssh $AdminUsername@$($pub.DnsSettings.Fqdn)"
