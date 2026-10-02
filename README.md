# VPN Spawner

Native iOS app that creates a temporary VPN server in your own AWS or Tencent Cloud account, connects the iPhone to it, and deletes it when time is up. No backend: the app talks only to your cloud provider and your server.

## Features

- **One-tap server**: cheapest small instance in the chosen region, ready in about two minutes.
- **Own firewall**: per-session security group admitting only your IPs.
- **Connect**: IKEv2 in-app via `NEVPNManager`; links/QR codes for Shadowsocks, VLESS, VMess, Trojan, Hysteria2 and WireGuard clients.
- **Self-destruct**: cloud-side timer plus watchdog; Destroy verifies the server and firewall are gone.
- **Privacy check**: exit IP, IPv6/DNS leaks, latency, speed.
- **Keys in Keychain**, least-privilege policies, Demo mode with no cloud calls.

## Setup

Cloud account setup (controller, permissions, keys): [`docs/setup.md`](docs/setup.md).

## Build

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your Team ID (gitignored)
python3 -m venv venv && venv/bin/pip install pytest boto3 tencentcloud-sdk-python
make help        # project, test, check, device, release
```

iOS 17+, iPhone only. Uses Apple's crypto only (NetworkExtension, CryptoKit); server software is installed on the node from upstream by `controller/bootstrap.sh`.

## License

MIT, see [LICENSE](LICENSE).
