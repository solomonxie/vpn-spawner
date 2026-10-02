import json
import os
import re
import base64
import gzip
import secrets
import time
from datetime import datetime, timedelta, timezone
from tencentcloud.common import credential
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.cvm.v20170312 import cvm_client, models

try:
    import firewall
except ImportError:
    from controller import firewall

def get_credential(secret_id=None, secret_key=None):
    if secret_id and secret_key:
        return credential.Credential(secret_id, secret_key)
    # On SCF the execution role's temporary key arrives under these names (no underscore before ID/KEY).
    if os.environ.get("TENCENTCLOUD_SESSIONTOKEN"):
        return credential.Credential(os.environ["TENCENTCLOUD_SECRETID"], os.environ["TENCENTCLOUD_SECRETKEY"],
                                     os.environ["TENCENTCLOUD_SESSIONTOKEN"])
    s_id = os.environ.get("TENCENTCLOUD_SECRET_ID")
    s_key = os.environ.get("TENCENTCLOUD_SECRET_KEY")
    if s_id and s_key:
        return credential.Credential(s_id, s_key)
    return credential.EnvironmentVariableCredential().get_credential()

def get_client(region, secret_id=None, secret_key=None):
    return cvm_client.CvmClient(get_credential(secret_id, secret_key), region)

def instance_firewall(client, fw_client, instance_id):
    req = models.DescribeInstancesRequest()
    req.InstanceIds = [instance_id]
    resp = client.DescribeInstances(req)
    if not resp.InstanceSet:
        return None
    for sg_id in resp.InstanceSet[0].SecurityGroupIds or []:
        if firewall.is_managed(fw_client, sg_id):
            return sg_id
    return None

def is_small_x86(q):
    # The Ubuntu image is x86_64; ARM families (Ampere, Kunpeng, Yitian) can't boot it.
    return any(v in (q.CpuType or "") for v in ("Intel", "AMD")) and 1 <= q.Cpu <= 2 and q.Memory >= 1

def resolve_placement(client, region):
    """Cheapest small x86 (zone, instance type) currently on sale, hourly billing."""
    req = models.DescribeZoneInstanceConfigInfosRequest()
    req.from_json_string(json.dumps({"Filters": [
        {"Name": "instance-charge-type", "Values": ["POSTPAID_BY_HOUR"]},
    ]}))
    on_sale = [q for q in client.DescribeZoneInstanceConfigInfos(req).InstanceTypeQuotaSet
               if q.Status == "SELL" and q.Price and q.Price.UnitPrice and is_small_x86(q)]
    if not on_sale:
        raise RuntimeError(f"No small x86 instance type on sale in {region}")
    best = min(on_sale, key=lambda q: (q.Price.UnitPrice, q.Cpu, q.Memory, q.InstanceType))
    return best.Zone, best.InstanceType

def resolve_image(client, region):
    try:
        req = models.DescribeImagesRequest()
        req.Filters = [
            {"Name": "image-type", "Values": ["PUBLIC_IMAGE"]},
            {"Name": "platform", "Values": ["Ubuntu"]}
        ]
        req.Limit = 5
        resp = client.DescribeImages(req)
        for img in resp.ImageSet:
            if "22.04" in img.OsName or "20.04" in img.OsName:
                return img.ImageId
        if resp.ImageSet:
            return resp.ImageSet[0].ImageId
    except Exception:
        pass
    return "img-pi0ii46r"

BOOTSTRAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bootstrap.sh")
SAFE_VALUE = re.compile(r"^[A-Za-z0-9+/=_.:-]+$")

PROTOCOLS = ["ikev2", "shadowsocks", "ss_obfs", "ss2022", "vless_reality", "vmess_ws", "trojan", "hysteria2", "wireguard"]
DEFAULT_PROTOCOLS = ["ikev2", "shadowsocks"]

def normalize_protocols(requested):
    requested = requested or DEFAULT_PROTOCOLS
    unknown = set(requested) - set(PROTOCOLS)
    if unknown:
        raise ValueError(f"Unknown protocols: {sorted(unknown)}")
    return [p for p in PROTOCOLS if p in requested]

def render_bootstrap(shadowsocks, ikev2_psk, protocols=None):
    values = {
        "SS_PORT": str(int(shadowsocks.get("port", 8388))),
        "SS_PASSWORD": shadowsocks.get("password", ""),
        "SS_METHOD": shadowsocks.get("method", "chacha20-ietf-poly1305"),
        "TAG": shadowsocks.get("tag", "Tencent-Ephemeral"),
        "IKEV2_PSK": ikev2_psk,
    }
    script = open(BOOTSTRAP).read().replace("{{PROTOCOLS}}", ",".join(normalize_protocols(protocols)))
    for key, value in values.items():
        if not SAFE_VALUE.match(value):
            raise ValueError(f"{key} has characters unsafe for the bootstrap script")
        script = script.replace("{{" + key + "}}", value)
    return script

