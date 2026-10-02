"""REAL PRODUCTION TESTS on AWS: everything goes through the deployed Lambda with the iOS app's
invoke-only key (~/.vpn-spawner/aws-vpn-spawner-keys.txt), exactly as the app will. Creates
billed EC2 instances, then destroys and verifies them. Direct boto3 checks use AWS_PROFILE."""
import base64
import json
import os
import sys
import time
import urllib.request

import boto3
import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from controller.app import PROTOCOLS
from controller.ike_probe import probe as ike_probe
from controller.spawn import current_public_ip
from proxy_client import exit_ip_via

KEY_FILE = os.path.expanduser("~/.vpn-spawner/aws-vpn-spawner-keys.txt")
REGION = os.environ.get("VPN_SPAWNER_AWS_REGION", "us-west-2")
EXTRA_IP = "203.0.113.10"


def app_key():
    kv = {}
    for line in open(KEY_FILE):
        if ":" in line:
            k, v = line.split(":", 1)
            kv[k.strip()] = v.strip()
    return kv


def invoke(action, **kw):
    kv = app_key()
    lam = boto3.client("lambda", region_name=kv["region"], aws_access_key_id=kv["access_key_id"],
                       aws_secret_access_key=kv["secret_access_key"])
    started = time.time()
    resp = lam.invoke(FunctionName=kv["function"],
                      Payload=json.dumps({"vendor": "aws", "action": action, "region": REGION, **kw}))
    body = json.loads(resp["Payload"].read())
    assert not resp.get("FunctionError"), f"{action} crashed in Lambda: {body}"
    print(f"[Lambda] {action}: {int((time.time() - started) * 1000)} ms")
    return body


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return resp.read()


def admin_ec2():
    return boto3.session.Session(profile_name=os.environ.get("AWS_PROFILE", "prod")).client("ec2", region_name=REGION)


def admin_scheduler():
    return boto3.session.Session(profile_name=os.environ.get("AWS_PROFILE", "prod")).client("scheduler", region_name=REGION)


def assert_gone(instance_id, sg_id):
    for _ in range(30):
        state = admin_ec2().describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]["State"]["Name"]
        if state in ("shutting-down", "terminated"):
            break
        time.sleep(5)
    assert state in ("shutting-down", "terminated"), state
    groups = admin_ec2().describe_security_groups(Filters=[{"Name": "group-id", "Values": [sg_id]}])["SecurityGroups"]
    assert not groups, f"security group {sg_id} left behind"


def launch(**kw):
    return invoke("launch", sessionId=f"test-aws-{int(time.time()) % 10000}", allowIps=[current_public_ip()],
                  replaceExisting=False, durationMinutes=20,
                  shadowsocks={"password": base64.b64encode(os.urandom(12)).decode(), "tag": "VPN-AWS"}, **kw)


needs_key = pytest.mark.skipif(not os.path.exists(KEY_FILE), reason="needs the AWS app key file")


@needs_key
def test_aws_lifecycle_through_lambda():
    my_ip = current_public_ip()
    started = launch(protocols=PROTOCOLS)
    assert started.get("success"), started
    instance_id, sg_id = started["instanceId"], started["securityGroupId"]
    print(f"[TEST] {instance_id} {sg_id} {started['instanceType']} self-destruct {started['terminateAt']}")
    try:
        sched = admin_scheduler().get_schedule(Name=f"vpn-spawner-{instance_id}")
        assert sched["Target"]["Arn"].endswith("ec2:terminateInstances") and instance_id in sched["Target"]["Input"]

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
        for _ in range(72):
            time.sleep(5)
            try:
                health = json.loads(fetch(f"http://{public_ip}:8389/health"))
                if health.get("ready") or health.get("stage") == "failed":
                    break
            except Exception:
                pass
        print(f"[TEST] health: {health}")
        assert health.get("ready"), f"Node not ready: {health}"
        assert not health.get("unavailable"), health

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

        extended = invoke("extend", instanceId=instance_id, durationMinutes=40)
        assert extended.get("success") and extended["terminateAt"] > started["terminateAt"], extended
        tags = {t["Key"]: t["Value"] for t in admin_ec2().describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]["Tags"]}
        assert tags["ExpiresAt"] == extended["terminateAt"] and tags["Name"] == "vpn-spawner-node"

        found = invoke("find", sessionId=tags["SessionId"])
        assert [i["instanceId"] for i in found["instances"]] == [instance_id], found
    finally:
        term = invoke("terminate", instanceId=instance_id, securityGroupId=sg_id)
        assert term.get("success") and term.get("securityGroupDeleted") is True, term
    assert_gone(instance_id, sg_id)
    sched = admin_scheduler()
    with pytest.raises(sched.exceptions.ResourceNotFoundException):
        sched.get_schedule(Name=f"vpn-spawner-{instance_id}")
    print("[TEST] AWS teardown verified: instance, security group and schedule gone")


@needs_key
def test_aws_watchdog_reaps_node_without_schedule():
    started = launch(protocols=["shadowsocks"])
    instance_id, sg_id = started["instanceId"], started["securityGroupId"]
    try:
        report = invoke("reap", regions=[REGION], timerlessGraceSeconds=0)["regions"][REGION]
        assert instance_id in report["checked"] and instance_id not in report["reaped"], report
        print(f"[TEST] healthy node spared: {report}")

        admin_scheduler().delete_schedule(Name=f"vpn-spawner-{instance_id}")
        print("[TEST] simulated lost schedule")

        report = invoke("reap", regions=[REGION], timerlessGraceSeconds=0)["regions"][REGION]
        assert report["reaped"].get(instance_id) == "no pending terminate schedule", report
        print(f"[TEST] watchdog reaped: {report['reaped']}")
    finally:
        term = invoke("terminate", instanceId=instance_id, securityGroupId=sg_id)
        assert term.get("success") and term.get("securityGroupDeleted") is True, term
    assert_gone(instance_id, sg_id)
