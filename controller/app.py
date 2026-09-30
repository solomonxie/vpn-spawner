import json
import os
import base64
from tencentcloud.common import credential
from tencentcloud.cvm.v20170312 import cvm_client, models

def get_client(region, secret_id=None, secret_key=None):
    s_id = secret_id or os.environ.get("TENCENTCLOUD_SECRET_ID")
    s_key = secret_key or os.environ.get("TENCENTCLOUD_SECRET_KEY")
    if s_id and s_key:
        cred = credential.Credential(s_id, s_key)
    else:
        cred = credential.EnvironmentVariableCredential().get_credential()
    return cvm_client.CvmClient(cred, region)

def resolve_zone(client, region):
    try:
        req = models.DescribeZonesRequest()
        resp = client.DescribeZones(req)
        for z in resp.ZoneSet:
            if z.ZoneState == "AVAILABLE":
                return z.Zone
    except Exception:
        pass
    return f"{region}-3"

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

def build_user_data(shadowsocks):
    port = shadowsocks.get("port", 8388)
    password = shadowsocks.get("password", "")
    method = shadowsocks.get("method", "chacha20-ietf-poly1305")
    tag = shadowsocks.get("tag", "Tencent-Ephemeral")

    script = f"""#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y shadowsocks-libev python3

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

mkdir -p /opt/vpn-sub
cat <<'PYEOF' > /opt/vpn-sub/sub_server.py
import http.server
import socketserver
import urllib.request
import base64

PORT = 8389
METHOD = "{method}"
PASSWORD = "{password}"
SS_PORT = {port}
TAG = "{tag}"

def get_ip():
    try:
        req = urllib.request.Request("http://metadata.tencentyun.com/latest/meta-data/public-ipv4", headers={{"User-Agent": "curl/7.68.0"}})
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.read().decode('utf-8').strip()
    except Exception:
        pass
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=3) as resp:
            return resp.read().decode('utf-8').strip()
    except Exception:
        return "127.0.0.1"

class SubHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ip = get_ip()
        user_info = f"{{METHOD}}:{{PASSWORD}}@{{ip}}:{{SS_PORT}}"
        b64_info = base64.b64encode(user_info.encode('utf-8')).decode('utf-8')
        ss_uri = f"ss://{{b64_info}}#{{TAG}}\\n"
        sub_body = base64.b64encode(ss_uri.encode('utf-8')).decode('utf-8')

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(sub_body)))
        self.end_headers()
        self.wfile.write(sub_body.encode('utf-8'))

    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(("", PORT), SubHandler) as httpd:
    httpd.serve_forever()
PYEOF

cat <<EOF > /etc/systemd/system/vpn-sub.service
[Unit]
Description=VPN Public Subscription Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vpn-sub/sub_server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-sub.service
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
    secret_id = req.get("secretId")
    secret_key = req.get("secretKey")

    client = get_client(region, secret_id, secret_key)

    if action == "launch":
        shadowsocks = req.get("shadowsocks", {})
        user_data = build_user_data(shadowsocks)
        zone = resolve_zone(client, region)
        image_id = resolve_image(client, region)

        cvm_req = models.RunInstancesRequest()
        cvm_req.Placement = {"Zone": zone}
        cvm_req.InstanceType = "S5.MEDIUM2"
        cvm_req.ImageId = image_id
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
