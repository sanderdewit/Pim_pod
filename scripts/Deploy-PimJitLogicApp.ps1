#Requires -Modules Az.Accounts, Az.Resources, Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Deploys LA-PIM-JIT: a Logic App that runs as a PIM for Groups (pre-approval) custom extension and
    calls Entra Cloud Sync provisionOnDemand for the activated member.

.DESCRIPTION
    1. Creates (or reuses) the app registration PIM requests a token for, set to issue v2.0 tokens.
    2. Deploys the Consumption Logic App with a system-assigned managed identity and an Entra ID OAuth
       authorization policy (infra/main.json, compiled from infra/main.bicep).
    3. Sets the app registration's Application ID URI to api://<logic app host>/<appId>
       (PIM requires the host to match the host of the endpoint URL).
    4. Grants the managed identity the Microsoft Graph application permissions it needs.
    5. Prints the values to enter when you create the custom extension in PIM.

    Run as a Global Administrator or Privileged Role Administrator with Contributor on the resource group.

.EXAMPLE
    ./Deploy-PimJitLogicApp.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroupName rg-pim-jit

.EXAMPLE
    # After you have confirmed which application ID PIM calls from (see README), lock the endpoint to it:
    ./Deploy-PimJitLogicApp.ps1 -SubscriptionId ... -ResourceGroupName rg-pim-jit -PimCallerAppId <appId>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $Location = 'westeurope',

    [string] $LogicAppName = 'LA-PIM-JIT',

    [string] $AppRegistrationName = 'LA-PIM-JIT PIM custom extension',

    [string] $SyncServicePrincipalId = '7dc02c72-03d1-462b-bf75-335fbffaa19e',

    [string] $SyncJobId = 'AAD2ADGroupProvisioning.bbafb01eee104a81847ce62a41c8c1d8.84174f1a-dc83-40c7-b120-c099a8c0d903',

    # 'auto' lets the Logic App look it up from the job schema at run time.
    [string] $SyncRuleId = 'auto',

    # Application ID in the azp claim of the token PIM sends. Leave empty until you have confirmed it.
    [string] $PimCallerAppId = '',

    [bool] $SyncOnRemoval = $true,

    [ValidateSet('v1.0', 'beta')]
    [string] $GraphApiVersion = 'v1.0',

    # Approved keeps any human approval in the PIM flow. AutoApproved skips it; see README.
    [ValidateSet('Approved', 'AutoApproved')]
    [string] $EvaluationOutcome = 'Approved',

    # Troubleshooting only: show the Authorization header PIM sends in the Logic App run history.
    [switch] $IncludeAuthorizationHeaderInRunHistory
)

$ErrorActionPreference = 'Stop'

$graph = 'https://graph.microsoft.com'
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphPermissions = @(
    'Synchronization.ReadWrite.All', # read the job schema, provisionOnDemand
    'GroupMember.Read.All',          # check when the user joins / leaves the group
    'User.ReadBasic.All'             # (checkMemberGroups on a user needs both)
)

function Invoke-Graph {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body
    )
    $request = @{ Method = $Method; Uri = "$graph/$Path"; OutputType = 'PSObject' }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 10
        $request.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @request
}

function ConvertTo-ODataFilter([string] $Filter) {
    '$filter=' + [uri]::EscapeDataString($Filter)
}

# --- Sign in --------------------------------------------------------------------------------------
if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
}
$context = Set-AzContext -Subscription $SubscriptionId
$tenantId = $context.Tenant.Id

Connect-MgGraph -TenantId $tenantId -NoWelcome -Scopes @(
    'Application.ReadWrite.All',      # create the app registration
    'AppRoleAssignment.ReadWrite.All' # grant Graph permissions to the managed identity
)

# --- 1. App registration that secures the endpoint ------------------------------------------------
$app = (Invoke-Graph -Path "v1.0/applications?$(ConvertTo-ODataFilter "displayName eq '$AppRegistrationName'")").value |
    Select-Object -First 1
if (-not $app) {
    Write-Host "Creating app registration '$AppRegistrationName'..."
    $app = Invoke-Graph -Method POST -Path 'v1.0/applications' -Body @{
        displayName    = $AppRegistrationName
        signInAudience = 'AzureADMyOrg'
        api            = @{ requestedAccessTokenVersion = 2 }
    }
} else {
    Write-Host "Reusing app registration '$AppRegistrationName' ($($app.appId))."
    Invoke-Graph -Method PATCH -Path "v1.0/applications/$($app.id)" -Body @{
        api = @{ requestedAccessTokenVersion = 2 }
    } | Out-Null
}

