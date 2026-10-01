# Tencent Cloud Permissions

Least-privilege CAM policy for the spawn/terminate workflow: `cam-policy.json`.
Draft, unverified against a live account. Narrow after first real run using CAM error messages.

## Flow -> API

| Step | Code | API | Permission |
|---|---|---|---|
| Pick zone | `resolve_zone` | DescribeZones | `cvm:DescribeZones` |
| Pick image | `resolve_image` | DescribeImages | `cvm:DescribeImages` |
| Launch | `launch` | RunInstances | `cvm:RunInstances`, plus `vpc:Describe*` (default VPC/subnet/SG lookup), `tag:AddResourceTag` (TagSpecification) |
| Poll | `status` | DescribeInstances | `cvm:DescribeInstances` |
| Teardown | `terminate` | TerminateInstances | `cvm:TerminateInstances` (limited to tag `ManagedBy=VPNSpawner`) |

`vpc:CreateSecurityGroup*`, `AssociateSecurityGroups`, `DeleteSecurityGroup` are only needed if the controller is changed to create a dedicated SG (see below). Remove otherwise.

## Setup

1. CAM > Users > create sub-user, programmatic access only (no console login).
2. CAM > Policies > Create by policy generator (JSON) > paste `cam-policy.json`.
3. Attach to the sub-user; put its SecretId/SecretKey in `.env` (gitignored).
4. For SCF deployment: attach the same policy to a CAM role trusted by `scf.qcloud.com`; the code then needs no keys (`EnvironmentVariableCredential`).

## Account prerequisites

- Real-name verified, balance > 0 (pay-as-you-go CVM + traffic billing).
- Default VPC and subnet exist in the target region (RunInstances sets no network).
- Instance type `S5.MEDIUM2` available in the chosen zone.
- Security group on the default VPC must allow inbound TCP/UDP 8388 and TCP 8389. `RunInstances` passes no `SecurityGroupIds`, so the region's default SG applies; if it blocks them, the node is unreachable. Fix by opening those ports on the default SG, or add a dedicated SG in the controller.

## Safety

- Terminate is tag-scoped: key cannot delete instances it did not create.
- `spawn.py --terminate <id>` is the manual kill; check CVM console after every test run.
- Do not grant `cvm:*` or `QcloudCVMFullAccess` (includes CBS/EIP/CLB etc.).
