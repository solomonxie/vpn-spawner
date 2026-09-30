# Ephemeral Cloud VPN

> 🚧 Work in progress — not yet functional.

An iPhone app for launching temporary VPN nodes in cloud regions you choose, connecting with compatible clients, and tearing down the cloud resources when you finish. The first implementation will evaluate Tencent Cloud in `ap-guangzhou` with Shadowsocks as the initial protocol. A user-owned Tencent Cloud Function (SCF) may run provisioning and cleanup so the workflow can finish when the phone disconnects; the exact controller lifecycle is still being validated.

## Product direction

- Use credentials supplied by the user to provision a node in a selected cloud region.
- Make the node available through a supported VPN or proxy protocol and provide the configuration needed by a compatible client.
- Track resources created for each session and offer an explicit stop-and-cleanup flow.
- Keep any orchestration inside the user's cloud account; the project does not operate a backend.

The first release should prove one provider, one region selection flow, and one protocol end to end before expanding to more clouds or protocols. See [the product design](docs/design/ephemeral-cloud-vpn/DESIGN.md) and [implementation plan](docs/design/ephemeral-cloud-vpn/IMPLEMENT_PLAN.md).

## Security and cost

Cloud credentials can create billable, internet-facing resources. The app must explain the required permissions, protect secrets with the platform credential store, scope created resources for cleanup, and show what will be deleted before stopping a session. Cloud-side deletion can fail or be interrupted, so sessions need reconciliation and a visible cleanup status. This software is not yet suitable for production or sensitive traffic.
