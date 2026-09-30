import json
import os
import base64
from tencentcloud.common import credential
from tencentcloud.cvm.v20170312 import cvm_client, models

def get_client(region):
    cred = credential.EnvironmentVariableCredential().get_credential()
    return cvm_client.CvmClient(cred, region)

def build_user_data(shadowsocks):
    port = shadowsocks.get("port", 8388)
    password = shadowsocks.get("password", "")
    method = shadowsocks.get("method", "chacha20-ietf-poly1305")
    script = f"""#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y shadowsocks-libev
cat <<EOF > /etc/shadowsocks-libev/config.json
{{
    "server": "0.0.0.0",
    "server_port": {port},
    "password": "{password}",
    "timeout": 300,
    "method": "{method}",
    "fast_open": false,
    "nameserver": "8.8.8.8",
    "mode": "tcp_and_udp"
}}
EOF
systemctl restart shadowsocks-libev
systemctl enable shadowsocks-libev
"""
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
    client = get_client(region)

    if action == "launch":
        shadowsocks = req.get("shadowsocks", {})
        user_data = build_user_data(shadowsocks)
        cvm_req = models.RunInstancesRequest()
        cvm_req.Placement = {"Zone": f"{region}-3"}
        cvm_req.InstanceType = "S5.MEDIUM2"
        cvm_req.ImageId = "img-pi0ii46r"
        cvm_req.InstanceChargeType = "POSTPAID_BY_HOUR"
        cvm_req.InstanceName = f"vpn-{session_id}"
        cvm_req.UserData = user_data
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
        resp = client.RunInstances(cvm_req)
        instance_ids = resp.InstanceIdSet
        return {
            "success": True,
            "instanceId": instance_ids[0] if instance_ids else None,
            "status": "provisioning"
        }

    elif action == "status":
        instance_id = req.get("instanceId", "")
        cvm_req = models.DescribeInstancesRequest()
        cvm_req.InstanceIds = [instance_id]
        resp = client.DescribeInstances(cvm_req)
        if resp.InstanceSet:
            inst = resp.InstanceSet[0]
            ips = inst.PublicIpAddresses
            return {
                "success": True,
                "instanceId": instance_id,
                "status": inst.InstanceState,
                "publicIP": ips[0] if ips else None
            }
        return {"success": False, "message": "Instance not found"}

    elif action == "terminate":
        instance_id = req.get("instanceId", "")
        cvm_req = models.TerminateInstancesRequest()
        cvm_req.InstanceIds = [instance_id]
        cvm_req.ReleasePrepaidDataDisks = True
        client.TerminateInstances(cvm_req)
        return {"success": True, "status": "terminated"}

    return {"success": False, "message": f"Unknown action: {action}"}
