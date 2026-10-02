#!/bin/bash
# CVM user-data: serves the requested PROTOCOLS on one node, plus an HTTP endpoint (8389)
# with /client.json (all connection details), /sub (base64 URI feed), /health, /log, /diag.
# Placeholders {{...}} are filled by controller/app.py and the iOS app (ComputeClient).
export DEBIAN_FRONTEND=noninteractive

SS_PORT={{SS_PORT}}
SS_PASSWORD='{{SS_PASSWORD}}'
SS_METHOD='{{SS_METHOD}}'
TAG='{{TAG}}'
IKEV2_PSK='{{IKEV2_PSK}}'
PROTOCOLS='{{PROTOCOLS}}'
VPN_POOL=10.99.0.0/24
WG_POOL=10.66.0.0/24

# sing-box serves ss2022 / VLESS Reality / VMess WS / Trojan / Hysteria2. Pinned + checksummed, so a
# mirror can be tried when GitHub is slow from mainland China without trusting the mirror.
SINGBOX_VERSION=1.14.2
SINGBOX_SHA256=a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6
SINGBOX_PROTOCOLS="ss2022 vless_reality vmess_ws trojan hysteria2"

wants() { [[ ",$PROTOCOLS," == *",$1,"* ]]; }
wants_any() { for p in "$@"; do wants "$p" && return 0; done; return 1; }

