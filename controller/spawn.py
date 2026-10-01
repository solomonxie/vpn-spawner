#!/usr/bin/env python3
import os
import sys
import time
import json
import base64
import socket
import argparse
import urllib.request

try:
    from app import main_handler
except ImportError:
    from controller.app import main_handler

def load_dotenv():
    env_file = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip("\"'"))

def current_public_ip():
    for url in ("https://api.ipify.org", "https://checkip.amazonaws.com"):
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                return resp.read().decode("utf-8").strip()
        except Exception:
            continue
    raise RuntimeError("Could not detect current public IP; pass --allow-ip")

def test_tcp_port(host, port, timeout=5):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        s.close()
        return True
    except Exception:
        return False

def test_http_sub(url, timeout=5):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Shadowrocket/1982"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8")
            decoded = base64.b64decode(content).decode("utf-8")
            return "ss://" in decoded
    except Exception:
        return False

def main():
    load_dotenv()
    parser = argparse.ArgumentParser(description="Spawn real ephemeral Shadowsocks node via controller")
    parser.add_argument("--region", default=os.environ.get("TENCENTCLOUD_REGION", "ap-guangzhou"), help="Tencent Cloud region")
    parser.add_argument("--secret-id", default=os.environ.get("TENCENTCLOUD_SECRET_ID"), help="Tencent Cloud SecretId")
    parser.add_argument("--secret-key", default=os.environ.get("TENCENTCLOUD_SECRET_KEY"), help="Tencent Cloud SecretKey")
    parser.add_argument("--port", type=int, default=8388, help="Shadowsocks port")
    parser.add_argument("--method", default="chacha20-ietf-poly1305", help="Cipher method")
    parser.add_argument("--keep", action="store_true", help="Keep instance running instead of cleaning up")
    parser.add_argument("--terminate", metavar="INSTANCE_ID", help="Terminate a specific instance and its security group")
    parser.add_argument("--allow-ip", action="append", default=[], help="IP allowed to reach the node (repeatable; default: current public IP)")
    parser.add_argument("--add-ip", metavar="INSTANCE_ID", help="Add --allow-ip (or current public IP) to a running node's allowlist")
    args = parser.parse_args()

    secret_id = args.secret_id
    secret_key = args.secret_key

    if not secret_id or not secret_key:
        print("ERROR: Tencent Cloud credentials required.")
        print("Provide via --secret-id and --secret-key, or set TENCENTCLOUD_SECRET_ID and TENCENTCLOUD_SECRET_KEY in environment or .env file.")
        sys.exit(1)

    if args.add_ip:
        ips = args.allow_ip or [current_public_ip()]
        for ip in ips:
            resp = main_handler({
                "ClientContext": {
                    "action": "allow_ip",
                    "region": args.region,
                    "instanceId": args.add_ip,
                    "ip": ip,
                    "secretId": secret_id,
                    "secretKey": secret_key
                }
            }, None)
            print(f"allow {ip}:", resp)
        return

    if args.terminate:
        print(f"Terminating instance {args.terminate} in {args.region}...")
        resp = main_handler({
            "ClientContext": {
                "action": "terminate",
                "region": args.region,
                "instanceId": args.terminate,
                "secretId": secret_id,
                "secretKey": secret_key
            }
        }, None)
        print("Termination response:", resp)
        return

    allow_ips = args.allow_ip or [current_public_ip()]
    session_id = f"test-{int(time.time()) % 10000}"
    password = base64.b64encode(os.urandom(12)).decode("ascii")

    print(f"=== Spawning real Shadowsocks CVM in {args.region} ===")
    print(f"Session ID : {session_id}")
    print(f"Cipher     : {args.method}")
    print(f"Port       : {args.port}")
    print(f"Allow IPs  : {', '.join(allow_ips)}")

    launch_payload = {
        "action": "launch",
        "sessionId": session_id,
        "region": args.region,
        "secretId": secret_id,
        "secretKey": secret_key,
        "allowIps": allow_ips,
        "shadowsocks": {
            "port": args.port,
            "password": password,
            "method": args.method,
            "tag": f"VPN-{args.region}"
        }
    }

    launch_res = main_handler({"ClientContext": launch_payload}, None)
    if not launch_res.get("success"):
        print("Launch failed:", launch_res)
        sys.exit(1)

    instance_id = launch_res.get("instanceId")
    print(f"CVM Instance Created: {instance_id}")
    print(f"Security Group      : {launch_res.get('securityGroupId')} allow={launch_res.get('allowedIps')}")
    print("Waiting for instance to be RUNNING and assign public IP...")

    public_ip = None
    for attempt in range(1, 30):
        time.sleep(4)
        status_res = main_handler({
            "ClientContext": {
                "action": "status",
                "region": args.region,
                "instanceId": instance_id,
                "secretId": secret_id,
                "secretKey": secret_key
            }
        }, None)

        status = status_res.get("status")
        ip = status_res.get("publicIP")
        print(f"[{attempt}/30] State: {status}, IP: {ip or 'waiting...'}")

        if status == "RUNNING" and ip:
            public_ip = ip
            break

    if not public_ip:
        print("Timed out waiting for instance public IP.")
        print("Cleaning up instance...")
        main_handler({"ClientContext": {"action": "terminate", "region": args.region, "instanceId": instance_id, "secretId": secret_id, "secretKey": secret_key}}, None)
        sys.exit(1)

    user_info = f"{args.method}:{password}@{public_ip}:{args.port}"
    b64_info = base64.b64encode(user_info.encode("utf-8")).decode("utf-8")
    ss_uri = f"ss://{b64_info}#VPN-{args.region}"
    sub_url = f"http://{public_ip}:8389/sub"

    print("\n================ SUCCESS ================")
    print(f"Server IP        : {public_ip}")
    print(f"Shadowsocks Port : {args.port}")
    print(f"Password         : {password}")
    print(f"Method           : {args.method}")
    print(f"Shadowsocks URI  : {ss_uri}")
    print(f"Subscription URL : {sub_url}")
    print("=========================================\n")

    print("Verifying server bootstrap (waiting 20s for cloud-init)...")
    for check in range(1, 10):
        time.sleep(5)
        tcp_ok = test_tcp_port(public_ip, args.port, timeout=3)
        sub_ok = test_http_sub(sub_url, timeout=3)
        print(f"Check {check}: TCP Port {args.port}={tcp_ok}, Sub HTTP={sub_ok}")
        if tcp_ok and sub_ok:
            print("All services are UP and verified healthy!")
            break

    if not args.keep:
        input("\nPress ENTER when you want to teardown this test server...")
        print(f"Terminating instance {instance_id}...")
        term_res = main_handler({
            "ClientContext": {
                "action": "terminate",
                "region": args.region,
                "instanceId": instance_id,
                "secretId": secret_id,
                "secretKey": secret_key
            }
        }, None)
        print("Teardown result:", term_res)
        print("Cleanup verified.")
    else:
        print(f"\n[KEEP] Instance {instance_id} is running. Remember to terminate later:")
        print(f"venv/bin/python controller/spawn.py --region {args.region} --terminate {instance_id}")
        print("If your IP changes:")
        print(f"venv/bin/python controller/spawn.py --region {args.region} --add-ip {instance_id}")

if __name__ == "__main__":
    main()
