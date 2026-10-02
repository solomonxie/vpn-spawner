"""AWS vendor for the controller: same action contract as Tencent's main_handler.

Billing is bounded three ways, none needing the client:
  1. EventBridge Scheduler one-time schedule -> ec2:TerminateInstances at expiry (moved by extend)
  2. watchdog (Lambda "reap", every 10 min): terminates managed instances whose schedule is
     missing or overdue, in every offered region
  3. the node itself shuts down 15 min past its ExpiresAt tag (read via IMDS instance tags);
     InstanceInitiatedShutdownBehavior=terminate turns that into a termination
"""
import json
import os
import secrets
import time
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

try:
    import app as core
except ImportError:
    from controller import app as core

REGIONS = ["us-west-2", "us-east-1", "ca-central-1", "eu-central-1", "ap-northeast-1", "ap-southeast-1",
           "ap-east-1", "ap-east-2"]  # Hong Kong, Taipei: opt-in regions, enabled on the account
INSTANCE_TYPES = ["t3a.micro", "t3.micro"]  # 2 vCPU burst / 1 GiB: enough for sing-box + strongSwan
AMI_PARAM = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
NODE_NAME = "vpn-spawner-node"
MANAGED = {"Key": "ManagedBy", "Value": "VPNSpawner"}
SCHEDULE_PREFIX = "vpn-spawner-"
SCHEDULER_TARGET = "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances"
ALIVE = ("pending", "running", "stopping", "stopped")
STATE = {"pending": "PENDING", "running": "RUNNING", "stopping": "STOPPING", "stopped": "STOPPED",
         "shutting-down": "TERMINATING", "terminated": "SHUTDOWN"}
TIMERLESS_GRACE = timedelta(minutes=5)
OVERDUE_GRACE = timedelta(minutes=10)

_session = None


def session():
    global _session
    if _session is None:
        _session = boto3.session.Session()
    return _session


def ec2(region):
    return session().client("ec2", region_name=region)


def scheduler(region):
    return session().client("scheduler", region_name=region)


def ssm(region):
    return session().client("ssm", region_name=region)


def code(e):
    return e.response.get("Error", {}).get("Code", "") if isinstance(e, ClientError) else ""


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def tags_of(resource):
    return {t["Key"]: t["Value"] for t in resource.get("Tags", [])}


# --- schedules (cloud-side self-destruct) ---

def schedule_name(instance_id):
    return SCHEDULE_PREFIX + instance_id


def schedule_at(expires_at):
    """Scheduler takes at(...) in UTC without zone suffix; keep it a minute ahead of now."""
    at = max(expires_at, datetime.now(timezone.utc) + timedelta(minutes=1))
    return at.strftime("%Y-%m-%dT%H:%M:%S")


def put_schedule(sched, instance_id, expires_at, create):
    args = dict(
        Name=schedule_name(instance_id),
        ScheduleExpression=f"at({schedule_at(expires_at)})",
        ScheduleExpressionTimezone="UTC",
        FlexibleTimeWindow={"Mode": "OFF"},
        ActionAfterCompletion="DELETE",
        Target={"Arn": SCHEDULER_TARGET, "RoleArn": os.environ["SCHEDULER_ROLE_ARN"],
                "Input": json.dumps({"InstanceIds": [instance_id]})},
    )
    if create:
        sched.create_schedule(**args)
    else:
        sched.update_schedule(**args)


