import json
import time
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.vpc.v20170312 import vpc_client, models

MANAGED_TAG = {"Key": "ManagedBy", "Value": "VPNSpawner"}


def get_client(cred, region):
    return vpc_client.VpcClient(cred, region)


def _req(cls, **params):
    r = cls()
    r.from_json_string(json.dumps(params))
    return r


def _ingress(ip):
    return {"Protocol": "ALL", "Port": "ALL", "CidrBlock": f"{ip}/32", "Action": "ACCEPT",
            "PolicyDescription": "vpn-spawner allow"}


def create(client, session_id, ips):
    resp = client.CreateSecurityGroup(_req(
        models.CreateSecurityGroupRequest,
        GroupName=f"vpn-{session_id}",
        GroupDescription="VPNSpawner per-session allowlist",
        Tags=[MANAGED_TAG, {"Key": "SessionId", "Value": session_id}],
    ))
    sg_id = resp.SecurityGroup.SecurityGroupId
    try:
        client.CreateSecurityGroupPolicies(_req(
            models.CreateSecurityGroupPoliciesRequest,
            SecurityGroupId=sg_id,
            SecurityGroupPolicySet={"Egress": [{"Protocol": "ALL", "Port": "ALL", "CidrBlock": "0.0.0.0/0", "Action": "ACCEPT"}]},
        ))
        for ip in ips:
            allow_ip(client, sg_id, ip)
    except Exception:
        delete(client, sg_id, wait_seconds=0)
        raise
    return sg_id


def allowed_ips(client, sg_id):
    resp = client.DescribeSecurityGroupPolicies(_req(models.DescribeSecurityGroupPoliciesRequest, SecurityGroupId=sg_id))
    return [p.CidrBlock.removesuffix("/32") for p in resp.SecurityGroupPolicySet.Ingress or []
            if p.Action == "ACCEPT" and p.CidrBlock]


def allow_ip(client, sg_id, ip):
    if ip not in allowed_ips(client, sg_id):
        client.CreateSecurityGroupPolicies(_req(
            models.CreateSecurityGroupPoliciesRequest,
            SecurityGroupId=sg_id,
            SecurityGroupPolicySet={"Ingress": [_ingress(ip)]},
        ))
    return allowed_ips(client, sg_id)


def exists(client, sg_id):
    try:
        resp = client.DescribeSecurityGroups(_req(models.DescribeSecurityGroupsRequest, SecurityGroupIds=[sg_id]))
    except TencentCloudSDKException as e:
        if "NotFound" in (e.code or ""):
            return False
        raise
    return bool(resp.SecurityGroupSet)


def is_managed(client, sg_id):
    """False for groups that don't exist (already deleted) as well as unmanaged ones."""
    try:
        resp = client.DescribeSecurityGroups(_req(models.DescribeSecurityGroupsRequest, SecurityGroupIds=[sg_id]))
    except TencentCloudSDKException as e:
        if "NotFound" in (e.code or ""):
            return False
        raise
    return any(
        t.Key == MANAGED_TAG["Key"] and t.Value == MANAGED_TAG["Value"]
        for sg in resp.SecurityGroupSet for t in (sg.TagSet or [])
    )


def delete(client, sg_id, wait_seconds=120):
    """Retries while the terminating instance still holds the group."""
    deadline = time.time() + wait_seconds
    while True:
        try:
            client.DeleteSecurityGroup(_req(models.DeleteSecurityGroupRequest, SecurityGroupId=sg_id))
            return True
        except TencentCloudSDKException as e:
            if "NotFound" in (e.code or ""):
                return True
            if time.time() >= deadline:
                return False
            time.sleep(5)


def sweep_orphans(client):
    """Best-effort delete of managed groups no longer bound to any instance."""
    resp = client.DescribeSecurityGroups(_req(
        models.DescribeSecurityGroupsRequest,
        Filters=[{"Name": "tag:ManagedBy", "Values": [MANAGED_TAG["Value"]]}],
        Limit="100",
    ))
    for sg in resp.SecurityGroupSet or []:
        delete(client, sg.SecurityGroupId, wait_seconds=0)
