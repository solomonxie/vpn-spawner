import os
import sys
from types import SimpleNamespace as NS

from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller import app


class FakeCvm:
    """Returns every account timer regardless of filter, like the real API once did."""

    def __init__(self):
        self.timers = [
            NS(InstanceId="ins-mine", TimerAction="TerminateInstances", Status="UNDO", ActionTimerId="t-mine"),
            NS(InstanceId="ins-other", TimerAction="TerminateInstances", Status="UNDO", ActionTimerId="t-other"),
        ]
        self.imported = []

    def DescribeInstancesActionTimer(self, req):
        return NS(ActionTimers=list(self.timers))

    def DeleteInstancesActionTimer(self, req):
        self.timers = [t for t in self.timers if t.ActionTimerId not in req.ActionTimerIds]

    def ImportInstancesActionTimer(self, req):
        self.imported.append((req.InstanceIds, req.ActionTimer.ActionTime))


def test_reschedule_never_touches_other_instances_timers():
    cvm = FakeCvm()
    app.reschedule_terminate(cvm, "ins-mine", app.expiry_from({"durationMinutes": 30}))
    assert [t.InstanceId for t in cvm.timers] == ["ins-other"]
    assert cvm.imported and cvm.imported[0][0] == ["ins-mine"]


def test_timer_never_sooner_than_tencent_minimum():
    from datetime import datetime, timezone
    soon = app.timer_time(datetime.now(timezone.utc))
    assert soon > datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeNodes:
    def __init__(self, states):
        self.instances = [NS(InstanceId=f"ins-{i}", InstanceState=s) for i, s in enumerate(states)]
        self.terminated = []

    def DescribeInstances(self, req):
        return NS(InstanceSet=self.instances)

    def TerminateInstances(self, req):
        self.terminated += req.InstanceIds


def test_launch_replaces_only_live_nodes():
    cvm = FakeNodes(["RUNNING", "PENDING", "TERMINATING", "SHUTDOWN"])
    assert app.replace_running_nodes(cvm) == ["ins-0", "ins-1"]
    assert cvm.terminated == ["ins-0", "ins-1"]


def test_no_terminate_call_when_nothing_running():
    cvm = FakeNodes(["SHUTDOWN"])
    assert app.replace_running_nodes(cvm) == [] and cvm.terminated == []


class FakeWatch:
    def __init__(self, instances, timers):
        self.instances, self.timers, self.terminated, self.calls = instances, timers, [], []

    def DescribeInstances(self, req):
        return NS(InstanceSet=self.instances)

    def DescribeInstancesActionTimer(self, req):
        return NS(ActionTimers=self.timers)

    def ImportInstancesActionTimer(self, req):
        self.calls.append("import")

    def DeleteInstancesActionTimer(self, req):
        self.calls.append("delete")

    def TerminateInstances(self, req):
        self.terminated += req.InstanceIds


class NoFirewall:
    def DescribeSecurityGroups(self, req):
        return NS(SecurityGroupSet=[])


def _inst(i, created):
    return NS(InstanceId=i, InstanceState="RUNNING", CreatedTime=created)


def _timer(i, at, status="UNDO"):
    return NS(InstanceId=i, TimerAction="TerminateInstances", Status=status, ActionTime=at, ActionTimerId=f"t-{i}")


def test_reschedule_deletes_then_imports():
    cvm = FakeWatch([], [_timer("ins-a", "2026-10-02T05:00:00Z")])
    app.reschedule_terminate(cvm, "ins-a", app.expiry_from({"durationMinutes": 30}))
    assert cvm.calls == ["delete", "import"]


def test_reschedule_restores_old_timer_when_import_keeps_failing(monkeypatch):
    monkeypatch.setattr(app.time, "sleep", lambda s: None)
    cvm = FakeWatch([], [_timer("ins-a", "2099-01-01T00:00:00Z")])
    imported = []

    def flaky_import(req):
        imported.append(req.ActionTimer.ActionTime)
        if len(imported) <= 3:
            raise TencentCloudSDKException("InternalError", "x")

    cvm.ImportInstancesActionTimer = flaky_import
    try:
        app.reschedule_terminate(cvm, "ins-a", app.expiry_from({"durationMinutes": 30}))
    except TencentCloudSDKException:
        pass
    assert len(imported) == 4 and imported[-1] == "2099-01-01T00:00:00Z"


def test_watchdog_reaps_timerless_failed_and_overdue_only():
    from datetime import datetime, timezone
    now = datetime(2026, 10, 2, 6, 0, tzinfo=timezone.utc)
    cvm = FakeWatch(
        [_inst("ins-ok", "2026-10-02T05:00:00Z"), _inst("ins-notimer", "2026-10-02T05:00:00Z"),
         _inst("ins-young", "2026-10-02T05:58:00Z"), _inst("ins-overdue", "2026-10-02T04:00:00Z"),
         _inst("ins-failed", "2026-10-02T05:00:00Z")],
        [_timer("ins-ok", "2026-10-02T06:20:00Z"), _timer("ins-overdue", "2026-10-02T05:30:00Z"),
         _timer("ins-failed", "2026-10-02T05:40:00Z", status="FAILED")],
    )
    report = app.reap_region(cvm, NoFirewall(), now=now)
    assert sorted(report["reaped"]) == ["ins-failed", "ins-notimer", "ins-overdue"]
    assert sorted(cvm.terminated) == ["ins-failed", "ins-notimer", "ins-overdue"]


def test_timer_trigger_event_runs_reap(monkeypatch):
    seen = {}
    monkeypatch.setattr(app, "reap_region", lambda c, f, now=None, timerless_grace=None: seen.setdefault("ran", True) and {"reaped": {}})
    out = app.main_handler({"Type": "Timer", "TriggerName": "watchdog"}, None)
    assert out["success"] and seen["ran"] and set(out["regions"]) == set(app.WATCH_REGIONS)


class FlakyTerminate:
    """TerminateInstances fails with the given codes first; DescribeInstances reports `state`."""

    def __init__(self, codes, state="RUNNING"):
        self.codes, self.state, self.calls = list(codes), state, 0

    def TerminateInstances(self, req):
        self.calls += 1
        if self.codes:
            raise TencentCloudSDKException(self.codes.pop(0), "x")

    def DescribeInstances(self, req):
        return NS(InstanceSet=[NS(InstanceState=self.state)] if self.state else [])


def test_terminate_waits_out_operation_in_progress(monkeypatch):
    monkeypatch.setattr(app.time, "sleep", lambda s: None)
    cvm = FlakyTerminate(["OperationDenied.InstanceOperationInProgress"] * 2, state="PENDING")
    assert app.terminate_instance(cvm, "ins-1") and cvm.calls == 3


def test_terminate_already_terminating_is_done():
    cvm = FlakyTerminate(["OperationDenied.InstanceOperationInProgress"], state="TERMINATING")
    assert app.terminate_instance(cvm, "ins-1") and cvm.calls == 1


def test_terminate_missing_instance_is_done():
    cvm = FlakyTerminate(["InvalidInstanceId.NotFound"], state=None)
    assert app.terminate_instance(cvm, "ins-1")
