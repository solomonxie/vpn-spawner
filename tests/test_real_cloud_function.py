"""REAL PRODUCTION TEST of "Runs from: Cloud function": every step goes through the deployed SCF
controller (as the iOS app's controller mode does), using the app's vpn-spawner key, which may only
invoke that function. Creates a billed CVM, then destroys it."""
import base64
import json
import os
import sys
import time
import urllib.request

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from controller.app import PROTOCOLS, get_credential, get_client
from controller.ike_probe import probe as ike_probe
from controller.spawn import load_dotenv, current_public_ip
from proxy_client import exit_ip_via
from tencentcloud.scf.v20180416 import scf_client, models as scf_models
from tencentcloud.cvm.v20170312 import models as cvm_models

load_dotenv()
SECRET_ID = os.environ.get("TENCENTCLOUD_SECRET_ID")
SECRET_KEY = os.environ.get("TENCENTCLOUD_SECRET_KEY")
REGION = os.environ.get("TENCENTCLOUD_REGION", "ap-guangzhou")
FUNCTION = os.environ.get("VPN_SPAWNER_FUNCTION", "vpn-spawner-controller")
EXTRA_IP = "203.0.113.10"


def invoke(action, **kw):
    """Same request shape the app sends: ClientContext JSON, no credentials (the function uses its role)."""
    req = scf_models.InvokeRequest()
    req.FunctionName = FUNCTION
    req.Namespace = "default"
    req.InvocationType = "RequestResponse"
    req.ClientContext = json.dumps({"action": action, "region": REGION, **kw})
    result = scf_client.ScfClient(get_credential(SECRET_ID, SECRET_KEY), REGION).Invoke(req).Result
    assert not result.ErrMsg, f"{action} crashed in SCF: {result.ErrMsg}\n{result.Log[-2000:]}"
    print(f"[SCF] {action}: {result.Duration} ms, {int(result.MemUsage) // 2**20} MB")
    return json.loads(result.RetMsg)


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return resp.read()


@pytest.mark.skipif(not SECRET_ID or not SECRET_KEY, reason="Real production test requires Tencent credentials")
def test_cloud_function_lifecycle():
    my_ip = current_public_ip()
    session_id = f"test-scf-{int(time.time()) % 10000}"
    expiry = int(time.time()) + 20 * 60

    launch = invoke("launch", sessionId=session_id, allowIps=[my_ip], replaceExisting=False, protocols=PROTOCOLS,
                    expiryTimestamp=expiry, shadowsocks={
                        "port": 8388, "password": base64.b64encode(os.urandom(12)).decode(),
                        "method": "chacha20-ietf-poly1305", "tag": "VPN-SCF"})
    assert launch.get("success"), launch
    instance_id, sg_id = launch["instanceId"], launch["securityGroupId"]
    assert launch["allowedIps"] == [my_ip] and launch["protocols"] == PROTOCOLS and launch["terminateAt"]
    print(f"[TEST] {instance_id} {sg_id} {launch['instanceType']} self-destruct {launch['terminateAt']}")

    try:
        public_ip = None
        for _ in range(40):
            time.sleep(4)
            status = invoke("status", instanceId=instance_id)
            if status.get("status") == "RUNNING" and status.get("publicIP"):
                public_ip = status["publicIP"]
                break
        assert public_ip, "Timed out waiting for RUNNING"
        assert sorted(status["allowedIps"]) == sorted([my_ip, public_ip])

        health = {}
        for _ in range(60):
            time.sleep(5)
            try:
                health = json.loads(fetch(f"http://{public_ip}:8389/health"))
                if health.get("ready"):
                    break
            except Exception:
                pass
        if not health.get("ready"):
            import socket
            for port in (8389, 8388, 22):
                s = socket.socket()
                s.settimeout(4)
                print(f"[DIAG] tcp {port}: {s.connect_ex((public_ip, port))} (0=open, 61=refused, 35/60=timeout)")
                s.close()
        assert health.get("ready"), f"Node not ready: {health}"
        assert not health.get("unavailable"), f"Protocols unavailable on node: {health['unavailable']}"

        endpoints = json.loads(fetch(f"http://{public_ip}:8389/client.json"))["endpoints"]
        failures = {}
        for ep in endpoints:
            if ep["proto"] == "ikev2":
                continue
            seen, why = exit_ip_via(ep, public_ip)
            print(f"[TEST] {ep['proto']:14} exit {seen}")
            if seen != public_ip:
                failures[ep["proto"]] = seen or why
        assert not failures, failures
        assert ike_probe(public_ip) == "accepted"

        added = invoke("allow_ip", instanceId=instance_id, ip=EXTRA_IP)
        assert added.get("success") and EXTRA_IP in added["allowedIps"], added

        extended = invoke("extend", instanceId=instance_id, expiryTimestamp=expiry + 600)
        assert extended.get("success") and extended["terminateAt"] > launch["terminateAt"], extended

        found = invoke("find", sessionId=session_id)
        assert [i["instanceId"] for i in found["instances"]] == [instance_id], found

    finally:
        term = invoke("terminate", instanceId=instance_id, securityGroupId=sg_id)
        assert term.get("success") and term.get("securityGroupDeleted") is True, term

    req = cvm_models.DescribeInstancesRequest()
    req.InstanceIds = [instance_id]
    for attempt in range(3):  # CAM occasionally rejects a valid call transiently
        try:
            left = get_client(REGION, SECRET_ID, SECRET_KEY).DescribeInstances(req).InstanceSet or []
            break
        except Exception:
            if attempt == 2:
                raise
            time.sleep(5)
    assert all(i.InstanceState in ("TERMINATING", "SHUTDOWN") for i in left), [(i.InstanceId, i.InstanceState) for i in left]
    print("[TEST] Teardown via SCF verified")
