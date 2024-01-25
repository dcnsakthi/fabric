// Power BI Embedded Capacity Azure Deployment Bicep Script

param workspaceName string
param skuName string
param capacityAdmin string

resource workspace 'Microsoft.PowerBIDedicated/capacities@2021-01-01' = {
  name: workspaceName
  location: resourceGroup().location
  sku: {
    name: skuName
  }
  properties: {
    administration: {
      members: [ capacityAdmin
      ]
    }
    mode :'Gen2'
  }
}
