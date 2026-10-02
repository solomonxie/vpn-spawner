"""REAL PRODUCTION TEST of the watchdog backstop: a node whose Tencent-side terminate timer
has vanished must be terminated by the deployed controller's reap action."""
import base64
import os
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_real_cloud_function import REGION, SECRET_ID, SECRET_KEY, invoke
from controller.app import get_client, terminate_timers
from controller.spawn import current_public_ip
from tencentcloud.cvm.v20170312 import models as cvm_models


@pytest.mark.skipif(not SECRET_ID or not SECRET_KEY, reason="Real production test requires Tencent credentials")
def test_watchdog_reaps_node_without_timer():
    launch = invoke("launch", sessionId=f"test-wd-{int(time.time()) % 10000}", allowIps=[current_public_ip()],
                    replaceExisting=False, protocols=["shadowsocks"], durationMinutes=20,
                    shadowsocks={"password": base64.b64encode(os.urandom(12)).decode()})
    instance_id, sg_id = launch["instanceId"], launch["securityGroupId"]
    cvm = get_client(REGION, SECRET_ID, SECRET_KEY)
    try:
        for _ in range(20):
            if terminate_timers(cvm, instance_id):
                break
            time.sleep(3)
        report = invoke("reap", regions=[REGION], timerlessGraceSeconds=0)["regions"][REGION]
        assert instance_id in report["checked"] and instance_id not in report["reaped"], report
        print(f"[TEST] healthy node spared: {report}")

        timers = [t.ActionTimerId for t in terminate_timers(cvm, instance_id)]
        req = cvm_models.DeleteInstancesActionTimerRequest()
        req.ActionTimerIds = timers
        cvm.DeleteInstancesActionTimer(req)
        print(f"[TEST] simulated lost timer: deleted {timers}")

        report = invoke("reap", regions=[REGION], timerlessGraceSeconds=0)["regions"][REGION]
        assert report["reaped"].get(instance_id) == "no pending terminate timer", report
        print(f"[TEST] watchdog reaped: {report['reaped']}")
    finally:
        term = invoke("terminate", instanceId=instance_id, securityGroupId=sg_id)
        assert term.get("success") and term.get("securityGroupDeleted") is True, term
