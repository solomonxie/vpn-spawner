import os
import sys
import time
import base64
import socket
import urllib.request
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller.app import main_handler

def load_env():
    env_file = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if os.path.exists(env_file):
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip("\"'"))

load_env()

SECRET_ID = os.environ.get("TENCENTCLOUD_SECRET_ID")
SECRET_KEY = os.environ.get("TENCENTCLOUD_SECRET_KEY")
REGION = os.environ.get("TENCENTCLOUD_REGION", "ap-guangzhou")

@pytest.mark.skipif(not SECRET_ID or not SECRET_KEY, reason="Real production test requires TENCENTCLOUD_SECRET_ID and TENCENTCLOUD_SECRET_KEY")
def test_real_server_provisioning_and_teardown():
    session_id = f"test-ci-{int(time.time()) % 10000}"
    port = 8388
    password = base64.b64encode(os.urandom(12)).decode("ascii")
    cipher = "chacha20-ietf-poly1305"

    launch_payload = {
        "action": "launch",
        "sessionId": session_id,
        "region": REGION,
        "secretId": SECRET_ID,
        "secretKey": SECRET_KEY,
        "shadowsocks": {
            "port": port,
            "password": password,
            "method": cipher,
            "tag": f"VPN-CI-{REGION}"
        }
    }

    print(f"\n[TEST] Launching real CVM instance in {REGION}...")
    launch_res = main_handler({"ClientContext": launch_payload}, None)
    assert launch_res.get("success") is True, f"Launch failed: {launch_res}"
    instance_id = launch_res.get("instanceId")
    assert instance_id is not None, "No instanceId returned"
    print(f"[TEST] Instance created: {instance_id}")

    try:
        public_ip = None
        for attempt in range(1, 30):
            time.sleep(4)
            status_res = main_handler({
                "ClientContext": {
                    "action": "status",
                    "region": REGION,
                    "instanceId": instance_id,
                    "secretId": SECRET_ID,
                    "secretKey": SECRET_KEY
                }
            }, None)
            status = status_res.get("status")
            ip = status_res.get("publicIP")
            print(f"[TEST] Poll {attempt}/30: State={status}, IP={ip}")
            if status == "RUNNING" and ip:
                public_ip = ip
                break

        assert public_ip is not None, "Timed out waiting for instance public IP"

        sub_url = f"http://{public_ip}:8389/sub"
        print(f"[TEST] Server ready: IP={public_ip}, SubURL={sub_url}")

        # Verify bootstrap & subscription endpoint
        sub_healthy = False
        for check in range(1, 12):
            time.sleep(5)
            try:
                req = urllib.request.Request(sub_url, headers={"User-Agent": "Shadowrocket/1982"})
                with urllib.request.urlopen(req, timeout=4) as resp:
                    if resp.status == 200:
                        content = resp.read().decode("utf-8")
                        decoded = base64.b64decode(content).decode("utf-8")
                        if "ss://" in decoded:
                            sub_healthy = True
                            print(f"[TEST] Verified subscription endpoint on attempt {check}!")
                            break
            except Exception as e:
                print(f"[TEST] Check {check} waiting for subscription service: {e}")

        assert sub_healthy is True, "Subscription endpoint did not return valid ss:// feed within timeout"

    finally:
        print(f"[TEST] Teardown: Terminating instance {instance_id}...")
        term_res = main_handler({
            "ClientContext": {
                "action": "terminate",
                "region": REGION,
                "instanceId": instance_id,
                "secretId": SECRET_ID,
                "secretKey": SECRET_KEY
            }
        }, None)
        assert term_res.get("success") is True, f"Teardown failed: {term_res}"
        print("[TEST] Teardown complete. All billable resources destroyed.")
