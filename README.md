# Ephemeral Cloud VPN

> 🚧 Work in progress — not yet functional.

An iPhone app for launching temporary Tencent Cloud nodes in `ap-guangzhou`, installing a Shadowsocks server, and cleaning up the cloud resources when you finish. A user-owned Tencent Cloud Function (SCF), deployed from a custom container image and invoked on demand, runs provisioning and cleanup. Sessions default to a one-hour lifetime with scheduled cleanup. The client app (such as Shadowrocket) is outside this project's scope.

## Product direction

- Use credentials supplied by the user to provision a node in a selected cloud region.
- Install and configure the Shadowsocks server on the node; show connection details for use in a separate client.
- Track resources created for each session and offer an explicit stop-and-cleanup flow.
- Keep any orchestration inside the user's cloud account; the project does not operate a backend.

The first release should prove one provider, one region, and one server protocol end to end before expanding to more clouds or protocols. See [the product design](docs/design/ephemeral-cloud-vpn/DESIGN.md) and [implementation plan](docs/design/ephemeral-cloud-vpn/IMPLEMENT_PLAN.md).

## Security and cost

Cloud credentials can create billable, internet-facing resources. The app must explain the required permissions, protect the controller invocation credential with the platform credential store, scope created resources for cleanup, and show what will be deleted before stopping a session. Cloud-side deletion can fail or be interrupted, so sessions need reconciliation and a visible cleanup status. This software is not yet suitable for production or sensitive traffic.
