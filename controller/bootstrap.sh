#!/bin/bash
# CVM user-data: Shadowsocks + native IKEv2 (PSK) on one node, plus an HTTP endpoint
# for the ss:// subscription, the iOS .mobileconfig and a health check.
# Placeholders {{...}} are filled by controller/app.py and the iOS app (ComputeClient).
export DEBIAN_FRONTEND=noninteractive

SS_PORT={{SS_PORT}}
SS_PASSWORD='{{SS_PASSWORD}}'
SS_METHOD='{{SS_METHOD}}'
TAG='{{TAG}}'
IKEV2_PSK='{{IKEV2_PSK}}'
VPN_POOL=10.99.0.0/24

apt-get update -y
apt-get install -y shadowsocks-libev python3 curl iptables charon-systemd strongswan-swanctl

PUBLIC_IP=$(curl -s --retry 10 --retry-delay 2 http://metadata.tencentyun.com/latest/meta-data/public-ipv4)
WAN_IF=$(ip route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')

mkdir -p /etc/vpn-node /opt/vpn-sub
cat > /etc/vpn-node/node.json <<EOF
{"public_ip": "$PUBLIC_IP", "ss_port": $SS_PORT, "ss_password": "$SS_PASSWORD",
 "ss_method": "$SS_METHOD", "tag": "$TAG", "ikev2_psk": "$IKEV2_PSK"}
EOF
chmod 600 /etc/vpn-node/node.json

# --- Shadowsocks ---
cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "timeout": 300,
    "method": "$SS_METHOD",
    "fast_open": false,
    "nameserver": "8.8.8.8",
    "mode": "tcp_and_udp"
}
EOF
systemctl enable shadowsocks-libev
systemctl restart shadowsocks-libev

# --- IKEv2 PSK (iOS / Android 12+ / macOS native clients) ---
cat > /etc/swanctl/conf.d/ikev2-psk.conf <<EOF
connections {
  ikev2-psk {
    version = 2
    proposals = aes256-sha256-modp2048,aes256-sha256-ecp256,aes128-sha256-modp2048,aes256-sha1-modp2048,aes256-sha256-modp1024,aes128-sha1-modp1024,default
    pools = vpn-pool
    unique = never
    dpd_delay = 30s
    send_certreq = no
    local {
      auth = psk
      id = $PUBLIC_IP
    }
    remote {
      auth = psk
    }
    children {
      ikev2-psk {
        local_ts = 0.0.0.0/0
        esp_proposals = aes256-sha256,aes128-sha256,aes256gcm16,aes128gcm16,aes256-sha1,aes128-sha1,default
        dpd_action = clear
      }
    }
  }
}
pools {
  vpn-pool {
    addrs = $VPN_POOL
    dns = 119.29.29.29, 1.1.1.1
  }
}
secrets {
  ike-psk {
    secret = "$IKEV2_PSK"
  }
}
EOF
chmod 600 /etc/swanctl/conf.d/ikev2-psk.conf

sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s $VPN_POOL -o "$WAN_IF" -j MASQUERADE
iptables -t mangle -A FORWARD -s $VPN_POOL -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360

systemctl enable strongswan
systemctl restart strongswan
sleep 2
swanctl --load-all

# --- HTTP: /sub (ss:// feed), /ikev2.mobileconfig, /health ---
cat > /opt/vpn-sub/sub_server.py <<'PYEOF'
import base64
import http.server
import json
import plistlib
import socketserver
import subprocess
import uuid

PORT = 8389
NODE = json.load(open("/etc/vpn-node/node.json"))


def ss_feed():
    info = f"{NODE['ss_method']}:{NODE['ss_password']}@{NODE['public_ip']}:{NODE['ss_port']}"
    uri = f"ss://{base64.b64encode(info.encode()).decode()}#{NODE['tag']}\n"
    return base64.b64encode(uri.encode())


def mobileconfig():
    sa = {"EncryptionAlgorithm": "AES-256", "IntegrityAlgorithm": "SHA2-256",
          "DiffieHellmanGroup": 14, "LifeTimeInMinutes": 1440}
    vpn = {
        "PayloadType": "com.apple.vpn.managed",
        "PayloadIdentifier": f"vpnspawner.ikev2.{NODE['public_ip']}",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadVersion": 1,
        "PayloadDisplayName": f"IKEv2 {NODE['tag']}",
        "UserDefinedName": f"{NODE['tag']} IKEv2",
        "VPNType": "IKEv2",
        "IKEv2": {
            "RemoteAddress": NODE["public_ip"],
            "RemoteIdentifier": NODE["public_ip"],
            "LocalIdentifier": "vpn-client",
            "AuthenticationMethod": "SharedSecret",
            "SharedSecret": NODE["ikev2_psk"],
            "ExtendedAuthEnabled": 0,
            "DeadPeerDetectionRate": "Medium",
            "IKESecurityAssociationParameters": sa,
            "ChildSecurityAssociationParameters": sa,
        },
    }
    return plistlib.dumps({
        "PayloadType": "Configuration",
        "PayloadIdentifier": f"vpnspawner.{NODE['public_ip']}",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadVersion": 1,
        "PayloadDisplayName": f"VPN Spawner {NODE['tag']}",
        "PayloadContent": [vpn],
    })


def active(unit):
    return subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True).stdout.strip() == "active"


def health():
    conns = subprocess.run(["swanctl", "--list-conns"], capture_output=True, text=True).stdout
    return json.dumps({
        "shadowsocks": active("shadowsocks-libev"),
        "ikev2": active("strongswan") and "ikev2-psk" in conns,
    }).encode()


ROUTES = {
    "/sub": (ss_feed, "text/plain; charset=utf-8"),
    "/ikev2.mobileconfig": (mobileconfig, "application/x-apple-aspen-config"),
    "/health": (health, "application/json"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        build, ctype = ROUTES.get(self.path.split("?")[0], ROUTES["/sub"])
        body = build()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()
PYEOF

cat > /etc/systemd/system/vpn-sub.service <<EOF
[Unit]
Description=VPN subscription / profile / health endpoint
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vpn-sub/sub_server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-sub.service