def gzip_user_data(script):
    """Tencent and AWS both cap user data at 16 KB; cloud-init decompresses gzip itself."""
    return gzip.compress(script.encode("utf-8"), mtime=0)

def build_user_data(shadowsocks, ikev2_psk, protocols=None):
    return base64.b64encode(gzip_user_data(render_bootstrap(shadowsocks, ikev2_psk, protocols))).decode("utf-8")

DEFAULT_MINUTES = 10
MIN_TIMER_LEAD = timedelta(minutes=6)  # Tencent requires ActionTime > now + 5 min

def timer_time(expires_at):
    """Cloud-side self-destruct time: never sooner than Tencent allows."""
    at = max(expires_at, datetime.now(timezone.utc) + MIN_TIMER_LEAD)
    return at.strftime("%Y-%m-%dT%H:%M:%SZ")

def expiry_from(req):
    if req.get("expiryTimestamp"):
        return datetime.fromtimestamp(int(req["expiryTimestamp"]), timezone.utc)
    return datetime.now(timezone.utc) + timedelta(minutes=int(req.get("durationMinutes", DEFAULT_MINUTES)))

def terminate_timers(client, instance_id):
    req = models.DescribeInstancesActionTimerRequest()
    req.InstanceIds = [instance_id]
    # Re-check InstanceId: an ignored filter once returned (and let us delete) other instances' timers.
    return [t for t in client.DescribeInstancesActionTimer(req).ActionTimers or []
            if t.InstanceId == instance_id and t.TimerAction == "TerminateInstances" and t.Status in ("UNDO", None)]

def import_terminate_timer(client, instance_id, action_time):
    req = models.ImportInstancesActionTimerRequest()
    req.from_json_string(json.dumps({"InstanceIds": [instance_id], "ActionTimer": {
        "TimerAction": "TerminateInstances", "ActionTime": action_time}}))
    client.ImportInstancesActionTimer(req)

def reschedule_terminate(client, instance_id, expires_at, attempts=3):
    """Tencent allows one timer per instance, so it's delete-then-import. The gap is kept tiny by
    retrying; if the new time can't be set the old one is restored, and the watchdog reaps any
    instance left without a timer."""
    old = terminate_timers(client, instance_id)
    if old:
        req = models.DeleteInstancesActionTimerRequest()
        req.ActionTimerIds = [t.ActionTimerId for t in old]
        client.DeleteInstancesActionTimer(req)
    new_time = timer_time(expires_at)
    for attempt in range(attempts):
        try:
            import_terminate_timer(client, instance_id, new_time)
            return new_time
        except TencentCloudSDKException:
            if attempt == attempts - 1:
                if old:
                    import_terminate_timer(client, instance_id, timer_time(parse_time(old[0].ActionTime)))
                raise
            time.sleep(2)

# Regions the app can launch in; the watchdog sweeps all of them.
WATCH_REGIONS = ["ap-guangzhou", "ap-shanghai", "ap-beijing", "ap-hongkong", "ap-tokyo", "ap-singapore"]
TIMERLESS_GRACE = timedelta(minutes=5)
OVERDUE_GRACE = timedelta(minutes=10)

