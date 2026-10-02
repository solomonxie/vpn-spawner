"""End-to-end check of each non-native protocol: a local sing-box client (tools/sing-box)
tunnels a request through the node and the exit IP must be the node's."""
import json
import os
import socket
import subprocess
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SINGBOX = os.path.join(ROOT, "tools", "sing-box")
EXIT_IP_URL = "https://ip.3322.net"


def outbound(endpoint, server):
    p, port, proto = endpoint["params"], endpoint["port"], endpoint["proto"]
    base = {"tag": "out", "server": server, "server_port": port}
    if proto in ("shadowsocks", "ss2022"):
        return {**base, "type": "shadowsocks", "method": p["method"], "password": p["password"]}
    if proto == "ss_obfs":
        return {**base, "type": "shadowsocks", "method": p["method"], "password": p["password"],
                "plugin": p["plugin"], "plugin_opts": p["plugin_opts"]}
    if proto == "vless_reality":
        return {**base, "type": "vless", "uuid": p["uuid"], "flow": "xtls-rprx-vision",
                "tls": {"enabled": True, "server_name": p["sni"],
                        "utls": {"enabled": True, "fingerprint": "chrome"},
                        "reality": {"enabled": True, "public_key": p["public_key"], "short_id": p["short_id"]}}}
    if proto == "vmess_ws":
        return {**base, "type": "vmess", "uuid": p["uuid"], "security": "auto",
                "transport": {"type": "ws", "path": p["path"]}}
    if proto == "trojan":
        return {**base, "type": "trojan", "password": p["password"],
                "tls": {"enabled": True, "server_name": p["sni"], "insecure": True}}
    if proto == "hysteria2":
        return {**base, "type": "hysteria2", "password": p["password"],
                "tls": {"enabled": True, "server_name": p["sni"], "insecure": True, "alpn": ["h3"]}}
    raise ValueError(proto)


def client_config(endpoint, server, socks_port):
    cfg = {"log": {"level": "warn"},
           "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": socks_port}],
           "route": {"final": "out"}}
    if endpoint["proto"] == "wireguard":
        p = endpoint["params"]
        address = p["address"] if isinstance(p["address"], list) else [p["address"]]
        cfg["endpoints"] = [{"type": "wireguard", "tag": "out", "address": address,
                             "private_key": p["private_key"],
                             "peers": [{"address": server, "port": endpoint["port"],
                                        "public_key": p["server_public_key"], "allowed_ips": ["0.0.0.0/0", "::/0"]}]}]
        cfg["outbounds"] = [{"type": "direct", "tag": "direct"}]
    else:
        cfg["outbounds"] = [outbound(endpoint, server)]
    return cfg


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def check_config(cfg):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cfg, f)
    r = subprocess.run([SINGBOX, "check", "-c", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    return r.returncode == 0, r.stderr


def exit_ip_via(endpoint, server, attempts=3):
    """Returns (exit_ip_or_None, diagnostic)."""
    port = free_port()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(client_config(endpoint, server, port), f)
    proc = subprocess.Popen([SINGBOX, "run", "-c", f.name], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(1.5)
        last = ""
        for _ in range(attempts):
            r = subprocess.run(["curl", "-s", "-m", "20", "--socks5-hostname", f"127.0.0.1:{port}", EXIT_IP_URL],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip(), ""
            last = f"curl rc={r.returncode} {r.stderr.strip()}"
            time.sleep(2)
        return None, last
    finally:
        proc.terminate()
        try:
            out = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            out = ""
        os.unlink(f.name)
        if out:
            last_lines = "\n".join(out.strip().splitlines()[-5:])
            print(f"[sing-box client {endpoint['proto']}] {last_lines}")
