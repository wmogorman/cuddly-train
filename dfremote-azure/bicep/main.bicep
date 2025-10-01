@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Container Group (ACI) name')
param containerGroupName string = 'dfremote-aci'

@description('Container (inside ACI) name')
param containerName string = 'dfremote'

@description('Docker image to run')
param image string = 'mifki/dfremote'

@description('UDP port to expose')
param udpPort int = 1235

@description('Mount path inside the container (best default for DF Remote classic)')
param mountPath string = '/df/data/save'

@description('Storage account name (must be globally unique, 3-24 lowercase letters/numbers)')
param storageAccountName string

@description('Azure File Share name')
param fileShareName string = 'dfremote-saves'

@description('Container CPU cores')
param cpuCores int = 1

@description('Container memory in GB')
param memoryInGb int = 1

var skuName = 'Standard_LRS'

resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: skuName
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${sa.name}/default/${fileShareName}'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
  }
}

var saKey = listKeys(sa.id, '2023-01-01').keys[0].value

resource aci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  properties: {
    osType: 'Linux'
    ipAddress: {
      type: 'Public'
      ports: [
        {
          port: udpPort
          protocol: 'UDP'
        }
      ]
    }
    containers: [
      {
        name: containerName
        properties: {
          image: image
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGb: memoryInGb
            }
          }
          ports: [
            {
              port: udpPort
              protocol: 'UDP'
            }
          ]
          volumeMounts: [
            {
              name: 'saves'
              mountPath: mountPath
              readOnly: false
            }
          ]
        }
      }
    ]
    volumes: [
      {
        name: 'saves'
        azureFile: {
          shareName: share.name
          storageAccountName: sa.name
          storageAccountKey: saKey
        }
      }
    ]
  }
}

output publicIP string = aci.properties.ipAddress.ip
output fileShareUNC string = '//' + sa.name + '.file.core.windows.net/' + fileShareName