def get_schedule_time(sched, instance_id):
    """Pending terminate time, or None if no schedule exists."""
    try:
        expr = sched.get_schedule(Name=schedule_name(instance_id))["ScheduleExpression"]
    except ClientError as e:
        if code(e) == "ResourceNotFoundException":
            return None
        raise
    return datetime.strptime(expr[3:-1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def delete_schedule(sched, instance_id):
    try:
        sched.delete_schedule(Name=schedule_name(instance_id))
    except ClientError as e:
        if code(e) != "ResourceNotFoundException":
            raise


def set_expiry(region, instance_id, expires_at):
    """Moves the schedule (update keeps it in place: never a window without one) and the
    ExpiresAt tag the node's own shutdown check reads."""
    sched = scheduler(region)
    put_schedule(sched, instance_id, expires_at, create=get_schedule_time(sched, instance_id) is None)
    ec2(region).create_tags(Resources=[instance_id], Tags=[{"Key": "ExpiresAt", "Value": iso(expires_at)}])
    return iso(expires_at)


# --- instances ---

def managed_instances(client, extra_filters=()):
    filters = [{"Name": "tag:ManagedBy", "Values": [MANAGED["Value"]]},
               {"Name": "instance-state-name", "Values": list(ALIVE)}, *extra_filters]
    out = []
    for page in client.get_paginator("describe_instances").paginate(Filters=filters):
        for r in page["Reservations"]:
            out += r["Instances"]
    return out


def describe(client, instance_id):
    try:
        found = [i for r in client.describe_instances(InstanceIds=[instance_id])["Reservations"] for i in r["Instances"]]
    except ClientError as e:
        if code(e) == "InvalidInstanceID.NotFound":
            return None
        raise
    return found[0] if found else None


def terminate_instance(client, instance_id):
    """Idempotent: a missing or already-terminating instance counts as done."""
    try:
        client.terminate_instances(InstanceIds=[instance_id])
    except ClientError as e:
        if code(e) != "InvalidInstanceID.NotFound":
            raise
    return True


def replace_running_nodes(client, sched):
    """One node at a time per region."""
    alive = [i["InstanceId"] for i in managed_instances(client)]
    for instance_id in alive:
        terminate_instance(client, instance_id)
        delete_schedule(sched, instance_id)
    return alive


# --- security groups ---

def default_vpc(client):
    vpcs = client.describe_vpcs(Filters=[{"Name": "is-default", "Values": ["true"]}])["Vpcs"]
    if not vpcs:
        raise RuntimeError("No default VPC in this region")
    return vpcs[0]["VpcId"]


def create_firewall(client, session_id, ips):
    sg_id = client.create_security_group(
        GroupName=f"vpn-{session_id}-{secrets.token_hex(3)}",
        Description="VPNSpawner per-session allowlist",
        VpcId=default_vpc(client),
        TagSpecifications=[{"ResourceType": "security-group",
                            "Tags": [MANAGED, {"Key": "SessionId", "Value": session_id}]}],
    )["GroupId"]
    try:
        for ip in ips:
            allow_ip(client, sg_id, ip)
    except Exception:
        delete_firewall(client, sg_id, wait_seconds=0)
        raise
    return sg_id


def allowed_ips(client, sg_id):
    sg = client.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
    return [r["CidrIp"].removesuffix("/32") for p in sg["IpPermissions"] for r in p.get("IpRanges", [])]


def allow_ip(client, sg_id, ip):
    if ip not in allowed_ips(client, sg_id):
        client.authorize_security_group_ingress(GroupId=sg_id, IpPermissions=[{
            "IpProtocol": "-1", "IpRanges": [{"CidrIp": f"{ip}/32", "Description": "vpn-spawner allow"}]}])
    return allowed_ips(client, sg_id)


def is_managed_sg(client, sg_id):
    try:
        sg = client.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
    except ClientError as e:
        if code(e) == "InvalidGroup.NotFound":
            return False
        raise
    return tags_of(sg).get("ManagedBy") == MANAGED["Value"]


def delete_firewall(client, sg_id, wait_seconds=120):
    """Retries while the terminating instance still holds the group."""
    deadline = time.time() + wait_seconds
    while True:
        try:
            client.delete_security_group(GroupId=sg_id)
            return True
        except ClientError as e:
            if code(e) == "InvalidGroup.NotFound":
                return True
            if time.time() >= deadline:
                return False
            time.sleep(5)


def sweep_orphan_firewalls(client):
    groups = client.describe_security_groups(Filters=[{"Name": "tag:ManagedBy", "Values": [MANAGED["Value"]]}])
    for sg in groups["SecurityGroups"]:
        delete_firewall(client, sg["GroupId"], wait_seconds=0)


def instance_firewall(client, inst):
    for g in inst.get("SecurityGroups", []):
        if is_managed_sg(client, g["GroupId"]):
            return g["GroupId"]
    return None


# --- launch ---

def launch_instance(client, region, ami, sg_id, user_data, session_id, expires_at):
    tags = [MANAGED, {"Key": "SessionId", "Value": session_id}, {"Key": "Name", "Value": NODE_NAME},
            {"Key": "ExpiresAt", "Value": iso(expires_at)}]
    last = None
    for instance_type in INSTANCE_TYPES:
        try:
            return instance_type, client.run_instances(
                ImageId=ami, InstanceType=instance_type, MinCount=1, MaxCount=1,
                SecurityGroupIds=[sg_id], UserData=user_data,
                InstanceInitiatedShutdownBehavior="terminate",
                MetadataOptions={"HttpTokens": "required", "InstanceMetadataTags": "enabled"},
                TagSpecifications=[{"ResourceType": "instance", "Tags": tags},
                                   {"ResourceType": "volume", "Tags": [MANAGED, {"Key": "SessionId", "Value": session_id}]}],
            )["Instances"][0]["InstanceId"]
        except ClientError as e:
            last = e
            if code(e) not in ("Unsupported", "InsufficientInstanceCapacity", "InvalidParameterValue"):
                raise
    raise last


# --- watchdog ---

def reap_region(client, sched, now=None, timerless_grace=TIMERLESS_GRACE):
    now = now or datetime.now(timezone.utc)
    alive = managed_instances(client)
    reaped = {}
    for inst in alive:
        at = get_schedule_time(sched, inst["InstanceId"])
        if at is None and now - inst["LaunchTime"] >= timerless_grace:
            reaped[inst["InstanceId"]] = "no pending terminate schedule"
        elif at is not None and at < now - OVERDUE_GRACE:
            reaped[inst["InstanceId"]] = f"terminate schedule overdue since {at:%H:%M}Z"
    for instance_id in reaped:
        terminate_instance(client, instance_id)
        delete_schedule(sched, instance_id)
    try:
        sweep_orphan_firewalls(client)
    except Exception:
        pass
    return {"checked": [i["InstanceId"] for i in alive], "reaped": reaped}


# --- dispatch ---

def handle(req):
    action = req.get("action", "")
    region = req.get("region") or REGIONS[0]
    session_id = req.get("sessionId", "")
    client = ec2(region)

    if action == "launch":
        allow = req.get("allowIps") or []
        if not allow:
            return {"success": False, "message": "allowIps is required"}
        if region not in REGIONS:
            return {"success": False, "message": f"Unsupported AWS region {region}"}
        psk = req.get("ikev2Psk") or secrets.token_urlsafe(18)
        protocols = core.normalize_protocols(req.get("protocols"))
        user_data = core.gzip_user_data(core.render_bootstrap(req.get("shadowsocks", {}), psk, protocols))
        expires_at = core.expiry_from(req) + timedelta(minutes=0)
        ami = ssm(region).get_parameter(Name=AMI_PARAM)["Parameter"]["Value"]
        sched = scheduler(region)
        replaced = replace_running_nodes(client, sched) if req.get("replaceExisting", True) else []
        try:
            sweep_orphan_firewalls(client)
        except Exception:
            pass
        sg_id = create_firewall(client, session_id, allow)
        try:
            instance_type, instance_id = launch_instance(client, region, ami, sg_id, user_data, session_id, expires_at)
        except Exception:
            delete_firewall(client, sg_id, wait_seconds=0)
            raise
        try:
            put_schedule(sched, instance_id, expires_at, create=True)
        except Exception:
            terminate_instance(client, instance_id)  # never leave a node without its self-destruct
            raise
        return {"success": True, "vendor": "aws", "instanceId": instance_id, "securityGroupId": sg_id,
                "zone": region, "instanceType": instance_type, "allowedIps": allowed_ips(client, sg_id),
                "ikev2Psk": psk, "protocols": protocols, "replaced": replaced,
                "terminateAt": iso(expires_at), "status": "provisioning"}

    if action == "status":
        inst = describe(client, req.get("instanceId", ""))
        if not inst:
            return {"success": False, "message": "Instance not found"}
        ip = inst.get("PublicIpAddress")
        result = {"success": True, "instanceId": inst["InstanceId"], "status": STATE.get(inst["State"]["Name"], "UNKNOWN"),
                  "publicIP": ip}
        # Tunnelled traffic hairpinning back to the node arrives from its own public IP.
        if inst["State"]["Name"] == "running" and ip:
            sg_id = instance_firewall(client, inst)
            if sg_id:
                result["allowedIps"] = allow_ip(client, sg_id, ip)
        return result

    if action == "allow_ip":
        ip = req.get("ip", "")
        sg_id = req.get("securityGroupId")
        if not sg_id:
            inst = describe(client, req.get("instanceId", ""))
            sg_id = instance_firewall(client, inst) if inst else None
        if not ip or not sg_id or not is_managed_sg(client, sg_id):
            return {"success": False, "message": "ip and a VPNSpawner-managed instance/securityGroupId are required"}
        return {"success": True, "securityGroupId": sg_id, "allowedIps": allow_ip(client, sg_id, ip)}

    if action == "extend":
        instance_id = req.get("instanceId", "")
        return {"success": True, "instanceId": instance_id,
                "terminateAt": set_expiry(region, instance_id, core.expiry_from(req))}

    if action == "find":
        found = managed_instances(client, [{"Name": "tag:SessionId", "Values": [session_id]}])
        return {"success": True, "instances": [{
            "instanceId": i["InstanceId"], "status": STATE.get(i["State"]["Name"], "UNKNOWN"),
            "publicIP": i.get("PublicIpAddress"), "securityGroupIds": [g["GroupId"] for g in i.get("SecurityGroups", [])],
        } for i in found]}

    if action == "terminate":
        instance_id = req.get("instanceId", "")
        inst = describe(client, instance_id) if instance_id else None
        sg_id = req.get("securityGroupId") or (instance_firewall(client, inst) if inst else None)
        if instance_id:
            terminate_instance(client, instance_id)
            delete_schedule(scheduler(region), instance_id)
        sg_deleted = None
        if sg_id and is_managed_sg(client, sg_id):
            sg_deleted = delete_firewall(client, sg_id, wait_seconds=int(req.get("firewallWaitSeconds", 120)))
        return {"success": True, "status": "terminated", "securityGroupId": sg_id, "securityGroupDeleted": sg_deleted}

    if action == "reap":
        grace = timedelta(seconds=int(req.get("timerlessGraceSeconds", TIMERLESS_GRACE.total_seconds())))
        report = {}
        for r in req.get("regions") or REGIONS:
            try:
                report[r] = reap_region(ec2(r), scheduler(r), timerless_grace=grace)
            except Exception as e:
                report[r] = {"error": str(e)[:200]}
        return {"success": True, "regions": report}

    return {"success": False, "message": f"Unknown action: {action}"}
