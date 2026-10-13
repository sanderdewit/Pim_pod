metadata description = 'Consumption Logic App used as a PIM for Groups (post-approval) custom extension. After an activation it runs Entra Cloud Sync provisionOnDemand so the AD group membership is updated immediately.'

@description('Name of the Logic App.')
param logicAppName string = 'LA-PIM-JIT'

@description('Azure region for the Logic App.')
param location string = resourceGroup().location

@description('Application (client) ID of the app registration that secures the endpoint. PIM requests a token for this app; its Application ID URI is the "resourceId" of the custom extension.')
param apiAppId string

@description('Optional. Application ID of the PIM service as it appears in the azp claim of the token PIM sends. When set, tokens issued to any other caller are rejected.')
param pimCallerAppId string = ''

@description('Object ID of the Cloud Sync service principal that owns the provisioning job.')
param syncServicePrincipalId string = '7dc02c72-03d1-462b-bf75-335fbffaa19e'

@description('ID of the Entra ID to AD group provisioning job.')
param syncJobId string = 'AAD2ADGroupProvisioning.bbafb01eee104a81847ce62a41c8c1d8.84174f1a-dc83-40c7-b120-c099a8c0d903'

@description('ID of the group synchronization rule (GET /servicePrincipals/{id}/synchronization/jobs/{jobId}/schema -> synchronizationRules[].id). Leave empty to look it up at run time.')
param syncRuleId string = ''

@description('Run provisionOnDemand again after the activation ends, so the membership is also removed from AD promptly.')
param syncOnExpiry bool = true

@description('Microsoft Graph version used for provisionOnDemand.')
@allowed([
  'v1.0'
  'beta'
])
param graphApiVersion string = 'v1.0'

@description('Troubleshooting only: include the Authorization header in the trigger outputs (run history) so you can inspect the token PIM sends.')
param includeAuthorizationHeaderInRunHistory bool = false

// PIM calls the endpoint with an Entra ID access token for apiAppId. The app registration is set to
// issue v2.0 tokens, so the audience is the app's client ID and the issuer is the v2.0 endpoint.
var tokenClaims = concat(
  [
    {
      name: 'iss'
      value: '${environment().authentication.loginEndpoint}${subscription().tenantId}/v2.0'
    }
    {
      name: 'aud'
      value: apiAppId
    }
  ],
  empty(pimCallerAppId)
    ? []
    : [
        {
          name: 'azp'
          value: pimCallerAppId
        }
      ]
)

var workflowDefinition = loadJsonContent('workflow.json')

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    accessControl: {
      triggers: {
        openAuthenticationPolicies: {
          policies: {
            'PIM-custom-extension': {
              type: 'AAD'
              claims: tokenClaims
            }
          }
        }
      }
    }
    definition: includeAuthorizationHeaderInRunHistory
      ? union(workflowDefinition, {
          triggers: {
            manual: union(workflowDefinition.triggers.manual, {
              operationOptions: 'IncludeAuthorizationHeadersInOutputs'
            })
          }
        })
      : workflowDefinition
    parameters: {
      syncServicePrincipalId: {
        value: syncServicePrincipalId
      }
      syncJobId: {
        value: syncJobId
      }
      syncRuleId: {
        value: syncRuleId
      }
      syncOnExpiry: {
        value: syncOnExpiry
      }
      graphApiVersion: {
        value: graphApiVersion
      }
    }
  }
}

// accessEndpoint looks like https://prod-NN.<region>.logic.azure.com:443/workflows/<id>
var endpoint = replace(logicApp.properties.accessEndpoint, ':443', '')

output logicAppId string = logicApp.id
output logicAppPrincipalId string = logicApp.identity.principalId

@description('Target URL for the PIM custom extension: the trigger URL without the SAS signature, so only OAuth requests are accepted.')
output customExtensionTargetUrl string = '${endpoint}/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0'

@description('Application ID URI to set on the app registration. Its host must match the host of the target URL.')
output applicationIdUri string = 'api://${split(split(endpoint, '://')[1], '/')[0]}/${apiAppId}'
