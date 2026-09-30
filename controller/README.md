# SCF Controller

Ephemeral VPN controller running as a Tencent Cloud Function (SCF).

## Deploy to Tencent Cloud

```bash
# Build and push to Tencent Container Registry (TCR) in ap-guangzhou
docker build -t ccr.ccs.tencentyun.com/<your-ns>/vpn-controller:latest .
docker push ccr.ccs.tencentyun.com/<your-ns>/vpn-controller:latest

# Create SCF function with container image and attach CAM role with CVM permissions
```
