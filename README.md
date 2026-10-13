# LA-PIM-JIT: just-in-time AD group sync for PIM for Groups

A Logic App that runs as a **post-approval PIM custom extension** for **Microsoft Entra Groups**.
When someone activates a PIM group membership, it calls the Cloud Sync
[`provisionOnDemand`](https://learn.microsoft.com/en-us/graph/api/synchronization-synchronizationjob-provisionondemand)
API, so the membership shows up in the on-premises AD group right away instead of on the next sync cycle.

```
User activates group membership in PIM
        │  (approval, if the role setting requires it)
        ▼
PIM calls the post-approval custom extension ── Bearer token for the app registration ──►  Logic App LA-PIM-JIT
                                                                                            │
  1. Replies 200 "Approved" straight away, so PIM never waits on the sync                   │
  2. Waits until the activation is active (polls PIM assignmentScheduleInstances)           │ managed identity
  3. POST …/synchronization/jobs/{jobId}/provisionOnDemand  (the group + the activated user)  ├──► Microsoft Graph ──► Cloud Sync ──► AD group
  4. Optional: waits until the activation ends, then runs provisionOnDemand again so the     │
     user is also removed from the AD group right away                                       │
```

Step 2 is needed because PIM calls the extension when the request is approved, which can be before
the membership exists in Entra ID. It also covers activations scheduled to start later.

## Do I need an app registration?

**Yes, one, with no secrets and no API permissions.** PIM authenticates to your endpoint by requesting an
Entra ID access token for an app registration. That app's **Application ID URI** is what you select on the
**API authentication** tab, and its host name must match the host name of the endpoint URL.

The Logic App doesn't need an app registration to call Microsoft Graph. It uses its own system-assigned
managed identity.

| Identity | Purpose | Configuration |
|---|---|---|
| App registration `LA-PIM-JIT PIM custom extension` | Audience of the token PIM sends to the Logic App | Application ID URI `api://<logic app host>/<appId>`, `requestedAccessTokenVersion = 2` |
| Logic App managed identity | Calls Microsoft Graph | Application permissions `Synchronization.ReadWrite.All`, `PrivilegedAssignmentSchedule.Read.AzureADGroup` |

## Repository contents

| Path | What it is |
|---|---|
| `infra/workflow.json` | Logic App workflow definition. You can also paste it into the Logic App code view. |
| `infra/main.bicep` | Consumption Logic App with managed identity and Entra ID OAuth authorization policy |
| `infra/main.json` | ARM template compiled from `main.bicep`. The script deploys this, so you don't need the Bicep CLI. |
| `scripts/Deploy-PimJitLogicApp.ps1` | End-to-end deployment: app registration, Logic App, Application ID URI, Graph permissions |
| `samples/pim-group-activation-request.json` | Request body for a manual test |

## Prerequisites

- Microsoft Entra ID Governance or Microsoft Entra Suite license. PIM custom extensions are in preview.
- Global Administrator or Privileged Role Administrator, to create the app registration and grant Graph
  application permissions to the managed identity.
- Contributor on the target resource group.
- PowerShell 7 with the `Az.Accounts`, `Az.Resources` and `Microsoft.Graph.Authentication` modules.
- The PIM group must be in scope of the Cloud Sync **Microsoft Entra ID to AD sync** configuration that
  owns the job (`AAD2ADGroupProvisioning.…`). The activating users need an AD account that the membership
  can point to. Check the configuration's **Configure group membership** setting if they're synced from AD.

## Deploy

```powershell
./scripts/Deploy-PimJitLogicApp.ps1 -SubscriptionId <subscription-id> -ResourceGroupName rg-pim-jit -Location westeurope
```

The defaults already contain your job:

| Parameter | Default |
|---|---|
| `-SyncServicePrincipalId` | `7dc02c72-03d1-462b-bf75-335fbffaa19e` |
| `-SyncJobId` | `AAD2ADGroupProvisioning.bbafb01eee104a81847ce62a41c8c1d8.84174f1a-dc83-40c7-b120-c099a8c0d903` |
| `-SyncRuleId` | Looked up from the job schema, so you normally leave it out |
| `-SyncOnExpiry` | `$true`, which also syncs the removal when the activation ends |
| `-GraphApiVersion` | `v1.0` (`beta` also works) |

> The URL you have ends in `/restart`. **Don't call that from the Logic App.** Restart clears the job state
> and forces a full sync. The Logic App calls `/provisionOnDemand` on the same job, and that call syncs only
> the one group and user.

The script prints these values at the end:

```
Endpoint            https://prod-NN.westeurope.logic.azure.com/workflows/<id>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0
API authentication  LA-PIM-JIT PIM custom extension (app ID <appId>)
                    Application ID URI: api://prod-NN.westeurope.logic.azure.com/<appId>
```

The endpoint URL deliberately has **no `sig=` parameter**. A Logic App rejects requests that carry both
a SAS signature and a bearer token. Without `sig`, it accepts only Entra ID tokens that match the
authorization policy.

## Create the custom extension in PIM

Go to **Entra admin center > ID Governance > Privileged Identity Management > Custom extensions >
Create a custom extension**.

1. **Basics**: Name `LA-PIM-JIT`, Resource type **Microsoft Entra Groups**, Custom extension type **Post-approval**.
2. **Endpoint configuration**: Target URL = the `Endpoint` value printed by the script. The Logic App
   replies within about a second, so the default timeout is fine.
3. **API authentication**: select the app registration `LA-PIM-JIT PIM custom extension`.
4. **Review + create**.

Then link the extension to the group: **PIM > Groups > *your group* > Settings > Member > Edit**, select the
post-approval custom extension, and **Save**. Only the `member` role needs it, because Cloud Sync writes
`members` to AD and not owners. The Logic App ignores owner activations.

## Verify

1. Activate the group membership as an eligible user.
2. In the Logic App, open **Run history**. Expect a run that:
   - returns `Approved` from `Respond_to_PIM`,
   - loops in `Until_assignment_active` until the activation shows up,
   - shows `{"result":"Success"…}` in `Provisioning_result`, or `Skipped` if AD already matched.
3. Check the group in AD. The user is a member.
4. If `SyncOnExpiry` is on, the same run stays **Running** until the activation ends. It then runs
   `Provision_on_demand_after_expiry`.

To test without PIM, use a user who already has an **active** membership of the group. Take the trigger URL
**with** `sig` from the Logic App designer, and post the sample body to it:

```powershell
$body = Get-Content ./samples/pim-group-activation-request.json -Raw   # fill in principalId and groupId first
Invoke-RestMethod -Method Post -Uri '<trigger URL with sig>' -ContentType 'application/json' -Body $body
```

## Lock the endpoint to the PIM service (recommended)

By default the Logic App accepts any v2.0 token from your tenant whose audience is the app registration
(`iss` + `aud`). Microsoft's documentation tells you to also check the caller's application ID (`azp`), but
the value it publishes is a documentation placeholder GUID. Find the real value in your tenant:

1. Redeploy with `-IncludeAuthorizationHeaderInRunHistory`. Activate once, open the run, copy the token from
   the trigger's `Authorization` header and decode it locally, for example at https://jwt.ms (which decodes
   in the browser). Note the `azp` claim.
