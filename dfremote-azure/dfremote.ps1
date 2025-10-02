# =========================
# DF Remote on Azure (VM)
# =========================
# Prereqs: Az PowerShell modules installed; you're logged in: Connect-AzAccount
# Recommended: SSH key pair ready (use ssh-keygen if needed)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

function Get-OrCreateResource {
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$Get,
        [Parameter(Mandatory)]
        [ScriptBlock]$Create,
        [string]$Description = 'resource'
    )

    $resource = & $Get
    if ($resource) {
        Write-Host "Using existing $Description." -ForegroundColor Yellow
        return $resource
    }

    try {
        $resource = & $Create
        Write-Host "Created $Description." -ForegroundColor Cyan
        return $resource
    } catch {
        Write-Host "Creation skipped for $Description; attempting to reuse existing instance." -ForegroundColor Yellow
        $resource = & $Get
        if ($resource) {
            return $resource
        }
        throw
    }
}

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
$SshPublicKeyPath = [System.IO.Path]::Combine($HOME, ".ssh", "id_rsa.pub")     # path to your public key
# Allow only these IPs/CIDRs (add your home/work IPs). Use "x.x.x.x/32" for single IPs.
$AllowedCidrs     = @("64.183.220.138/32")  # <-- CHANGE THIS
# ----------------------------

$vnetName   = "$VmName-vnet"
$subnetName = "subnet1"
$nsgName    = "$VmName-nsg"
$nicName    = "$VmName-nic"
$pipName    = "$VmName-pip"
$diskName   = "$VmName-data"

Select-AzSubscription -SubscriptionId $SubscriptionId

