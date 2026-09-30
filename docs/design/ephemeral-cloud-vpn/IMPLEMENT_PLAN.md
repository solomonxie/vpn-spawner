# Implementation Plan

## Phase 1: Validate Tencent Cloud architecture and scope

Prove the first vertical slice in Tencent Cloud `ap-guangzhou`, targeting a Shadowsocks endpoint reachable from North America. Compare direct app orchestration with a user-owned SCF controller, focusing on credential scope, workflow completion after phone disconnect, and complete teardown.

- [ ] T1.1 Confirm CVM/SCF availability and API behavior in `ap-guangzhou` — depends: none
- [ ] T1.2 Specify the Shadowsocks server implementation and client configuration format — depends: T1.1
- [ ] T1.3 Prototype direct control versus SCF orchestration, including an app-disconnect scenario — depends: T1.1
- [ ] T1.4 Define least-privilege CAM policies for the app and SCF role — depends: T1.3
- [ ] T1.5 Inventory created resources, session tags, expiry strategy, and deletion order — depends: T1.2, T1.3
- [ ] T1.6 Run the lifecycle in a disposable Tencent Cloud project and estimate session costs — depends: T1.4, T1.5

## Phase 2: iOS foundation and resumable sessions

Build the native app and persist session state before connecting it to cloud operations. Even with SCF, the phone can close or lose network access and must be able to query and resume the workflow later.

- [ ] T2.1 Create the SwiftUI app shell and establish supported iOS versions — depends: T1.2
- [ ] T2.2 Implement secure invocation credential storage and redacted diagnostics — depends: T2.1, T1.4
- [ ] T2.3 Define persistent session states, idempotency keys, resource ownership identifiers, and migration strategy — depends: T2.1, T1.5

## Phase 3: Tencent orchestration and Shadowsocks end to end

Implement the architecture selected by the prototype, then deliver one usable connection configuration. Keep creation, timeout handling, and teardown tied to the same session identity. The controller must report durable progress so the phone can reconnect after interruption.

- [ ] T3.1 Implement SCF controller deployment/invocation or direct Tencent authentication — depends: T1.3, T2.2
- [ ] T3.2 Provision one tagged CVM node and configure Shadowsocks — depends: T3.1, T2.3
- [ ] T3.3 Produce and validate a client configuration without logging its secret — depends: T3.2
- [ ] T3.4 Implement idempotent teardown of the node and every related resource — depends: T3.2
- [ ] T3.5 Reconcile progress and cleanup after app termination or network loss — depends: T3.4
- [ ] T3.6 Remove the controller and its triggers after successful cleanup, if the chosen design creates them per session — depends: T3.5

## Phase 4: User experience and release hardening

Expose lifecycle and cost implications clearly, then validate recovery and security before adding provider breadth. App-store readiness follows a complete, supportable lifecycle.

- [ ] T4.1 Add provider credential, region, launch, connection, and stop flows — depends: T3.3, T3.4
- [ ] T4.2 Add cost disclosures, permissions guidance, and cleanup status — depends: T4.1, T1.6
- [ ] T4.3 Review key handling, logs, network behavior, and failure recovery — depends: T3.5, T4.2
- [ ] T4.4 Document user setup and first-release limitations — depends: T4.3

## Phase 5: Expand platform and integrations

Add breadth only after the first provider lifecycle is reliable. Reuse product-level session behavior while implementing provider-specific resource management.

- [ ] T5.1 Add another provider adapter and its cleanup inventory — depends: T4.3
- [ ] T5.2 Add another protocol and client configuration format — depends: T4.3
- [ ] T5.3 Evaluate Android implementation against shared lifecycle behavior — depends: T4.3
