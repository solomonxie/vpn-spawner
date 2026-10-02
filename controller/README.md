# SCF Controller

Ephemeral VPN controller running as a Tencent Cloud Function (SCF).
Same code runs locally via `spawn.py` and `tests/test_real_lifecycle.py`.

## Node

One CVM, set up by `bootstrap.sh` (also bundled into the iOS app, so both paths provision identically):

| Protocol | Port | Clients |
|---|---|---|
| Shadowsocks | TCP/UDP 8388 | Shadowrocket etc. |
| IKEv2 PSK (strongSwan) | UDP 500/4500 | iOS, Android 12+, macOS native — no app |
| HTTP | TCP 8389 | `/sub` ss:// feed, `/ikev2.mobileconfig` iPhone profile, `/health` |

IKEv2 manual setup: Server = Remote ID = node IP, Local ID `vpn-client`, PSK from `launch` (`ikev2Psk`).

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
| `launch` | `allowIps: [ip]` (required), `ikev2Psk` (optional, generated) | pick cheapest zone/type on sale, create SG, bind to new CVM |
| `status` | `instanceId` | state + IP; once RUNNING, adds the node's own IP (hairpin) |
| `allow_ip` | `instanceId` or `securityGroupId`, `ip` | add ingress rule, return `allowedIps` |
| `terminate` | `instanceId` | terminate CVM, delete its SG |

Orphaned managed SGs (instance gone) are swept on each `launch`.

## AWS

Same contract with `"vendor": "aws"` (Lambda `vpn-spawner-controller` in ca-central-1, deployed by
`terraform/aws/vpn_spawner.tf`; build with `controller/package.sh`). Regions:
us-west-2, us-east-1, ca-central-1, eu-central-1, ap-northeast-1, ap-southeast-1.
Node: t3a.micro (falls back to t3.micro), Ubuntu 22.04, default VPC.

Self-destruct, three layers: per-node EventBridge Scheduler one-time schedule
(`vpn-spawner-<instance>`, moved in place by `extend`), the watchdog schedule (`reap` every
10 min), and the node shutting itself down 15 min past its `ExpiresAt` tag
(InstanceInitiatedShutdownBehavior=terminate).
