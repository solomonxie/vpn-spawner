import json
import os
import re
import base64
import secrets
from tencentcloud.common import credential
from tencentcloud.cvm.v20170312 import cvm_client, models

try:
    import firewall
except ImportError:
    from controller import firewall

def get_credential(secret_id=None, secret_key=None):
    s_id = secret_id or os.environ.get("TENCENTCLOUD_SECRET_ID")
    s_key = secret_key or os.environ.get("TENCENTCLOUD_SECRET_KEY")
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

INSTANCE_TYPES = ["SA2.MEDIUM2", "S5.MEDIUM2", "SA3.MEDIUM2", "SA5.MEDIUM2", "S6.MEDIUM2"]

def resolve_placement(client, region):
    """Cheapest (zone, instance type) currently on sale, hourly billing."""
    req = models.DescribeZoneInstanceConfigInfosRequest()
    req.from_json_string(json.dumps({"Filters": [
        {"Name": "instance-charge-type", "Values": ["POSTPAID_BY_HOUR"]},
        {"Name": "instance-type", "Values": INSTANCE_TYPES},
    ]}))
    on_sale = [q for q in client.DescribeZoneInstanceConfigInfos(req).InstanceTypeQuotaSet if q.Status == "SELL"]
    if not on_sale:
        raise RuntimeError(f"None of {INSTANCE_TYPES} on sale in {region}")
    best = min(on_sale, key=lambda q: q.Price.UnitPrice)
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

def build_user_data(shadowsocks, ikev2_psk):
    values = {
        "SS_PORT": str(int(shadowsocks.get("port", 8388))),
        "SS_PASSWORD": shadowsocks.get("password", ""),
        "SS_METHOD": shadowsocks.get("method", "chacha20-ietf-poly1305"),
        "TAG": shadowsocks.get("tag", "Tencent-Ephemeral"),
        "IKEV2_PSK": ikev2_psk,
    }
    script = open(BOOTSTRAP).read()
    for key, value in values.items():
        if not SAFE_VALUE.match(value):
            raise ValueError(f"{key} has characters unsafe for the bootstrap script")
        script = script.replace("{{" + key + "}}", value)
    return base64.b64encode(script.encode("utf-8")).decode("utf-8")

def main_handler(event, context):
    ctx_raw = event.get("ClientContext", "{}")
    if isinstance(ctx_raw, str):
        try:
            req = json.loads(ctx_raw)
        except Exception:
            req = {}
    else:
        req = ctx_raw

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
        user_data = build_user_data(shadowsocks, ikev2_psk)
        zone, instance_type = resolve_placement(client, region)
        image_id = resolve_image(client, region)
        try:
            firewall.sweep_orphans(fw_client)
        except Exception:
            pass
        sg_id = firewall.create(fw_client, session_id, allow_ips)

        cvm_req = models.RunInstancesRequest()
        cvm_req.Placement = {"Zone": zone}
        cvm_req.InstanceType = instance_type
        cvm_req.ImageId = image_id
        cvm_req.InstanceChargeType = "POSTPAID_BY_HOUR"
        cvm_req.InstanceName = f"vpn-{session_id}"
        cvm_req.UserData = user_data
        cvm_req.SecurityGroupIds = [sg_id]
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
            "status": "provisioning"
        }

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
        cvm_req = models.TerminateInstancesRequest()
        cvm_req.InstanceIds = [instance_id]
        cvm_req.ReleasePrepaidDataDisks = True
        client.TerminateInstances(cvm_req)
        sg_deleted = None
        if sg_id and firewall.is_managed(fw_client, sg_id):
            sg_deleted = firewall.delete(fw_client, sg_id, wait_seconds=req.get("firewallWaitSeconds", 120))
        return {"success": True, "status": "terminated", "securityGroupId": sg_id, "securityGroupDeleted": sg_deleted}

    return {"success": False, "message": f"Unknown action: {action}"}
