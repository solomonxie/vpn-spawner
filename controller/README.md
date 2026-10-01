# SCF Controller

Ephemeral VPN controller running as a Tencent Cloud Function (SCF).

## Deploy to Tencent Cloud

```bash
# Build and push to Tencent Container Registry (TCR) in ap-guangzhou
docker build -t ccr.ccs.tencentyun.com/<your-ns>/vpn-controller:latest .
docker push ccr.ccs.tencentyun.com/<your-ns>/vpn-controller:latest

# Create SCF function with container image and attach CAM role with CVM permissions
```

Set the function timeout to >= 150s: `terminate` waits up to `firewallWaitSeconds` (default 120) for the instance to release its security group before deleting it.

## Access control

Each node gets its own security group (`vpn-<sessionId>`, tagged `ManagedBy=VPNSpawner`):
ingress ALL only from the caller's IPs (`/32`), egress open.

| Action | Input | Effect |
|---|---|---|
| `launch` | `allowIps: [ip]` (required) | create SG, bind to new CVM |
| `allow_ip` | `instanceId` or `securityGroupId`, `ip` | add ingress rule, return `allowedIps` |
| `terminate` | `instanceId` | terminate CVM, delete its SG |

Orphaned managed SGs (instance gone) are swept on each `launch`.