2. Redeploy **without** that switch and with `-PimCallerAppId <azp value>`. The authorization policy then
   also requires `azp`.

Even without this check, a caller can only make the Logic App sync the current Entra state of a group to
AD. It can't grant access.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No run appears after an activation | PIM got a 401. Check that the app registration issues v2.0 tokens (`requestedAccessTokenVersion = 2`), that the Application ID URI host matches the endpoint host, and that the endpoint URL has no `sig`. |
| `Terminate_invalid_payload` | The request body isn't the documented `privilegedAccessGroupAssignmentScheduleRequest` shape. Post-approval is a preview feature. Look at the trigger body and adjust `Parse_request`. |
| `Get_assignment_instances` or `Provision_on_demand` returns 403 | The managed identity is missing a Graph permission. Grants can take a while to apply, because managed identity tokens are cached for up to 24 hours. |
| `AssignmentNotActive` | The activation wasn't active within 1 hour of approval, for example because it was cancelled. |
| `ProvisionOnDemandFailed`, or `Skipped` with an error code | Check the group is in scope of the Cloud Sync configuration and the user exists in AD. Run **Provision on demand** for the same group and user in the Cloud Sync portal to see the detailed steps. |
| HTTP 429 | `provisionOnDemand` is limited to 5 requests per 10 seconds. The HTTP actions retry automatically. |

## Notes and limits

- PIM post-approval extensions aren't in Microsoft's public docs yet, which so far only cover pre-approval.
  This Logic App assumes post-approval sends the same request body and accepts the same response
  (`evaluationId`, `evaluationOutcome`, `reason`). It always answers `Approved`, so it can never block or
  auto-approve an activation.
- Early deactivation (`selfDeactivate`) isn't handled. The removal reaches AD on the next regular Cloud Sync
  cycle, or when the expiry sync runs at the original end time.
- `provisionOnDemand` accepts one group with up to five members per call. The Logic App sends one group and
  one member.
