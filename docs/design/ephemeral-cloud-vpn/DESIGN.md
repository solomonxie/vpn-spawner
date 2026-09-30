# Product Design

## Problem

The user wants temporary VPN or proxy endpoints in specific countries or cloud regions without keeping a permanent server running. Existing hosted services own the infrastructure and limit provider, region, and protocol choices. Operating cloud resources manually adds setup time and makes reliable teardown difficult.

## Goals

- Launch an ephemeral node in a user-selected supported provider and region.
- Support several connection protocols over time and export compatible client configuration.
- Keep provider control and session state on the user's device; operate without a project backend.
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
- Direct mobile-to-provider control: matches the no-backend requirement, but places credential security, provider API behavior, and recovery on the client.
- User-run relay/controller: reduces mobile credential exposure, but adds infrastructure and setup the user did not request.

## Decision

Start with direct mobile-to-provider control. Keep long-lived credentials in the operating system's secure credential store, never logs or exported session data. Require narrowly scoped provider permissions and explain that a compromised or unlocked device can still use them. Design provider adapters and session records so Android can be added later without changing the product's lifecycle model.

This decision accepts a larger mobile security burden and more provider-specific client code to avoid operating a project backend. Revisit it if provider APIs cannot safely support the required provisioning flow from mobile clients.

## Data & integrations

- Store provider credentials locally in iOS Keychain; use the equivalent protected store on any future Android client.
- Store session metadata locally: provider, region, created resource identifiers, lifecycle state, timestamps, and cleanup outcome.
- Call cloud control-plane APIs directly from the device. Initial provider and protocol are implementation decisions for the first milestone.
- Deliver endpoint and connection configuration to the user only after the session is ready. Avoid persisting private keys or sharing links in analytics, logs, or crash reports.
- Cloud resources incur provider charges while they exist. Surface estimates where provider data permits; estimates are not guarantees.

## Lifecycle and failure handling

Provisioning must tag or otherwise mark every created resource with a unique session identifier. Teardown must enumerate and delete the resources owned by that session, report partial failures, and support retry. On app restart, reconcile local sessions with provider state. Do not equate a successful server deletion with deletion of all related disks, addresses, firewall rules, snapshots, or other billable resources.

## Risks / open questions

- Which provider and protocol should be the first supported pair?
- Provider APIs and terms may constrain use of credentials from mobile apps or distribution of bootstrapping scripts.
- Static cloud keys on a phone are a significant risk; first-release credential formats and minimum permissions need provider-specific review.
- Interrupted setup or teardown can leave exposed, billable resources. Cleanup must be idempotent and observable.
- Cloud region names do not guarantee physical location, latency, or legal jurisdiction.
- A no-backend design limits remote recovery if the device is lost or the app is removed before cleanup.
- A third-party connection client may be needed for protocol support; supported import formats and licensing remain open.
