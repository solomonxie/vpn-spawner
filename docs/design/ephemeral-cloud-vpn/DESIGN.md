# Product Design

## Problem

The user wants temporary VPN or proxy endpoints in specific countries or cloud regions without keeping a permanent server running. Existing hosted services own the infrastructure and limit provider, region, and protocol choices. Operating cloud resources manually adds setup time and makes reliable teardown difficult.

## Goals

- Launch an ephemeral node in a user-selected supported provider and region.
- Install a Shadowsocks server on a temporary Tencent CVM node and show its connection details.
- Keep orchestration in the user's Tencent Cloud account; operate without a project backend.
- Make resource ownership, estimated costs, connection details, and teardown status visible.
- Remove resources created for a session when the user ends it.

## Non-goals

- A hosted VPN fleet or account service operated by this project.
- Anonymous or unmanaged cloud access; users bring authorized provider credentials.
- Guaranteeing that a cloud region maps to a particular national jurisdiction or exit location.
- Building a VPN tunnel client or integrating the Shadowrocket app.
- Supporting every cloud and protocol in the first release.
- Hiding activity from cloud providers or replacing endpoint security controls.

## Options considered

- Project-operated control backend: simplifies provider integrations, but adds a service that stores credentials or acts on user authority.
- Direct mobile-to-provider control: simplest infrastructure and no controller cost, but long workflows and recovery depend on the app returning.
- User-owned Tencent SCF controller: can keep cloud workflows running after the app disconnects, with per-invocation cost, deployment complexity, and a server-side role to secure.
- User-owned temporary CVM controller: familiar runtime and full workflow control, but adds a billable public server and another service that must be secured and deleted.

## Decision

Target Tencent Cloud in `ap-guangzhou`, connecting from North America, with a Shadowsocks server installed on each node. The user supplies a compatible client such as Shadowrocket; this app provisions infrastructure, configures the server, shows connection details, and cleans up resources.

Use a persistent, user-owned SCF event function deployed from a custom container image. Place the function and its private TCR image in `ap-guangzhou`, subject to Tencent's same-region image requirement. Install it once through a documented Tencent CLI or console workflow, outside the mobile app, so broad setup permissions never enter the app. Invoke it on demand from the mobile app using a credential scoped to this function. The SCF execution role receives the cloud permissions needed for the supported resource lifecycle. Set a one-hour default expiry starting when the controller accepts a launch request, and create a cloud-side scheduled cleanup. Keep the function and image available between sessions; ordinary session teardown does not remove them. Users can explicitly extend a session, which moves its scheduled deadline.

Prototype SCF timer and Tencent EventBridge options for one-time, per-session cleanup. SCF documents recurring timer triggers; verify whether an exact-expiry trigger can be safely created and removed per session, and account for trigger quotas. If a suitable one-time schedule is unavailable or too limited, use a periodic SCF timer that checks persisted expiry metadata and cleans expired, session-tagged resources. If Tencent CAM cannot scope important create/delete APIs by region, resource, or tag as required, document the unavoidable permission breadth and constrain those APIs in the function's fixed server-side configuration. CVM instance creation assigns IDs at runtime, so exact-name IAM scoping may not be available; test region and tag conditions and restrict allowed images, network, security group, and instance configuration. Never accept arbitrary resource names, shell commands, image IDs, or bootstrap scripts from the app.

The no-backend requirement means this project will not operate a service. A user-owned SCF function is still a backend component operationally, but it runs in the user's account and under the user's billing and permissions. Keep app credentials in iOS Keychain, never logs or exported session data, and explain that a compromised or unlocked device can invoke whatever its CAM policy permits. Design provider adapters and session records so Android can be added later without changing the product's lifecycle model.

This decision accepts responsibility for maintaining the user's SCF image and configuration in exchange for workflow continuity when the mobile app is unavailable. Revisit it if the controller requires broad permissions that cannot be safely constrained.

## Data & integrations

- Store the minimum credential needed to invoke the user's SCF controller locally in iOS Keychain; use the equivalent protected store on any future Android client.
- Store session metadata locally: provider, region, created resource identifiers, lifecycle state, timestamps, and cleanup outcome. Persist authoritative expiry/session state in Tencent-side storage or tags so cleanup does not depend on the phone.
- Call Tencent SCF APIs from the device to invoke the user's controller. The controller uses its SCF execution role to call CVM and networking APIs in `ap-guangzhou` and to manage expiry schedules. Confirm least-privilege policies can support the full lifecycle before adopting this design.
- Show server endpoint and Shadowsocks connection details only after the session is ready. Avoid persisting passwords in logs, analytics, crash reports, or clipboard history longer than needed.
- Cloud resources incur provider charges while they exist. Surface estimates where provider data permits; estimates are not guarantees.

## Lifecycle and failure handling

Provisioning must tag or otherwise mark every created resource with a unique session identifier and expiry time. The one-hour default is a safety deadline, not proof that deletion succeeded: scheduled cleanup must be idempotent, retry partial failures, and expose cleanup status. Teardown must enumerate all resources created for the session, including disks, addresses, firewall rules, snapshots, and schedules. On app restart, reconcile local state with provider state. Keep the SCF controller and image deployed across sessions.

## Risks / open questions

- Tencent CAM may require broader permissions for create APIs because new resource IDs are unknown before creation; validate every required action and tag condition. The CVM API authorization table should be checked per operation rather than assuming all CVM permissions have the same scope.
- Tencent schedule choices, delivery delay, retry behavior, and quota may affect the one-hour expiry target. Confirm SCF timer or EventBridge behavior in `ap-guangzhou`.
- Provider APIs and terms may constrain mobile invocation, function deployment, or node bootstrap scripts.
- Static CAM keys on a phone are a significant risk; first-release credential format and minimum permissions need provider-specific review.
- Interrupted setup or teardown can leave exposed, billable resources. Cleanup must be idempotent and observable.
- Scheduled cleanup can fail or be delayed; provide retries, visible status, and a manual cleanup path.
- Cloud region names do not guarantee physical location, latency, or legal jurisdiction.
- The controller's container registry image and function logs may incur charges or retain data; set retention and review image access.