def parse_time(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

def reap_region(client, fw_client, now=None, timerless_grace=TIMERLESS_GRACE):
    """Watchdog: terminate managed instances whose cloud timer is missing, failed or overdue."""
    now = now or datetime.now(timezone.utc)
    req = models.DescribeInstancesRequest()
    req.from_json_string(json.dumps({"Filters": [{"Name": "tag:ManagedBy", "Values": ["VPNSpawner"]}], "Limit": 100}))
    alive = [i for i in client.DescribeInstances(req).InstanceSet or []
             if i.InstanceState not in ("TERMINATING", "SHUTDOWN", "LAUNCH_FAILED")]
    reaped = {}
    for inst in alive:
        pending = [parse_time(t.ActionTime) for t in terminate_timers(client, inst.InstanceId)]
        if not pending and now - parse_time(inst.CreatedTime) >= timerless_grace:
            reaped[inst.InstanceId] = "no pending terminate timer"
        elif pending and min(pending) < now - OVERDUE_GRACE:
            reaped[inst.InstanceId] = f"terminate timer overdue since {min(pending):%H:%M}Z"
    for instance_id in list(reaped):
        if not terminate_instance(client, instance_id, wait_seconds=20):
            reaped[instance_id] += " (terminate still pending; retried next run)"
    try:
        firewall.sweep_orphans(fw_client)
    except Exception:
        pass
    return {"checked": [i.InstanceId for i in alive], "reaped": reaped}

NODE_NAME = "vpn-spawner-node"
GONE_STATES = ("TERMINATING", "SHUTDOWN", "LAUNCH_FAILED")

def instance_state(client, instance_id):
    req = models.DescribeInstancesRequest()
    req.InstanceIds = [instance_id]
    found = client.DescribeInstances(req).InstanceSet or []
    return found[0].InstanceState if found else None

def terminate_instance(client, instance_id, wait_seconds=90):
    """Idempotent: already gone or terminating counts as done; waits out "operation in progress"
    (e.g. still launching, or another terminate already running). Returns True once on its way out."""
    deadline = time.time() + wait_seconds
    while True:
        try:
            req = models.TerminateInstancesRequest()
            req.InstanceIds = [instance_id]
            req.ReleasePrepaidDataDisks = True
            client.TerminateInstances(req)
            return True
        except TencentCloudSDKException as e:
            code = e.get_code() or ""
            if "NotFound" in code or "InvalidInstanceId" in code:
                return True
            state = instance_state(client, instance_id)
            if state is None or state in GONE_STATES:
                return True
            if "InProgress" not in code and "InvalidInstanceState" not in code:
                raise
            if time.time() >= deadline:
                return False
            time.sleep(5)

def replace_running_nodes(client):
    """One node at a time: terminate any managed instance still alive before launching another."""
    req = models.DescribeInstancesRequest()
    req.from_json_string(json.dumps({"Filters": [{"Name": "tag:ManagedBy", "Values": ["VPNSpawner"]}], "Limit": 100}))
    alive = [i.InstanceId for i in client.DescribeInstances(req).InstanceSet or []
             if i.InstanceState not in ("TERMINATING", "SHUTDOWN", "LAUNCH_FAILED")]
    for instance_id in alive:
        terminate_instance(client, instance_id)
    return alive

def find_by_session(client, session_id):
    req = models.DescribeInstancesRequest()
    req.from_json_string(json.dumps({"Filters": [
        {"Name": "tag:SessionId", "Values": [session_id]},
        {"Name": "tag:ManagedBy", "Values": ["VPNSpawner"]},
    ]}))
    return client.DescribeInstances(req).InstanceSet or []

def main_handler(event, context):
    if event.get("Type") == "Timer":
        event = {"action": "reap"}
    # SCF's Invoke API delivers ClientContext as the event itself; local callers wrap it.
    ctx_raw = event.get("ClientContext", event)
    if isinstance(ctx_raw, str):
        try:
            req = json.loads(ctx_raw)
        except Exception:
            req = {}
    else:
        req = ctx_raw

    if req.get("vendor") == "aws":
        try:
            import aws_backend
        except ImportError:
            from controller import aws_backend
        return aws_backend.handle(req)

    action = req.get("action", "")
    region = req.get("region", "ap-guangzhou")
    session_id = req.get("sessionId", "")
    secret_id = req.get("secretId")
    secret_key = req.get("secretKey")

    cred = get_credential(secret_id, secret_key)
    client = cvm_client.CvmClient(cred, region)
    fw_client = firewall.get_client(cred, region)

    if action == "launch":
        allow_ips = req.get("allowIps") or []
        if not allow_ips:
            return {"success": False, "message": "allowIps is required"}
        shadowsocks = req.get("shadowsocks", {})
        ikev2_psk = req.get("ikev2Psk") or secrets.token_urlsafe(18)
        protocols = normalize_protocols(req.get("protocols"))
        user_data = build_user_data(shadowsocks, ikev2_psk, protocols)
        zone, instance_type = resolve_placement(client, region)
        image_id = resolve_image(client, region)
        replaced = replace_running_nodes(client) if req.get("replaceExisting", True) else []
        try:
            firewall.sweep_orphans(fw_client)
        except Exception:
            pass
        sg_id = firewall.create(fw_client, session_id, allow_ips)
        expires_at = expiry_from(req)

        cvm_req = models.RunInstancesRequest()
        cvm_req.Placement = {"Zone": zone}
        cvm_req.InstanceType = instance_type
        cvm_req.ImageId = image_id
        cvm_req.InstanceChargeType = "POSTPAID_BY_HOUR"
        cvm_req.InstanceName = NODE_NAME
        cvm_req.UserData = user_data
        cvm_req.SecurityGroupIds = [sg_id]
        # Survives any client crash: Tencent terminates the instance itself at expiry.
        cvm_req.ActionTimer = {"TimerAction": "TerminateInstances", "ActionTime": timer_time(expires_at)}
        cvm_req.InternetAccessible = {
            "InternetChargeType": "TRAFFIC_POSTPAID_BY_HOUR",
            "InternetMaxBandwidthOut": 30,
            "PublicIpAssigned": True
        }
        cvm_req.TagSpecification = [{
            "ResourceType": "instance",
            "Tags": [
                {"Key": "SessionId", "Value": session_id},
                {"Key": "ManagedBy", "Value": "VPNSpawner"}
            ]
        }]
        try:
            resp = client.RunInstances(cvm_req)
        except Exception:
            firewall.delete(fw_client, sg_id, wait_seconds=0)
            raise
        instance_ids = resp.InstanceIdSet
        return {
            "success": True,
            "instanceId": instance_ids[0] if instance_ids else None,
            "securityGroupId": sg_id,
            "zone": zone,
            "instanceType": instance_type,
            "allowedIps": firewall.allowed_ips(fw_client, sg_id),
            "ikev2Psk": ikev2_psk,
            "protocols": protocols,
            "replaced": replaced,
            "terminateAt": timer_time(expires_at),
            "status": "provisioning"
        }

    elif action == "extend":
        instance_id = req.get("instanceId", "")
        return {"success": True, "instanceId": instance_id,
                "terminateAt": reschedule_terminate(client, instance_id, expiry_from(req))}

    elif action == "reap":
        regions = req.get("regions") or WATCH_REGIONS
        report = {}
        for r in regions:
            try:
                grace = timedelta(seconds=int(req.get("timerlessGraceSeconds", TIMERLESS_GRACE.total_seconds())))
                report[r] = reap_region(cvm_client.CvmClient(cred, r), firewall.get_client(cred, r), timerless_grace=grace)
            except Exception as e:
                report[r] = {"error": str(e)[:200]}
        return {"success": True, "regions": report}

    elif action == "find":
        found = find_by_session(client, session_id)
        return {"success": True, "instances": [{
            "instanceId": i.InstanceId, "status": i.InstanceState,
            "publicIP": (i.PublicIpAddresses or [None])[0],
            "securityGroupIds": i.SecurityGroupIds or [],
        } for i in found]}

    elif action == "allow_ip":
        ip = req.get("ip", "")
        sg_id = req.get("securityGroupId") or instance_firewall(client, fw_client, req.get("instanceId", ""))
        if not ip or not sg_id or not firewall.is_managed(fw_client, sg_id):
            return {"success": False, "message": "ip and a VPNSpawner-managed instance/securityGroupId are required"}
        return {"success": True, "securityGroupId": sg_id, "allowedIps": firewall.allow_ip(fw_client, sg_id, ip)}

    elif action == "status":
        instance_id = req.get("instanceId", "")
        cvm_req = models.DescribeInstancesRequest()
        cvm_req.InstanceIds = [instance_id]
        resp = client.DescribeInstances(cvm_req)
        if resp.InstanceSet:
            inst = resp.InstanceSet[0]
            public_ip = (inst.PublicIpAddresses or [None])[0]
            result = {
                "success": True,
                "instanceId": instance_id,
                "status": inst.InstanceState,
                "publicIP": public_ip
            }
            # Tunnelled traffic hairpinning back to the node arrives from its own public IP.
            if inst.InstanceState == "RUNNING" and public_ip:
                for sg_id in inst.SecurityGroupIds or []:
                    if firewall.is_managed(fw_client, sg_id):
                        result["allowedIps"] = firewall.allow_ip(fw_client, sg_id, public_ip)
            return result
        return {"success": False, "message": "Instance not found"}

    elif action == "terminate":
        instance_id = req.get("instanceId", "")
        sg_id = req.get("securityGroupId") or instance_firewall(client, fw_client, instance_id)
        terminated = terminate_instance(client, instance_id) if instance_id else True
        sg_deleted = None
        if sg_id and firewall.is_managed(fw_client, sg_id):
            sg_deleted = firewall.delete(fw_client, sg_id, wait_seconds=req.get("firewallWaitSeconds", 120))
        return {"success": terminated, "status": "terminated" if terminated else "terminate pending",
                "securityGroupId": sg_id, "securityGroupDeleted": sg_deleted}

    return {"success": False, "message": f"Unknown action: {action}"}
