import os
import sys
from datetime import datetime, timedelta, timezone

import pytest
from botocore.exceptions import ClientError

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller import aws_backend as aws

NOW = datetime(2026, 10, 2, 6, 0, tzinfo=timezone.utc)


def err(code):
    return ClientError({"Error": {"Code": code, "Message": code}}, "op")


class FakeEC2:
    def __init__(self, instances=(), terminate_error=None):
        self.instances = list(instances)
        self.terminated, self.tags = [], []
        self.terminate_error = terminate_error

    def get_paginator(self, name):
        ec2 = self

        class P:
            def paginate(self, Filters):
                return [{"Reservations": [{"Instances": ec2.instances}]}]
        return P()

    def terminate_instances(self, InstanceIds):
        if self.terminate_error:
            raise err(self.terminate_error)
        self.terminated += InstanceIds

    def describe_security_groups(self, **kw):
        return {"SecurityGroups": []}

    def create_tags(self, Resources, Tags):
        self.tags.append((Resources, Tags))


class FakeScheduler:
    def __init__(self, schedules=None):
        self.schedules = dict(schedules or {})
        self.calls = []

    def get_schedule(self, Name):
        if Name not in self.schedules:
            raise err("ResourceNotFoundException")
        return {"ScheduleExpression": f"at({self.schedules[Name]:%Y-%m-%dT%H:%M:%S})"}

    def create_schedule(self, **kw):
        self.calls.append("create")
        self.schedules[kw["Name"]] = datetime.strptime(kw["ScheduleExpression"][3:-1], "%Y-%m-%dT%H:%M:%S")

    def update_schedule(self, **kw):
        self.calls.append("update")
        self.schedules[kw["Name"]] = datetime.strptime(kw["ScheduleExpression"][3:-1], "%Y-%m-%dT%H:%M:%S")

    def delete_schedule(self, Name):
        self.calls.append("delete")
        if Name not in self.schedules:
            raise err("ResourceNotFoundException")
        del self.schedules[Name]


def inst(i, launched):
    return {"InstanceId": i, "LaunchTime": launched, "State": {"Name": "running"}}


def test_watchdog_reaps_missing_and_overdue_schedules_only():
    ec2 = FakeEC2([inst("i-ok", NOW - timedelta(hours=1)), inst("i-none", NOW - timedelta(hours=1)),
                   inst("i-young", NOW - timedelta(minutes=2)), inst("i-overdue", NOW - timedelta(hours=2))])
    sched = FakeScheduler({"vpn-spawner-i-ok": NOW + timedelta(minutes=20),
                           "vpn-spawner-i-overdue": NOW - timedelta(minutes=30)})
    report = aws.reap_region(ec2, sched, now=NOW)
    assert sorted(report["reaped"]) == ["i-none", "i-overdue"]
    assert sorted(ec2.terminated) == ["i-none", "i-overdue"]
    assert "vpn-spawner-i-ok" in sched.schedules


def test_terminate_missing_instance_is_done():
    assert aws.terminate_instance(FakeEC2(terminate_error="InvalidInstanceID.NotFound"), "i-gone")


def test_terminate_other_errors_surface():
    with pytest.raises(ClientError):
        aws.terminate_instance(FakeEC2(terminate_error="UnauthorizedOperation"), "i-x")


def test_extend_updates_schedule_in_place(monkeypatch):
    monkeypatch.setenv("SCHEDULER_ROLE_ARN", "arn:aws:iam::1:role/x")
    sched = FakeScheduler({"vpn-spawner-i-a": NOW})
    ec2 = FakeEC2()
    monkeypatch.setattr(aws, "scheduler", lambda r: sched)
    monkeypatch.setattr(aws, "ec2", lambda r: ec2)
    new = datetime.now(timezone.utc) + timedelta(minutes=30)
    aws.set_expiry("us-west-2", "i-a", new)
    assert sched.calls == ["update"], "never delete-then-create: no window without a schedule"
    assert ec2.tags[0][1] == [{"Key": "ExpiresAt", "Value": aws.iso(new)}]


def test_extend_recreates_a_missing_schedule(monkeypatch):
    monkeypatch.setenv("SCHEDULER_ROLE_ARN", "arn:aws:iam::1:role/x")
    sched = FakeScheduler()
    monkeypatch.setattr(aws, "scheduler", lambda r: sched)
    monkeypatch.setattr(aws, "ec2", lambda r: FakeEC2())
    aws.set_expiry("us-west-2", "i-a", datetime.now(timezone.utc) + timedelta(minutes=30))
    assert sched.calls == ["create"]


def test_delete_schedule_tolerates_missing():
    aws.delete_schedule(FakeScheduler(), "i-none")


def test_vendor_dispatch(monkeypatch):
    from controller import app
    monkeypatch.setattr(aws, "handle", lambda req: {"routed": req["action"]})
    assert app.main_handler({"vendor": "aws", "action": "find"}, None) == {"routed": "find"}
