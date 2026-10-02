import os
import sys
from types import SimpleNamespace as NS

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