# 0) Read SSH public key
if ($SshPublicKeyPath -like "~*") {
    $relativeSshKey = $SshPublicKeyPath.Substring(1).TrimStart('/','\')
    $relativeSshKey = $relativeSshKey -replace '[\\/]', [string][System.IO.Path]::DirectorySeparatorChar
    $SshPublicKeyPath = [System.IO.Path]::Combine($HOME, $relativeSshKey)
}
if (-not $onWindows -and $SshPublicKeyPath -like "*\*") {
    $normalizedCandidate = $SshPublicKeyPath -replace "\\", "/"
    if (Test-Path -LiteralPath $normalizedCandidate) {
        $SshPublicKeyPath = $normalizedCandidate
    }
}

$SshKey = $null
if (Test-Path -LiteralPath $SshPublicKeyPath) {
    $SshKey = Get-Content -LiteralPath $SshPublicKeyPath -Raw
}

if (-not $SshKey) {
    Write-Host "SSH public key not found at '$SshPublicKeyPath'. Generating a new SSH key pair." -ForegroundColor Yellow
    $sshDir = Split-Path -Path $SshPublicKeyPath -Parent
    if ($sshDir -and -not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    $privateKeyPath = if ($SshPublicKeyPath.EndsWith('.pub')) {
        $SshPublicKeyPath.Substring(0, $SshPublicKeyPath.Length - 4)
    } else {
        "$SshPublicKeyPath.key"
    }

    $sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    if (-not $sshKeygen) {
        throw "SSH public key not found at '$SshPublicKeyPath', and ssh-keygen is unavailable to create one automatically."
    }

    $privateKeyExists = Test-Path -LiteralPath $privateKeyPath
    if ($privateKeyExists) {
        $publicKey = & $sshKeygen.Definition -y -f $privateKeyPath
        if (-not $publicKey) {
            throw "Failed to derive public key from existing private key at '$privateKeyPath'."
        }
        Set-Content -Path $SshPublicKeyPath -Value $publicKey
    } else {
        & $sshKeygen.Definition -t rsa -b 4096 -f $privateKeyPath -N '' | Out-Null
    }

    if (-not (Test-Path -LiteralPath $SshPublicKeyPath)) {
        throw "Automatic SSH key generation failed; expected public key at '$SshPublicKeyPath'."
    }

    $SshKey = Get-Content -LiteralPath $SshPublicKeyPath -Raw
}

if ($SshKey) {
    $SshKey = $SshKey.Trim()

}
# 1) Resource group
$null = Get-OrCreateResource -Description "resource group '$Rg'" `
    -Get    { Get-AzResourceGroup -Name $Rg -ErrorAction SilentlyContinue } `
    -Create { New-AzResourceGroup -Name $Rg -Location $Location -ErrorAction Stop }

# 2) Network security group with rules
$nsg = Get-OrCreateResource -Description "network security group '$nsgName'" `
    -Get    { Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $Rg -ErrorAction SilentlyContinue } `
    -Create { New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $Rg -Location $Location -ErrorAction Stop }

$rulesChanged = $false
$priority = 1000
foreach ($cidr in $AllowedCidrs) {
    $ruleName = "allow-ssh-from-" + ($cidr -replace '[^a-zA-Z0-9]','-')
    if (-not ($nsg.SecurityRules | Where-Object { $_.Name -eq $ruleName })) {
        $nsg = $nsg | Add-AzNetworkSecurityRuleConfig -Name $ruleName `
            -Access Allow -Protocol Tcp -Direction Inbound -Priority $priority `
            -SourceAddressPrefix $cidr -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 22
        $rulesChanged = $true
    }
    $priority++
}

foreach ($cidr in $AllowedCidrs) {
    $ruleName = "allow-dfremote-udp1235-from-" + ($cidr -replace '[^a-zA-Z0-9]','-')
    if (-not ($nsg.SecurityRules | Where-Object { $_.Name -eq $ruleName })) {
        $nsg = $nsg | Add-AzNetworkSecurityRuleConfig -Name $ruleName `
            -Access Allow -Protocol Udp -Direction Inbound -Priority $priority `
            -SourceAddressPrefix $cidr -SourcePortRange * -DestinationAddressPrefix * `
            -DestinationPortRange 1235
        $rulesChanged = $true
    }
    $priority++
}

if ($rulesChanged) {
    $nsg = $nsg | Set-AzNetworkSecurityGroup
}

# 3) Virtual network + subnet
$subnetCfg = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.10.0.0/24" -NetworkSecurityGroup $nsg
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $vnet) {
    $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $Rg -Location $Location `
        -AddressPrefix "10.10.0.0/16" -Subnet $subnetCfg -ErrorAction Stop
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
} else {
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    if (-not $subnet) {
        $vnet | Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.10.0.0/24" -NetworkSecurityGroup $nsg | Out-Null
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    }
    if (-not $subnet.NetworkSecurityGroup -or $subnet.NetworkSecurityGroup.Id -ne $nsg.Id) {
        $vnet = Set-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -AddressPrefix $subnet.AddressPrefix -NetworkSecurityGroup $nsg
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
        $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    }
}

# 4) Public IP (static with DNS label)
$pubIp = Get-OrCreateResource -Description "public IP '$pipName'" `
    -Get    { Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $Rg -ErrorAction SilentlyContinue } `
    -Create { New-AzPublicIpAddress -Name $pipName -ResourceGroupName $Rg -Location $Location -AllocationMethod Static -Sku Standard -DomainNameLabel $DnsLabel -ErrorAction Stop }

# 5) Network interface
$nic = Get-OrCreateResource -Description "network interface '$nicName'" `
    -Get    { Get-AzNetworkInterface -Name $nicName -ResourceGroupName $Rg -ErrorAction SilentlyContinue } `
    -Create { New-AzNetworkInterface -Name $nicName -ResourceGroupName $Rg -Location $Location -SubnetId $subnet.Id -PublicIpAddressId $pubIp.Id -NetworkSecurityGroupId $nsg.Id -ErrorAction Stop }

if (-not $nic -or -not $nic.Id) { throw "NIC creation failed; check subnet/pip/nsg IDs." }

# 6) Cloud-init + VM config
$cloudInit = @"
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
  - [ /dev/disk/azure/scsi1/lun0, /srv/dfremote, 'ext4', 'defaults,nofail', '0', '2' ]
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
"@

$cloudInit = $cloudInit.Replace("{ADMINUSER}", $AdminUsername)

$dataDisk = Get-OrCreateResource -Description "managed disk '$diskName'" `
    -Get    { Get-AzDisk -DiskName $diskName -ResourceGroupName $Rg -ErrorAction SilentlyContinue } `
    -Create {
        $dataDiskCfg = New-AzDiskConfig -Location $Location -CreateOption Empty -DiskSizeGB $DataDiskSizeGB -SkuName "StandardSSD_LRS"
        New-AzDisk -DiskName $diskName -Disk $dataDiskCfg -ResourceGroupName $Rg -ErrorAction Stop
    }

$vmExists = Get-AzVM -Name $VmName -ResourceGroupName $Rg -ErrorAction SilentlyContinue
if (-not $vmExists) {
    $cred = New-Object System.Management.Automation.PSCredential ($AdminUsername, (ConvertTo-SecureString "unused" -AsPlainText -Force))
    $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize |
      Set-AzVMOperatingSystem -Linux -ComputerName $VmName -Credential $cred -DisablePasswordAuthentication |
      Set-AzVMSourceImage -PublisherName Canonical -Offer 0001-com-ubuntu-server-jammy -Skus 22_04-lts-gen2 -Version latest |
      Add-AzVMNetworkInterface -Id $nic.Id |
      Set-AzVMOSDisk -Name "$VmName-osdisk" -DiskSizeInGB $OsDiskSizeGB -CreateOption FromImage

    $vmConfig = Add-AzVMDataDisk -VM $vmConfig -Name $diskName -CreateOption Attach -ManagedDiskId $dataDisk.Id -Lun 0 -Caching ReadWrite

    if (-not $SshKey) {
        throw "SSH public key content was not loaded."
    }

    $authorizedKeyPath = "/home/$AdminUsername/.ssh/authorized_keys"
    $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig -KeyData $SshKey -Path $authorizedKeyPath

    $vmConfig.OSProfile.CustomData = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cloudInit))

    New-AzVM -ResourceGroupName $Rg -Location $Location -VM $vmConfig | Out-Null
} else {
    Write-Host "VM '$VmName' already exists; skipping creation." -ForegroundColor Yellow
}

# 7) (Optional) Auto-shutdown
try {
  az vm auto-shutdown -g $Rg -n $VmName --time 0100 --email "" | Out-Null
} catch {
  Write-Host "Auto-shutdown via az CLI not set (CLI missing?). You can set it in the Portal (Operations -> Auto-shutdown)." -ForegroundColor Yellow
}

# 8) Output connection details
$pub = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $Rg
"DF Remote public DNS: $($pub.DnsSettings.Fqdn)"
"DF Remote public IP:  $($pub.IpAddress)"
"UDP Port:             1235 (allowed only from: $($AllowedCidrs -join ', '))"
"SSH:                  ssh $AdminUsername@$($pub.DnsSettings.Fqdn)"