$appSp = (Invoke-Graph -Path "v1.0/servicePrincipals?$(ConvertTo-ODataFilter "appId eq '$($app.appId)'")").value |
    Select-Object -First 1
if (-not $appSp) {
    Invoke-Graph -Method POST -Path 'v1.0/servicePrincipals' -Body @{ appId = $app.appId } | Out-Null
}

# --- 2. Logic App ---------------------------------------------------------------------------------
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

Write-Host "Deploying Logic App '$LogicAppName'..."
$deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $ResourceGroupName `
    -Name "pim-jit-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    -TemplateFile ([IO.Path]::Combine($PSScriptRoot, '..', 'infra', 'main.json')) `
    -TemplateParameterObject @{
        logicAppName                           = $LogicAppName
        location                               = $Location
        apiAppId                               = $app.appId
        pimCallerAppId                         = $PimCallerAppId
        syncServicePrincipalId                 = $SyncServicePrincipalId
        syncJobId                              = $SyncJobId
        syncRuleId                             = $SyncRuleId
        syncOnRemoval                          = $SyncOnRemoval
        graphApiVersion                        = $GraphApiVersion
        evaluationOutcome                      = $EvaluationOutcome
        includeAuthorizationHeaderInRunHistory = $IncludeAuthorizationHeaderInRunHistory.IsPresent
    }

$targetUrl = $deployment.Outputs['customExtensionTargetUrl'].Value
$appIdUri = $deployment.Outputs['applicationIdUri'].Value
$miObjectId = $deployment.Outputs['logicAppPrincipalId'].Value

# --- 3. Application ID URI (host must match the endpoint host) ------------------------------------
Invoke-Graph -Method PATCH -Path "v1.0/applications/$($app.id)" -Body @{ identifierUris = @($appIdUri) } | Out-Null

# --- 4. Graph permissions for the managed identity ------------------------------------------------
$graphSp = (Invoke-Graph -Path "v1.0/servicePrincipals?$(ConvertTo-ODataFilter "appId eq '$graphAppId'")").value |
    Select-Object -First 1

# A new managed identity can take a moment to show up in Microsoft Graph.
for ($attempt = 1; ; $attempt++) {
    try {
        $existing = (Invoke-Graph -Path "v1.0/servicePrincipals/$miObjectId/appRoleAssignments").value
        break
    } catch {
        if ($attempt -ge 12) { throw }
        Start-Sleep -Seconds 10
    }
}

foreach ($permission in $graphPermissions) {
    $role = $graphSp.appRoles | Where-Object { $_.value -eq $permission -and $_.allowedMemberTypes -contains 'Application' }
    if ($existing | Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $graphSp.id }) {
        Write-Host "Managed identity already has $permission."
        continue
    }
    Invoke-Graph -Method POST -Path "v1.0/servicePrincipals/$miObjectId/appRoleAssignments" -Body @{
        principalId = $miObjectId
        resourceId  = $graphSp.id
        appRoleId   = $role.id
    } | Out-Null
    Write-Host "Granted $permission to the managed identity."
}

# --- 5. Values for the PIM custom extension -------------------------------------------------------
Write-Host ''
Write-Host 'Create the custom extension in Entra admin center > ID Governance > Privileged Identity Management > Custom extensions:' -ForegroundColor Green
Write-Host '  Basics              Resource type: Microsoft Entra Groups, Custom extension type: Pre-approval'
Write-Host "  Endpoint            $targetUrl"
Write-Host "  API authentication  $AppRegistrationName (app ID $($app.appId))"
Write-Host "                      Application ID URI: $appIdUri"
Write-Host ''
Write-Host 'Then link it in PIM > Groups > <group> > Settings > Member > Edit > Require pre-approval custom extension to activate.'

[pscustomobject]@{
    LogicAppName      = $LogicAppName
    TargetUrl         = $targetUrl
    AppRegistration   = $AppRegistrationName
    AppId             = $app.appId
    ApplicationIdUri  = $appIdUri
    ManagedIdentityId = $miObjectId
}
