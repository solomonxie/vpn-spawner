# Implementation Plan

## Phase 1: Validate Tencent Cloud architecture and scope

Prove the first vertical slice in Tencent Cloud `ap-guangzhou`, targeting a Shadowsocks server reachable from North America through a separate client. Validate the persistent, user-owned SCF custom-image controller, its permission boundary, and automatic one-hour cleanup before app work depends on them.

- [ ] T1.1 Confirm CVM/SCF availability and API behavior in `ap-guangzhou` — depends: none
- [ ] T1.2 Specify the Shadowsocks server bootstrap and connection fields for a separate client — depends: T1.1
- [ ] T1.3 Build a custom SCF container image with the required Tencent SDK and provisioning tools; document one-time installation outside the app — depends: T1.1
- [ ] T1.4 Prototype app invocation and controller operation after app termination or phone shutdown — depends: T1.3
- [ ] T1.5 Validate CAM permissions per API, including region/resource/tag restrictions and create-time gaps — depends: T1.4
- [ ] T1.6 Prototype one-hour expiry scheduling using SCF timer or EventBridge; verify delivery, retries, quotas, and schedule cleanup — depends: T1.3
- [ ] T1.7 Inventory resources, fixed configuration, session tags, expiry metadata, and deletion order — depends: T1.2, T1.5
- [ ] T1.8 Run the lifecycle in a disposable Tencent Cloud project and estimate node, SCF, schedule, registry, and logging costs — depends: T1.5, T1.6, T1.7

## Phase 2: iOS foundation and resumable sessions

Build the native app and persist session state before connecting it to cloud operations. The app invokes the controller, displays workflow and expiry status, and resumes status checks after it closes or loses network access.

- [ ] T2.1 Create the SwiftUI app shell and establish supported iOS versions — depends: T1.2
- [ ] T2.2 Implement secure invocation credential storage and redacted diagnostics — depends: T2.1, T1.5
- [ ] T2.3 Define persistent session states, idempotency keys, resource ownership identifiers, expiry, and migration strategy — depends: T2.1, T1.7

## Phase 3: Tencent orchestration and Shadowsocks end to end

Implement the validated SCF controller and node lifecycle. Keep creation, the scheduled deadline, and teardown tied to the same session identity. The app must reconnect and inspect durable progress after interruption; a compatible connection client is operated separately by the user.

- [ ] T3.1 Package the persistent SCF custom-image controller and execution role for one-time CLI/console installation — depends: T1.3, T1.5
- [ ] T3.2 Connect the app to the installed controller using invoke-only credentials — depends: T3.1, T2.2
- [ ] T3.3 Provision one tagged CVM node with fixed Shadowsocks server configuration — depends: T3.2, T2.3
- [ ] T3.4 Schedule automatic cleanup at session expiry, defaulting to 60 minutes from launch request acceptance — depends: T3.3, T1.6
- [ ] T3.5 Implement explicit session extension by updating authoritative expiry and its schedule — depends: T3.4
- [ ] T3.6 Implement idempotent teardown of the node, related resources, and expiry schedule — depends: T3.4
- [ ] T3.7 Return endpoint and Shadowsocks connection details without logging secrets — depends: T3.3
- [ ] T3.8 Reconcile workflow and cleanup after app termination, network loss, or scheduled cleanup failure — depends: T3.6, T3.7

## Phase 4: User experience and release hardening

Expose lifecycle and cost implications clearly, then validate recovery and security before adding provider breadth. App-store readiness follows a complete, supportable lifecycle.

- [ ] T4.1 Add controller connection, region, launch, session, expiry, extension, and stop flows — depends: T3.4, T3.5, T3.7
- [ ] T4.2 Add cost disclosures, permissions guidance, expiry, and cleanup status — depends: T4.1, T1.8
- [ ] T4.3 Review key handling, logs, network behavior, and failure recovery — depends: T3.8, T4.2
- [ ] T4.4 Document user setup and first-release limitations — depends: T4.3

## Phase 5: Expand platform and integrations

Add breadth only after the first provider lifecycle is reliable. Reuse product-level session behavior while implementing provider-specific resource management.

- [ ] T5.1 Add another provider adapter and its cleanup inventory — depends: T4.3
- [ ] T5.2 Add another server protocol setup if desired — depends: T4.3
- [ ] T5.3 Evaluate Android implementation against shared lifecycle behavior — depends: T4.3