PKGS="python3 curl iptables openssl"
wants_any shadowsocks ss_obfs && PKGS="$PKGS shadowsocks-libev"
wants ss_obfs && PKGS="$PKGS simple-obfs"
wants ikev2 && PKGS="$PKGS charon-systemd strongswan-swanctl libcharon-extra-plugins"
wants wireguard && PKGS="$PKGS wireguard-tools"
PUBLIC_IP=$(curl -s --retry 10 --retry-delay 2 http://metadata.tencentyun.com/latest/meta-data/public-ipv4)
APP_ID=$(curl -s --retry 5 http://metadata.tencentyun.com/latest/meta-data/app-id)
WAN_IF=$(ip route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
mkdir -p /etc/vpn-node /opt/vpn-sub
chmod 700 /etc/vpn-node
stage() { echo "$1" > /etc/vpn-node/stage; echo "== $1"; }
stage "starting"

# --- HTTP first, so /health and /log answer (with the current stage) while setup runs ---
cat > /opt/vpn-sub/sub_server.py <<'PYEOF'
import base64
import http.server
import json
import plistlib
import socketserver
import subprocess
import urllib.parse
import uuid

PORT = 8389
NODE = IP = TAG = None


def load_node():
    """node.json appears only when setup finishes; until then only /health (with the stage) and /log answer."""
    global NODE, IP, TAG
    if NODE is None:
        try:
            NODE = json.load(open("/etc/vpn-node/node.json"))
            IP, TAG = NODE["public_ip"], NODE["tag"]
        except (OSError, ValueError):
            return False
    return True


def stage():
    try:
        return open("/etc/vpn-node/stage").read().strip()
    except OSError:
        return "starting"
Q = urllib.parse.quote


def b64(s):
    return base64.b64encode(s.encode()).decode()


def endpoints():
    """Every enabled protocol: import URI + structured params (used by tests and the app)."""
    out = []
    p = NODE["protocols"]
    if "ikev2" in p:
        out.append({"proto": "ikev2", "port": 500, "uri": "", "note": "Connect from the app",
                    "params": {"server": IP, "remote_id": IP, "local_id": "vpn-client", "psk": NODE["ikev2_psk"]}})
    if "shadowsocks" in p:
        out.append({"proto": "shadowsocks", "port": NODE["ss_port"],
                    "uri": f"ss://{b64(NODE['ss_method'] + ':' + NODE['ss_password'])}@{IP}:{NODE['ss_port']}#{Q(TAG + '-SS')}",
                    "params": {"method": NODE["ss_method"], "password": NODE["ss_password"]}})
    if "ss_obfs" in p:
        plugin = Q("obfs-local;obfs=http;obfs-host=www.bing.com", safe="")
        out.append({"proto": "ss_obfs", "port": 8390,
                    "uri": f"ss://{b64(NODE['ss_method'] + ':' + NODE['ss_password'])}@{IP}:8390/?plugin={plugin}#{Q(TAG + '-SS-obfs')}",
                    "params": {"method": NODE["ss_method"], "password": NODE["ss_password"],
                               "plugin": "obfs-local", "plugin_opts": "obfs=http;obfs-host=www.bing.com"}})
    if "ss2022" in p and "ss2022_password" in NODE:
        method = "2022-blake3-aes-128-gcm"
        out.append({"proto": "ss2022", "port": 8446,
                    "uri": f"ss://{method}:{Q(NODE['ss2022_password'], safe='')}@{IP}:8446#{Q(TAG + '-SS2022')}",
                    "params": {"method": method, "password": NODE["ss2022_password"]}})
    if "vless_reality" in p and "vless_uuid" in NODE:
        q = urllib.parse.urlencode({"encryption": "none", "flow": "xtls-rprx-vision", "security": "reality",
                                    "sni": NODE["reality_sni"], "fp": "chrome", "pbk": NODE["reality_public_key"],
                                    "sid": NODE["reality_short_id"], "type": "tcp"})
        out.append({"proto": "vless_reality", "port": 443,
                    "uri": f"vless://{NODE['vless_uuid']}@{IP}:443?{q}#{Q(TAG + '-VLESS')}",
                    "params": {"uuid": NODE["vless_uuid"], "public_key": NODE["reality_public_key"],
                               "short_id": NODE["reality_short_id"], "sni": NODE["reality_sni"]}})
    if "vmess_ws" in p and "vmess_uuid" in NODE:
        cfg = {"v": "2", "ps": TAG + "-VMess", "add": IP, "port": "8445", "id": NODE["vmess_uuid"], "aid": "0",
               "scy": "auto", "net": "ws", "type": "none", "host": "", "path": "/ws", "tls": ""}
        out.append({"proto": "vmess_ws", "port": 8445, "uri": "vmess://" + b64(json.dumps(cfg)),
                    "params": {"uuid": NODE["vmess_uuid"], "path": "/ws"}})
    if "trojan" in p and "trojan_password" in NODE:
        out.append({"proto": "trojan", "port": 8443,
                    "uri": f"trojan://{Q(NODE['trojan_password'], safe='')}@{IP}:8443?security=tls&sni=www.bing.com&allowInsecure=1&type=tcp#{Q(TAG + '-Trojan')}",
                    "note": "Self-signed certificate: allow insecure",
                    "params": {"password": NODE["trojan_password"], "sni": "www.bing.com"}})
    if "hysteria2" in p and "hy2_password" in NODE:
        out.append({"proto": "hysteria2", "port": 8443,
                    "uri": f"hysteria2://{Q(NODE['hy2_password'], safe='')}@{IP}:8443?sni=www.bing.com&insecure=1#{Q(TAG + '-Hy2')}",
                    "note": "UDP. Self-signed certificate: insecure",
                    "params": {"password": NODE["hy2_password"], "sni": "www.bing.com"}})
    if "wireguard" in p and "wg_server_pub" in NODE:
        conf = (f"[Interface]\nPrivateKey = {NODE['wg_client_key']}\nAddress = 10.66.0.2/32\nDNS = 119.29.29.29\n\n"
                f"[Peer]\nPublicKey = {NODE['wg_server_pub']}\nEndpoint = {IP}:51820\n"
                f"AllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n")
        out.append({"proto": "wireguard", "port": 51820, "uri": conf, "note": "Import into the WireGuard app",
                    "params": {"private_key": NODE["wg_client_key"], "server_public_key": NODE["wg_server_pub"],
                               "address": "10.66.0.2/32"}})
    return out


def client_json():
    return json.dumps({"server": IP, "endpoints": endpoints()}).encode()


def sub_feed():
    lines = [e["uri"] for e in endpoints() if e["uri"].split("://")[0] in ("ss", "vless", "vmess", "trojan", "hysteria2")]
    return base64.b64encode(("\n".join(lines) + "\n").encode())


def mobileconfig():
    sa = {"EncryptionAlgorithm": "AES-256", "IntegrityAlgorithm": "SHA2-256",
          "DiffieHellmanGroup": 14, "LifeTimeInMinutes": 1440}
    vpn = {
        "PayloadType": "com.apple.vpn.managed",
        "PayloadIdentifier": f"vpnspawner.ikev2.{IP}",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadVersion": 1,
        "PayloadDisplayName": f"IKEv2 {TAG}",
        "UserDefinedName": f"{TAG} IKEv2",
        "VPNType": "IKEv2",
        "IKEv2": {
            "RemoteAddress": IP, "RemoteIdentifier": IP, "LocalIdentifier": "vpn-client",
            "AuthenticationMethod": "SharedSecret", "SharedSecret": NODE["ikev2_psk"],
            "ExtendedAuthEnabled": 0, "DeadPeerDetectionRate": "Medium",
            "IKESecurityAssociationParameters": sa, "ChildSecurityAssociationParameters": sa,
        },
    }
    return plistlib.dumps({
        "PayloadType": "Configuration", "PayloadIdentifier": f"vpnspawner.{IP}",
        "PayloadUUID": str(uuid.uuid4()).upper(), "PayloadVersion": 1,
        "PayloadDisplayName": f"VPN Spawner {TAG}", "PayloadContent": [vpn],
    })


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def active(unit):
    return run("systemctl", "is-active", unit).strip() == "active"


def log():
    units = []
    for unit in ("cloud-final", "strongswan", "sing-box", "shadowsocks-libev", "shadowsocks-libev-server@obfs", "wg-quick@wg0"):
        units += ["-u", unit]
    return run("journalctl", *units, "-n", "300", "--no-pager", "-o", "short-iso").encode()


def protocol_status():
    p = NODE["protocols"]
    singbox = active("sing-box")
    status = {}
    if "ikev2" in p:
        # ESP must run in userspace: Tencent images block the kernel esp4 module.
        status["ikev2"] = (active("strongswan") and "ikev2-psk" in run("swanctl", "--list-conns")
                           and "kernel-libipsec" in run("swanctl", "--stats"))
    if "shadowsocks" in p:
        status["shadowsocks"] = active("shadowsocks-libev")
    if "ss_obfs" in p:
        status["ss_obfs"] = active("shadowsocks-libev-server@obfs")
    for name in ("ss2022", "vless_reality", "vmess_ws", "trojan", "hysteria2"):
        if name in p:
            status[name] = singbox
    if "wireguard" in p:
        status["wireguard"] = active("wg-quick@wg0")
    return status


def health():
    if not load_node():
        return json.dumps({"ready": False, "stage": stage()}).encode()
    status = protocol_status()
    unavailable = NODE.get("unavailable", {})
    return json.dumps({
        # Setup finished: everything that could be installed is up; the rest is listed with a reason.
        "ready": bool(status) and all(status.values()),
        "protocols": status,
        "unavailable": unavailable,
        "stage": stage(),
        # Pre-multi-protocol clients read these.
        "shadowsocks": status.get("shadowsocks", True),
        "ikev2": status.get("ikev2", True),
        "ipsec_backend": status.get("ikev2", True),
        "kernel": run("uname", "-r").strip(),
    }).encode()


def diag():
    cmds = {
        "uname": "uname -a",
        "services": "systemctl --no-pager --type=service --state=running | grep -Ei 'sing|shadow|strong|wg|vpn' || true",
        "listening": "ss -lntup 2>&1 | head -40",
        "singbox": "/usr/local/bin/sing-box version 2>&1; /usr/local/bin/sing-box check -c /etc/vpn-node/sing-box.json 2>&1; echo rc=$?",
        "blacklist": "grep -rHiE 'esp|xfrm|ipsec|af_key|wireguard' /etc/modprobe.d /lib/modprobe.d 2>&1 || true",
        "wg": "wg show 2>&1 | sed 's/private key.*/private key: (hidden)/'",
        "cloud_init_tail": "tail -60 /var/log/cloud-init-output.log 2>&1",
    }
    out = []
    for name, cmd in cmds.items():
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
        out.append(f"===== {name}\n$ {cmd}\n{r.stdout}{r.stderr}")
    return "\n".join(out).encode()


ROUTES = {
    "/client.json": (client_json, "application/json"),
    "/sub": (sub_feed, "text/plain; charset=utf-8"),
    "/ikev2.mobileconfig": (mobileconfig, "application/x-apple-aspen-config"),
    "/health": (health, "application/json"),
    "/log": (log, "text/plain; charset=utf-8"),
    "/diag": (diag, "text/plain; charset=utf-8"),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if not load_node() and path not in ("/health", "/log", "/diag"):
            path = "/health"
        build, ctype = ROUTES.get(path, ROUTES["/sub"])
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
Description=VPN client config / subscription / health endpoint
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

stage "installing packages"
apt-get update -y
apt-get install -y $PKGS

sysctl -w net.ipv4.ip_forward=1
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- Shadowsocks (plain on SS_PORT; obfs on 8390 as a second ss-server instance) ---
if wants shadowsocks; then
  cat > /etc/shadowsocks-libev/config.json <<EOF
{"server": "0.0.0.0", "server_port": $SS_PORT, "password": "$SS_PASSWORD", "timeout": 300,
 "method": "$SS_METHOD", "fast_open": false, "nameserver": "8.8.8.8", "mode": "tcp_and_udp"}
EOF
  systemctl enable shadowsocks-libev
  systemctl restart shadowsocks-libev
else
  systemctl disable --now shadowsocks-libev 2>/dev/null || true
fi
if wants ss_obfs; then
  cat > /etc/shadowsocks-libev/obfs.json <<EOF
{"server": "0.0.0.0", "server_port": 8390, "password": "$SS_PASSWORD", "timeout": 300,
 "method": "$SS_METHOD", "fast_open": false, "nameserver": "8.8.8.8", "mode": "tcp_only",
 "plugin": "obfs-server", "plugin_opts": "obfs=http"}
EOF
  systemctl enable --now shadowsocks-libev-server@obfs
fi

# --- IKEv2 PSK (iOS / Android 12+ / macOS native clients) ---
if wants ikev2; then
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

  # Tencent images block the kernel ESP module (/etc/modprobe.d/dirtyfrag.conf: install esp4 /bin/false),
  # a vulnerability mitigation; kernel SAs then fail with "Protocol not supported". Do ESP in userspace
  # (TUN device) instead of lifting the mitigation.
  cat > /etc/strongswan.d/charon/kernel-libipsec.conf <<EOF
kernel-libipsec {
  load = yes
}
EOF
  # Verbose IKE/config logging to the journal; exposed at /log for debugging client failures.
  cat > /etc/strongswan.d/charon-systemd-log.conf <<EOF
charon-systemd {
  journal {
    default = 1
    ike = 2
    cfg = 2
    knl = 1
  }
}
EOF
  iptables -t nat -A POSTROUTING -s $VPN_POOL -o "$WAN_IF" -j MASQUERADE
  systemctl enable strongswan
  systemctl restart strongswan
  sleep 2
  swanctl --load-all
fi

# --- sing-box ---
SINGBOX_NEEDED=no
for p in $SINGBOX_PROTOCOLS; do wants "$p" && SINGBOX_NEEDED=yes; done
if [ "$SINGBOX_NEEDED" = yes ]; then
  stage "downloading sing-box"
  TGZ=/tmp/sing-box.tgz
  ASSET="sing-box-$SINGBOX_VERSION-linux-amd64.tar.gz"
  GH="https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/$ASSET"
  # Same-region COS copy (internal network, free) named from this account's app-id; GitHub + mirrors race it.
  python3 - "$TGZ" "$SINGBOX_SHA256" \
    "https://vpn-spawner-assets-$APP_ID.cos.ap-guangzhou.myqcloud.com/sing-box/$ASSET" \
    "$GH" "https://ghfast.top/$GH" "https://gh-proxy.com/$GH" "https://ghproxy.net/$GH" "https://gh.llkk.cc/$GH" <<'PYEOF'
import hashlib, shutil, sys, threading, time, urllib.request
dest, sha, urls = sys.argv[1], sys.argv[2], sys.argv[3:]
won = threading.Event()
def fetch(i, url):
    try:
        data = urllib.request.urlopen(url, timeout=20).read()
        if hashlib.sha256(data).hexdigest() == sha and not won.is_set():
            won.set()
            open(dest, "wb").write(data)
            print(f"sing-box from {url}")
        else:
            print(f"checksum mismatch from {url}")
    except Exception as e:
        print(f"{url}: {e}")
for i, url in enumerate(urls):
    threading.Thread(target=fetch, args=(i, url), daemon=True).start()
won.wait(180)
time.sleep(1)
sys.exit(0 if won.is_set() else 1)
PYEOF
  if [ -f "$TGZ" ]; then
    tar xzf "$TGZ" -C /tmp
    install -m 755 "/tmp/sing-box-$SINGBOX_VERSION-linux-amd64/sing-box" /usr/local/bin/sing-box
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -keyout /etc/vpn-node/key.pem -out /etc/vpn-node/cert.pem -subj "/CN=www.bing.com" 2>/dev/null
fi

# --- WireGuard keys (config written by setup below) ---
if wants wireguard; then
  umask 077
  wg genkey | tee /etc/vpn-node/wg_server.key | wg pubkey > /etc/vpn-node/wg_server.pub
  wg genkey | tee /etc/vpn-node/wg_client.key | wg pubkey > /etc/vpn-node/wg_client.pub
  umask 022
fi

# --- Generate per-protocol secrets + configs + node.json ---
stage "configuring protocols"
cat > /opt/vpn-sub/setup.py <<'PYEOF'
import base64
import json
import os
import secrets
import subprocess
import uuid

env = os.environ
protocols = [p for p in env["PROTOCOLS"].split(",") if p]
node = {
    "public_ip": env["PUBLIC_IP"], "tag": env["TAG"], "protocols": protocols,
    "ss_port": int(env["SS_PORT"]), "ss_password": env["SS_PASSWORD"], "ss_method": env["SS_METHOD"],
    "ikev2_psk": env["IKEV2_PSK"],
}


SINGBOX = "/usr/local/bin/sing-box"
SINGBOX_PROTOCOLS = {"ss2022", "vless_reality", "vmess_ws", "trojan", "hysteria2"}


def sb(*args):
    return subprocess.run([SINGBOX, *args], capture_output=True, text=True).stdout


# A failed download (GitHub is intermittent from mainland China) costs only the sing-box protocols.
node["unavailable"] = {}
if SINGBOX_PROTOCOLS & set(protocols) and not os.path.exists(SINGBOX):
    for p in sorted(SINGBOX_PROTOCOLS & set(protocols)):
        node["unavailable"][p] = "sing-box download failed (GitHub and mirrors unreachable)"
    protocols = [p for p in protocols if p not in SINGBOX_PROTOCOLS]
if "wireguard" in protocols and not os.path.exists("/etc/vpn-node/wg_server.pub"):
    node["unavailable"]["wireguard"] = "WireGuard key generation failed"
    protocols.remove("wireguard")
node["protocols"] = protocols

inbounds = []
tls = {"enabled": True, "certificate_path": "/etc/vpn-node/cert.pem", "key_path": "/etc/vpn-node/key.pem"}
if "ss2022" in protocols:
    node["ss2022_password"] = base64.b64encode(secrets.token_bytes(16)).decode()
    inbounds.append({"type": "shadowsocks", "tag": "ss2022", "listen": "::", "listen_port": 8446,
                     "method": "2022-blake3-aes-128-gcm", "password": node["ss2022_password"]})
if "vless_reality" in protocols:
    pair = dict(line.split(": ", 1) for line in sb("generate", "reality-keypair").strip().splitlines())
    node.update(vless_uuid=str(uuid.uuid4()), reality_public_key=pair.get("PublicKey", ""),
                reality_short_id=secrets.token_hex(8), reality_sni="www.microsoft.com")
    inbounds.append({"type": "vless", "tag": "vless", "listen": "::", "listen_port": 443,
                     "users": [{"uuid": node["vless_uuid"], "flow": "xtls-rprx-vision"}],
                     "tls": {"enabled": True, "server_name": node["reality_sni"], "reality": {
                         "enabled": True, "handshake": {"server": node["reality_sni"], "server_port": 443},
                         "private_key": pair.get("PrivateKey", ""), "short_id": [node["reality_short_id"]]}}})
if "vmess_ws" in protocols:
    node["vmess_uuid"] = str(uuid.uuid4())
    inbounds.append({"type": "vmess", "tag": "vmess", "listen": "::", "listen_port": 8445,
                     "users": [{"uuid": node["vmess_uuid"], "alterId": 0}],
                     "transport": {"type": "ws", "path": "/ws"}})
if "trojan" in protocols:
    node["trojan_password"] = secrets.token_urlsafe(18)
    inbounds.append({"type": "trojan", "tag": "trojan", "listen": "::", "listen_port": 8443,
                     "users": [{"password": node["trojan_password"]}], "tls": tls})
if "hysteria2" in protocols:
    node["hy2_password"] = secrets.token_urlsafe(18)
    inbounds.append({"type": "hysteria2", "tag": "hy2", "listen": "::", "listen_port": 8443,
                     "users": [{"password": node["hy2_password"]}], "tls": {**tls, "alpn": ["h3"]}})
if inbounds:
    with open("/etc/vpn-node/sing-box.json", "w") as f:
        json.dump({"log": {"level": "warn"}, "inbounds": inbounds, "outbounds": [{"type": "direct"}]}, f, indent=1)

if "wireguard" in protocols:
    read = lambda name: open(f"/etc/vpn-node/{name}").read().strip()
    node.update(wg_server_pub=read("wg_server.pub"), wg_client_key=read("wg_client.key"))
    with open("/etc/wireguard/wg0.conf", "w") as f:
        f.write(f"""[Interface]
Address = 10.66.0.1/24
ListenPort = 51820
PrivateKey = {read("wg_server.key")}
PostUp = iptables -t nat -A POSTROUTING -s {env["WG_POOL"]} -o {env["WAN_IF"]} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s {env["WG_POOL"]} -o {env["WAN_IF"]} -j MASQUERADE

[Peer]
PublicKey = {read("wg_client.pub")}
AllowedIPs = 10.66.0.2/32
""")
    os.chmod("/etc/wireguard/wg0.conf", 0o600)

with open("/etc/vpn-node/node.json", "w") as f:
    json.dump(node, f)
os.chmod("/etc/vpn-node/node.json", 0o600)
PYEOF
PUBLIC_IP="$PUBLIC_IP" WAN_IF="$WAN_IF" WG_POOL="$WG_POOL" TAG="$TAG" PROTOCOLS="$PROTOCOLS" \
  SS_PORT="$SS_PORT" SS_PASSWORD="$SS_PASSWORD" SS_METHOD="$SS_METHOD" IKEV2_PSK="$IKEV2_PSK" \
  python3 /opt/vpn-sub/setup.py

if [ -f /etc/vpn-node/sing-box.json ] && [ -x /usr/local/bin/sing-box ]; then
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/vpn-node/sing-box.json
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box
fi
if wants wireguard; then
  systemctl enable --now wg-quick@wg0
fi

stage "done"
