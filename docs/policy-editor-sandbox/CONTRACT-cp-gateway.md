# Contract: Control Plane ⇄ Gateway policy sandbox

Both sides MUST implement exactly this. Changes require updating this file first.

## Gateway endpoint

`POST https://<gw-host>:<gw-servlet-port>/api/am/gateway/v2/policy-sandbox/execute`
- Auth: Basic (Environment username/password). The user must have `/permission/admin/manage/apim_admin`.
- Content-Type / Accept: `application/json`
- If `[apim.policy_sandbox] enable` is false on the gateway → **404** `{"code":404,"message":"Policy sandbox is disabled"}`
- Too many concurrent runs → **429**; body > max → **413**; invalid XML → **400** with `errors`.

### Request `PolicySandboxExecuteRequest`
```json
{
  "renderedSequence": "<sequence xmlns=\"http://ws.apache.org/ns/synapse\">...mediators...</sequence>",
  "flow": "request",
  "sampleRequest": {
    "method": "POST",
    "path": "/orders/1?x=y",
    "headers": {"Authorization": "Bearer abc", "Content-Type": "application/json"},
    "body": "{\"a\":1}",
    "contentType": "application/json"
  },
  "mocks": [
    {"id": "m1", "urlPattern": "https://idp.example.com/token*", "matchType": "GLOB",
     "method": "POST", "status": 401, "headers": {"Content-Type": "application/json"},
     "body": "{\"error\":\"invalid\"}", "contentType": "application/json", "delayMs": 0}
  ],
  "extraProperties": {"api.ut.userName": "admin"},
  "captureSnapshots": false
}
```
- `renderedSequence` is ALREADY rendered (no Jinja) and normalized by the CP: a single `<sequence>` root, no `name` attribute. The Gateway instruments the sequence's children with the nodeId contract (`apim-apps/.../PolicyForm/Editor/CONTRACT.md`).
- `flow`: `request` | `response` | `fault`. Only `request` is required for v1. For the others, run the sequence the same way and add a warning.
- `matchType`: `GLOB` | `REGEX`. `method` is optional (any method when absent).
- `extraProperties` are set as Synapse (default scope) properties before the policy runs.

### Response `PolicySandboxExecuteResponse` (HTTP 200 whenever the run was attempted)
```json
{
  "status": "COMPLETED",
  "respondedEarly": false,
  "durationMs": 132,
  "clientResponse": {"status": 200, "headers": {"Content-Type": "application/json"}, "body": "{...}"},
  "finalMessage": {"payload": "{...}", "contentType": "application/json", "httpStatus": 200,
                   "headers": {"Authorization": "Bearer xyz"}},
  "properties": {"synapse": {"LEAN_ACCESS_TOKEN": "xyz"}, "axis2": {"HTTP_SC": "200", "HTTP_METHOD": "POST"},
                 "transport": {"Authorization": "Bearer xyz"}},
  "logs": [{"ts": 1727300000000, "level": "INFO", "nodeId": "11", "message": "LEAN_AUTH_RESPONSE = Token endpoint response"}],
  "trace": [{"order": 0, "nodeId": "0", "tag": "property", "tMs": 1}],
  "outboundCalls": [{"nodeId": "10", "method": "POST", "url": "https://idp.example.com/token",
                     "mocked": true, "mockId": "m1", "status": 401, "requestBody": "username=...", "durationMs": 3}],
  "fault": {"code": "101504", "message": "...", "nodeId": "10"},
  "warnings": ["endpoint key='x' cannot be mocked"],
  "errors": []
}
```
- `status`: `COMPLETED` (reached end of policy) | `RESPONDED` (policy executed `<respond/>`) | `FAULT` (fault sequence triggered) | `DROPPED` | `TIMEOUT` | `ERROR` (sandbox infrastructure error; see `errors`).
- `respondedEarly` = `status == RESPONDED`.
- `fault` is present only for FAULT. `nodeId` is the last traced node before the fault. **The real Synapse fault is surfaced faithfully.** Example: a `<call blocking="true">` receiving 401 goes to FAULT. The sandbox must NOT pretend the flow continued into later nodes (user decision).
- Values are stringified and truncated: 64 KB per body/payload, 4 KB per property value, at most `max_log_lines` logs.
- `logs[].message` is built from the `<log>` properties as `name = value` pairs joined by `, `. `level` is the `<log level>` attribute value uppercased.

## Control Plane endpoints (publisher v4)

- `POST /operation-policies/render`: already implemented. Request `{policyDefinition, attributeValues}`; response `{renderedSequence, normalized, errors[], warnings[], detectedVariables[], unknownMediators[]}`.
- `POST /operation-policies/test`
  - Request: `{policyDefinition, attributeValues, flow, sampleRequest, mocks, extraProperties, gatewayEnvironment, captureSnapshots}`.
  - Behavior: render first. If there are render errors, return 200 with the render fields and no `execution`. Otherwise forward to the gateway.
  - Response: the render fields + `execution` (= the gateway response verbatim).
  - Gateway unreachable: 502. Sandbox disabled on the CP: 404. Gateway 404/429/413: map to the same code with a message.
- `GET /operation-policies/test/environments` → `{enabled: boolean, environments: [{name, displayName}]}`. Lists only config-defined environments that have a server URL (or `sandbox_url`).
- `GET /operation-policies/{operationPolicyId}/definition?gatewayType=Synapse` → `text/plain` (the raw .j2).
- `GET /apis/{apiId}/operation-policies/{operationPolicyId}/definition?gatewayType=Synapse` → `text/plain`.
- `SettingsDTO.operationPolicyTestEnabled: boolean`.
- Scopes: `apim:common_operation_policy_manage` and `apim:common_operation_policy_create` for common endpoints (same as `/render`); `apim:mediation_policy_create` / `apim:api_create` for the API-specific definition endpoint.
- UI operationIds already coded in apim-apps `data/api.js`: `renderOperationPolicy`, `testOperationPolicy`, `getOperationPolicySandboxEnvironments`, `getCommonOperationPolicyDefinition`, `getAPISpecificOperationPolicyDefinition`.

## Config (`api-manager.xml.j2` block `<OperationPolicySandbox>`, already added)
Keys: `enable`, `timeout` (CP→GW HTTP timeout, ms), `execution_timeout` (GW loopback run, ms), `max_concurrent_runs`, `max_log_lines`. Optional per-environment `sandbox_url` (new `Environment` field; base URL of the gateway REST v2, e.g. `https://gw:9444/api/am/gateway/v2`). When it is absent, derive the URL from `serverURL` by replacing a trailing `/services/` with `/api/am/gateway/v2`.
