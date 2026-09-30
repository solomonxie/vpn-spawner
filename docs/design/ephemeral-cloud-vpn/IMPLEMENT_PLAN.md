# Implementation Plan

## Phase 1: Choose and validate the first vertical slice

Resolve the provider and protocol before building an abstraction that may not match real provider constraints. Validate the no-backend credential flow and the full resource lifecycle in a disposable cloud account.

- [ ] T1.1 Select the first provider, protocol, and compatible client format — depends: none
- [ ] T1.2 Define least-privilege permissions and a disposable-account validation procedure — depends: T1.1
- [ ] T1.3 Map all resources created by provisioning and their teardown order — depends: T1.1

## Phase 2: iOS foundation and local secrets

Build the native app foundation and local session model before cloud operations. Credential handling and lifecycle state are prerequisites for safely retrying asynchronous provisioning and teardown.

- [ ] T2.1 Create the SwiftUI app shell and establish supported iOS versions — depends: T1.1
- [ ] T2.2 Implement secure local credential storage and redacted diagnostics — depends: T2.1, T1.2
- [ ] T2.3 Define persistent session states, resource ownership identifiers, and migration strategy — depends: T2.1, T1.3

## Phase 3: One provider and protocol end to end

Implement the selected provider integration behind a narrow adapter, then deliver one usable connection configuration. Keep creation and teardown tied to the same session identity.

- [ ] T3.1 Implement provider authentication and region discovery — depends: T2.2
- [ ] T3.2 Provision and configure one node with protocol-specific bootstrap — depends: T3.1, T2.3
- [ ] T3.3 Produce and validate the connection configuration — depends: T3.2
- [ ] T3.4 Implement idempotent teardown, partial-failure reporting, and retry — depends: T3.2
- [ ] T3.5 Reconcile interrupted sessions against provider state on app launch — depends: T3.4

## Phase 4: User experience and release hardening

Expose lifecycle and cost implications clearly, then validate recovery and security before adding provider breadth. App-store readiness follows a complete, supportable lifecycle.

- [ ] T4.1 Add provider credential, region, launch, connection, and stop flows — depends: T3.3, T3.4
- [ ] T4.2 Add cost disclosures, permissions guidance, and cleanup status — depends: T4.1, T1.2
- [ ] T4.3 Review key handling, logs, network behavior, and failure recovery — depends: T3.5, T4.2
- [ ] T4.4 Document user setup and first-release limitations — depends: T4.3

## Phase 5: Expand platform and integrations

Add breadth only after the first provider lifecycle is reliable. Reuse product-level session behavior while implementing provider-specific resource management.

- [ ] T5.1 Add another provider adapter and its cleanup inventory — depends: T4.3
- [ ] T5.2 Add another protocol and client configuration format — depends: T4.3
- [ ] T5.3 Evaluate Android implementation against shared lifecycle behavior — depends: T4.3
