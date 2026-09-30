# Product Design

## Problem

The user wants temporary VPN or proxy endpoints in specific countries or cloud regions without keeping a permanent server running. Existing hosted services own the infrastructure and limit provider, region, and protocol choices. Operating cloud resources manually adds setup time and makes reliable teardown difficult.

## Goals

- Launch an ephemeral node in a user-selected supported provider and region.
- Support several connection protocols over time and export compatible client configuration.
- Keep orchestration in the user's Tencent Cloud account; operate without a project backend.
- Make resource ownership, estimated costs, connection details, and teardown status visible.
- Remove resources created for a session when the user ends it.

## Non-goals

- A hosted VPN fleet or account service operated by this project.
- Anonymous or unmanaged cloud access; users bring authorized provider credentials.
- Guaranteeing that a cloud region maps to a particular national jurisdiction or exit location.
- Supporting every cloud and protocol in the first release.
- Hiding activity from cloud providers or replacing endpoint security controls.

## Options considered

- Project-operated control backend: simplifies provider integrations, but adds a service that stores credentials or acts on user authority.
- Direct mobile-to-provider control: simplest infrastructure and no controller cost, but long workflows and recovery depend on the app returning.
- User-owned Tencent SCF controller: can keep cloud workflows running after the app disconnects, with per-invocation cost, deployment complexity, and a server-side role to secure.
- User-owned temporary CVM controller: familiar runtime and full workflow control, but adds a billable public server and another service that must be secured and deleted.

## Decision

Target Tencent Cloud in `ap-guangzhou`, connecting from North America, with Shadowsocks as the first protocol candidate. Prototype a user-owned SCF controller before committing to the orchestration design. Prefer a controller that stays in the user's account but is idle between sessions, invoked through Tencent's control plane, with a narrowly scoped app credential and a separate SCF execution role. Evaluate whether the function and any triggers can be removed after cleanup without leaving resources behind. If deploying SCF for every session requires broad CAM permissions or takes too long, fall back to direct app control with persisted state and resumable reconciliation.

The no-backend requirement means this project will not operate a service. A user-owned SCF function is still a backend component operationally, but it runs in the user's account and under the user's billing and permissions. Keep app credentials in iOS Keychain, never logs or exported session data, and explain that a compromised or unlocked device can invoke whatever its CAM policy permits. Design provider adapters and session records so Android can be added later without changing the product's lifecycle model.

This decision accepts a larger mobile security burden and more provider-specific client code to avoid operating a project backend. Revisit it if provider APIs cannot safely support the required provisioning flow from mobile clients.

## Data & integrations

- Store the minimum credential needed to invoke the user's SCF controller locally in iOS Keychain; use the equivalent protected store on any future Android client.
- Store session metadata locally: provider, region, created resource identifiers, lifecycle state, timestamps, and cleanup outcome.
- Call Tencent SCF APIs from the device to invoke the user's controller. The controller uses its SCF execution role to call CVM and networking APIs in `ap-guangzhou`. Confirm that least-privilege policies can support the full lifecycle before adopting this design.
- Deliver endpoint and connection configuration to the user only after the session is ready. Avoid persisting private keys or sharing links in analytics, logs, or crash reports.
- Cloud resources incur provider charges while they exist. Surface estimates where provider data permits; estimates are not guarantees.

## Lifecycle and failure handling

Provisioning must tag or otherwise mark every created resource with a unique session identifier. Teardown must enumerate and delete the resources owned by that session, report partial failures, and support retry. On app restart, reconcile local sessions with provider state. Do not equate a successful server deletion with deletion of all related disks, addresses, firewall rules, snapshots, or other billable resources.

## Risks / open questions

- Which provider and protocol should be the first supported pair?
- Provider APIs and terms may constrain mobile invocation, function deployment, or node bootstrap scripts.
- Tencent SCF controller permissions may be hard to narrow to only the session resources the app creates.
- Static CAM keys on a phone are a significant risk; first-release credential format and minimum permissions need provider-specific review.
- Interrupted setup or teardown can leave exposed, billable resources. Cleanup must be idempotent and observable.
- Deleting a controller before cleanup finishes, or failing to delete its triggers and related resources, can strand infrastructure. Controller self-removal needs an explicit, tested lifecycle.
- Cloud region names do not guarantee physical location, latency, or legal jurisdiction.
- If the controller is removed after a session, losing the device or its credential can limit remote recovery. An expiry-based cleanup path needs to be designed before relying on it.
- A third-party connection client may be needed for protocol support; supported import formats and licensing remain open.
