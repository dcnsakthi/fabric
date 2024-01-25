// Microsoft Fabric Capacity Azure Deployment Bicep Script

param capacityName string
param capacitySku string
param capacityAdmin string

resource capacity 'Microsoft.Fabric/capacities@2022-07-01-preview' = {
  name: capacityName
  location: resourceGroup().location
  sku: {
    name: capacitySku
    tier: 'Fabric'
  }
  properties:{
    administration: {
      members: [ capacityAdmin
      ]
    }
  }
}
