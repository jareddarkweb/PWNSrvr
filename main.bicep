param location string = resourceGroup().location
param environmentName string = 'pwnmachine-env'
param vnetName string = 'pwnmachine-vnet'
param storageAccountName string = 'pmstorage${uniqueString(resourceGroup().id)}'
param logAnalyticsName string = 'pwnmachine-logs'

// Container Images
param powerdnsImage string = 'pwnmachine/powerdns:latest'
param traefikImage string = 'pwnmachine/traefik:latest'
param managerImage string = 'pwnmachine/manager:latest'
param redisImage string = 'redis:latest'
param mariadbImage string = 'mariadb:10'

// Secrets & Config
@secure()
param letsEncryptEmail string
@secure()
param pdnsMysqlRootPassword string
@secure()
param pdnsApiKey string

var pdnsDatabaseName = 'pdns'

// --- Networking ---
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'aca-subnet'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'app-envs'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// --- Storage ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

var shareNames = [
  'powerdns-data'
  'powerdns-logs'
  'redis-data'
  'traefik-data'
  'traefik-logs'
]

resource shares 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = [for share in shareNames: {
  parent: fileService
  name: share
}]

// --- Observability ---
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// --- Managed Environment ---
resource acaEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: vnet.properties.subnets[0].id
      internal: false
    }
  }
}

// Environment Storage Links
resource acaEnvStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = [for share in shareNames: {
  parent: acaEnvironment
  name: share
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: share
      accessMode: 'ReadWrite'
    }
  }
}]

// --- Container Apps ---

// 1. Redis
resource redisApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pm-redis'
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      ingress: {
        external: false
        targetPort: 6379
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'pm-redis'
          image: redisImage
          args: ['redis-server', '--appendonly', 'yes']
          volumeMounts: [{ volumeName: 'vol-redis-data', mountPath: '/data' }]
        }
      ]
      volumes: [{ name: 'vol-redis-data', storageName: 'redis-data', storageType: 'AzureFile' }]
    }
  }
  dependsOn: [acaEnvStorage]
}

// 2. PowerDNS DB
resource powerdnsDbApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pm-powerdns-db'
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      secrets: [{ name: 'mysql-root-password', value: pdnsMysqlRootPassword }]
      ingress: {
        external: false
        targetPort: 3306
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'pm-powerdns-db'
          image: mariadbImage
          env: [
            { name: 'MYSQL_ROOT_PASSWORD', secretRef: 'mysql-root-password' }
            { name: 'MYSQL_DATABASE', value: pdnsDatabaseName }
          ]
          volumeMounts: [{ volumeName: 'vol-powerdns-data', mountPath: '/var/lib/mysql' }]
        }
      ]
      volumes: [{ name: 'vol-powerdns-data', storageName: 'powerdns-data', storageType: 'AzureFile' }]
    }
  }
  dependsOn: [acaEnvStorage]
}

// 3. PowerDNS
resource powerdnsApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pm-powerdns'
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      secrets: [
        { name: 'pdns-api-key', value: pdnsApiKey }
        { name: 'mysql-password', value: pdnsMysqlRootPassword }
      ]
      ingress: {
        external: true
        targetPort: 53
        transport: 'tcp' // Note: UDP is not supported in standard ACA Ingress
      }
    }
    template: {
      containers: [
        {
          name: 'pm-powerdns'
          image: powerdnsImage
          env: [
            { name: 'MYSQL_HOST', value: 'pm-powerdns-db' }
            { name: 'MYSQL_USER', value: 'root' }
            { name: 'MYSQL_PASSWORD', secretRef: 'mysql-password' }
            { name: 'MYSQL_DATABASE', value: pdnsDatabaseName }
            { name: 'PDNS_API_KEY', secretRef: 'pdns-api-key' }
          ]
          volumeMounts: [{ volumeName: 'vol-powerdns-logs', mountPath: '/logs/pdns' }]
        }
      ]
      volumes: [{ name: 'vol-powerdns-logs', storageName: 'powerdns-logs', storageType: 'AzureFile' }]
    }
  }
  dependsOn: [powerdnsDbApp, acaEnvStorage]
}

// 4. Traefik
resource traefikApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pm-traefik'
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      secrets: [
        { name: 'lets-encrypt-email', value: letsEncryptEmail }
        { name: 'pdns-api-key', value: pdnsApiKey }
      ]
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
      }
    }
    template: {
      containers: [
        {
          name: 'pm-traefik'
          image: traefikImage
          env: [
            { name: 'LETS_ENCRYPT_EMAIL', secretRef: 'lets-encrypt-email' }
            { name: 'TRAEFIK_PROVIDERS_REDIS_ENDPOINTS', value: 'pm-redis:6379' }
            { name: 'PDNS_API_KEY', secretRef: 'pdns-api-key' }
            { name: 'PDNS_API_URL', value: 'http://pm-powerdns:8081/' }
          ]
          volumeMounts: [
            { volumeName: 'vol-traefik-data', mountPath: '/data' }
            { volumeName: 'vol-traefik-logs', mountPath: '/logs/traefik' }
          ]
        }
      ]
      volumes: [
        { name: 'vol-traefik-data', storageName: 'traefik-data', storageType: 'AzureFile' }
        { name: 'vol-traefik-logs', storageName: 'traefik-logs', storageType: 'AzureFile' }
      ]
    }
  }
  dependsOn: [redisApp, powerdnsApp, acaEnvStorage]
}

// 5. Manager
resource managerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'pm-manager'
  location: location
  properties: {
    managedEnvironmentId: acaEnvironment.id
    configuration: {
      secrets: [{ name: 'pdns-api-key', value: pdnsApiKey }]
    }
    template: {
      containers: [
        {
          name: 'pm-manager'
          image: managerImage
          env: [
            { name: 'PM_REDIS_HOST', value: 'redis://pm-redis' }
            { name: 'PM_POWERDNS_HTTP_API', value: 'http://pm-powerdns:8081' }
            { name: 'PM_POWERDNS_HTTP_API_KEY', secretRef: 'pdns-api-key' }
          ]
        }
      ]
    }
  }
  dependsOn: [redisApp, powerdnsApp]
}
