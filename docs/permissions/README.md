# Tencent Cloud Permissions

Least-privilege CAM policy for the spawn/terminate workflow: `cam-policy.json`.
Source of truth: `terraform/tencentcloud/vpn_spawner.tf` (sub-user `vpn-spawner`, key in `~/.vpn-spawner/tencentcloud-vpn-spawner-keys.txt`).
Verified by a passing `tests/test_real_lifecycle.py` run.

## Flow -> API

| Step | API | Permission |
|---|---|---|
| Pick image | DescribeImages | `cvm:DescribeImages` |
| Firewall | CreateSecurityGroup (+Tags), CreateSecurityGroupPolicies | `cvm:CreateSecurityGroup`, `vpc:CreateSecurityGroupPolicies`, `tag:*Resource*` |
| Launch | RunInstances (SecurityGroupIds, TagSpecification) | `cvm:RunInstances`, `finance:trade` |
| Poll | DescribeInstances | `cvm:DescribeInstances` |
| Add IP | DescribeSecurityGroupPolicies, CreateSecurityGroupPolicies | `cvm:DescribeSecurityGroupPolicys` (sic) |
| Teardown | TerminateInstances, DeleteSecurityGroup | tag-scoped to `ManagedBy=VPNSpawner` |

## Access control

Each node gets its own security group: ingress ALL from allowed IPs (`/32`) only, egress open.
Launch requires `allowIps`; CLI/app default to the caller's current public IP. Add more with `allow_ip`.

## Gotchas (found in real runs)

- Security group APIs are served by `vpc.tencentcloudapi.com`, but CAM checks most of them as `cvm:*`.
- CAM spells one action `cvm:DescribeSecurityGroupPolicys`.
- CAM rejects policies with unknown actions (`ActionNotExist`), one name per error: `vpc:DescribeSecurityGroupEx`, `vpc:DeleteSecurityGroup`, `cvm:CreateSecurityGroupPolicies` don't exist.
- Sub-users need `finance:trade` to place any order, even pay-as-you-go (`无支付权限`).
- Tag-scoped `TerminateInstances` / `DeleteSecurityGroup` works.
- New permissions can take ~1 min to propagate.

## Account prerequisites

- Real-name verified, balance > 0.
- Default VPC + subnet in the region (RunInstances sets no network).
