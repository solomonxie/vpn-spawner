#!/usr/bin/env python3
"""Uploads build/scf-controller.zip to an existing SCF function in place (no re-create).
Credentials from TENCENTCLOUD_SECRET_ID / TENCENTCLOUD_SECRET_KEY. Usage: deploy_code.py ZIP NAME REGION"""
import base64
import sys
import time

from tencentcloud.common import credential
from tencentcloud.scf.v20180416 import scf_client, models

zip_path, name, region = sys.argv[1:4]
client = scf_client.ScfClient(credential.EnvironmentVariableCredential().get_credential(), region)

req = models.UpdateFunctionCodeRequest()
req.FunctionName = name
req.Namespace = "default"
req.Handler = "app.main_handler"
req.ZipFile = base64.b64encode(open(zip_path, "rb").read()).decode()
client.UpdateFunctionCode(req)

get = models.GetFunctionRequest()
get.FunctionName = name
for _ in range(60):
    status = client.GetFunction(get).Status
    if status == "Active":
        print(f"{name} code updated")
        sys.exit(0)
    if "Failed" in status:
        sys.exit(f"{name} update failed: {status}")
    time.sleep(2)
sys.exit(f"{name} still {status}")
