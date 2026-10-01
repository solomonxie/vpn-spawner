import os
import sys
from types import SimpleNamespace as NS

from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller import firewall


class FakeVpc:
    def __init__(self, busy_deletes=0):
        self.ingress, self.egress, self.tags = [], [], []
        self.busy_deletes = busy_deletes
        self.deleted = False

    def CreateSecurityGroup(self, req):
        self.tags = [NS(Key=t.Key, Value=t.Value) for t in req.Tags]
        return NS(SecurityGroup=NS(SecurityGroupId="sg-1"))

    def CreateSecurityGroupPolicies(self, req):
        ps = req.SecurityGroupPolicySet
        self.ingress += [NS(CidrBlock=p.CidrBlock, Action=p.Action) for p in ps.Ingress or []]
        self.egress += [NS(CidrBlock=p.CidrBlock, Action=p.Action) for p in ps.Egress or []]

    def DescribeSecurityGroupPolicies(self, req):
        return NS(SecurityGroupPolicySet=NS(Ingress=self.ingress))

    def DescribeSecurityGroups(self, req):
        return NS(SecurityGroupSet=[NS(SecurityGroupId="sg-1", TagSet=self.tags)])

    def DeleteSecurityGroup(self, req):
        if self.busy_deletes:
            self.busy_deletes -= 1
            raise TencentCloudSDKException("ResourceInUse", "bound to instance")
        self.deleted = True


def test_create_admits_only_given_ips_and_opens_egress():
    vpc = FakeVpc()
    sg = firewall.create(vpc, "s1", ["1.2.3.4"])
    assert firewall.allowed_ips(vpc, sg) == ["1.2.3.4"]
    assert [p.CidrBlock for p in vpc.egress] == ["0.0.0.0/0"]
    assert firewall.is_managed(vpc, sg)


def test_allow_ip_is_idempotent():
    vpc = FakeVpc()
    sg = firewall.create(vpc, "s1", ["1.2.3.4"])
    firewall.allow_ip(vpc, sg, "5.6.7.8")
    assert firewall.allow_ip(vpc, sg, "5.6.7.8") == ["1.2.3.4", "5.6.7.8"]


def test_delete_retries_until_instance_releases(monkeypatch):
    monkeypatch.setattr(firewall.time, "sleep", lambda s: None)
    vpc = FakeVpc(busy_deletes=2)
    assert firewall.delete(vpc, "sg-1", wait_seconds=60) is True
    assert vpc.deleted


def test_delete_gives_up_without_wait():
    vpc = FakeVpc(busy_deletes=1)
    assert firewall.delete(vpc, "sg-1", wait_seconds=0) is False


def test_unmanaged_group_not_recognised():
    vpc = FakeVpc()
    assert not firewall.is_managed(vpc, "sg-1")
