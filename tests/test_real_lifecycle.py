"""REAL PRODUCTION TEST: creates a billed CVM + security group, then destroys both."""
import os
import sys
import time
import base64
import urllib.request
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller.app import main_handler
from controller.spawn import load_dotenv, current_public_ip

load_dotenv()

SECRET_ID = os.environ.get("TENCENTCLOUD_SECRET_ID")
SECRET_KEY = os.environ.get("TENCENTCLOUD_SECRET_KEY")
REGION = os.environ.get("TENCENTCLOUD_REGION", "ap-guangzhou")
EXTRA_IP = "203.0.113.10"  # TEST-NET-3, never routable


def invoke(action, **kw):
    return main_handler({"ClientContext": {
        "action": action, "region": REGION, "secretId": SECRET_ID, "secretKey": SECRET_KEY, **kw,
    }}, None)


def fetch_sub(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Shadowrocket/1982"})
    with urllib.request.urlopen(req, timeout=4) as resp:
        return base64.b64decode(resp.read()).decode("utf-8")


@pytest.mark.skipif(not SECRET_ID or not SECRET_KEY, reason="Real production test requires TENCENTCLOUD_SECRET_ID and TENCENTCLOUD_SECRET_KEY")
def test_real_server_provisioning_and_teardown():
    my_ip = current_public_ip()
    session_id = f"test-ci-{int(time.time()) % 10000}"

    print(f"\n[TEST] Launching real CVM in {REGION}, allow={my_ip}")
    launch = invoke("launch", sessionId=session_id, allowIps=[my_ip], shadowsocks={
        "port": 8388,
        "password": base64.b64encode(os.urandom(12)).decode("ascii"),
        "method": "chacha20-ietf-poly1305",
        "tag": f"VPN-CI-{REGION}",
    })
    assert launch.get("success") is True, f"Launch failed: {launch}"
    instance_id = launch["instanceId"]
    sg_id = launch["securityGroupId"]
    assert instance_id and sg_id
    assert launch["allowedIps"] == [my_ip], "Firewall must admit only the caller's IP"
    print(f"[TEST] Instance {instance_id}, security group {sg_id}")

    try:
        public_ip = None
        for attempt in range(1, 30):
            time.sleep(4)
            status = invoke("status", instanceId=instance_id)
            print(f"[TEST] Poll {attempt}/30: {status.get('status')} {status.get('publicIP')}")
            if status.get("status") == "RUNNING" and status.get("publicIP"):
                public_ip = status["publicIP"]
                break
        assert public_ip, "Timed out waiting for instance public IP"

        sub_url = f"http://{public_ip}:8389/sub"
        feed = None
        for check in range(1, 25):
            time.sleep(5)
            try:
                feed = fetch_sub(sub_url)
                if "ss://" in feed:
                    print(f"[TEST] Subscription reachable from allowed IP on check {check}")
                    break
            except Exception as e:
                print(f"[TEST] Check {check}: {e}")
        assert feed and "ss://" in feed, "Subscription endpoint not reachable from allowed IP"

        added = invoke("allow_ip", instanceId=instance_id, ip=EXTRA_IP)
        assert added.get("success") is True, f"allow_ip failed: {added}"
        assert sorted(added["allowedIps"]) == sorted([my_ip, EXTRA_IP])

        again = invoke("allow_ip", instanceId=instance_id, ip=EXTRA_IP)
        assert sorted(again["allowedIps"]) == sorted([my_ip, EXTRA_IP]), "allow_ip must be idempotent"

    finally:
        print(f"[TEST] Teardown: terminating {instance_id} and {sg_id}...")
        term = invoke("terminate", instanceId=instance_id, securityGroupId=sg_id)
        assert term.get("success") is True, f"Teardown failed: {term}"
        assert term.get("securityGroupDeleted") is True, f"Security group {sg_id} left behind: {term}"
        print("[TEST] Teardown complete. All billable resources destroyed.")
