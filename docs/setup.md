# VPN Spawner setup

The app creates servers in **your own** cloud account. One-time setup per provider, then paste the key into the app.

- **AWS**: the app calls a controller Lambda in your account; its key can only invoke that function.
- **Tencent Cloud**: the app calls the Tencent API directly ("Runs from: This iPhone") or a controller cloud function in your account ("Runs from: Cloud function").

Every resource the controller creates is tagged `ManagedBy=VPNSpawner`; delete rights are limited to that tag.

## Build the controller package

Needs Python 3 and `zip`. From the repo root:

```bash
python3 -m venv venv
controller/package.sh   # -> build/controller.zip (AWS) and build/scf-controller.zip (Tencent), same content
```

## AWS

Replace `<ACCOUNT_ID>` (12 digits, top-right of the console) and `<REGION>` (where the Lambda lives; the app's default is `ca-central-1`).
Server regions: us-west-2, us-east-1, ca-central-1, eu-central-1, ap-northeast-1, ap-southeast-1, ap-east-1 (Hong Kong), ap-east-2 (Taipei). The last two are opt-in: enable them under Account → AWS Regions to use them. Each region used needs its default VPC.

### 1. Terminate role (used by each server's self-destruct schedule)

IAM → Roles → Create role → Custom trust policy:

```json
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
  "Principal": {"Service": "scheduler.amazonaws.com"}, "Action": "sts:AssumeRole",
  "Condition": {"StringEquals": {"aws:SourceAccount": "<ACCOUNT_ID>"}}}]}
```

Name `vpn-spawner-terminate`. Inline policy:

```json
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "ec2:TerminateInstances",
  "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:instance/*",
  "Condition": {"StringEquals": {"aws:ResourceTag/ManagedBy": "VPNSpawner"}}}]}
```

### 2. Controller Lambda

Lambda → Create function in `<REGION>`:

| Setting | Value |
|---|---|
| Name | `vpn-spawner-controller` |
| Runtime | Python 3.12 |
| Execution role | new role with basic Lambda permissions |
| Code | upload `build/controller.zip` |
| Handler | `app.main_handler` |
| Memory / timeout | 256 MB / 3 min (terminate waits up to 2 min for the firewall to free up) |
| Environment | `SCHEDULER_ROLE_ARN` = ARN of `vpn-spawner-terminate` |

Add this inline policy to the function's execution role:

```json
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["ec2:DescribeInstances", "ec2:DescribeSecurityGroups", "ec2:DescribeVpcs"], "Resource": "*"},
  {"Effect": "Allow", "Action": "ec2:RunInstances",
   "Resource": ["arn:aws:ec2:*:<ACCOUNT_ID>:instance/*", "arn:aws:ec2:*:<ACCOUNT_ID>:volume/*"],
   "Condition": {"StringEquals": {"aws:RequestTag/ManagedBy": "VPNSpawner"}}},
  {"Effect": "Allow", "Action": "ec2:RunInstances",
   "Resource": ["arn:aws:ec2:*::image/*", "arn:aws:ec2:*:<ACCOUNT_ID>:subnet/*",
                "arn:aws:ec2:*:<ACCOUNT_ID>:security-group/*", "arn:aws:ec2:*:<ACCOUNT_ID>:network-interface/*"]},
  {"Effect": "Allow", "Action": "ec2:CreateTags", "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:*/*",
   "Condition": {"StringEquals": {"ec2:CreateAction": ["RunInstances", "CreateSecurityGroup"]}}},
  {"Effect": "Allow", "Action": ["ec2:TerminateInstances", "ec2:CreateTags"], "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:instance/*",
   "Condition": {"StringEquals": {"aws:ResourceTag/ManagedBy": "VPNSpawner"}}},
  {"Effect": "Allow", "Action": "ec2:CreateSecurityGroup", "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:security-group/*",
   "Condition": {"StringEquals": {"aws:RequestTag/ManagedBy": "VPNSpawner"}}},
  {"Effect": "Allow", "Action": "ec2:CreateSecurityGroup", "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:vpc/*"},
  {"Effect": "Allow", "Action": ["ec2:AuthorizeSecurityGroupIngress", "ec2:DeleteSecurityGroup"],
   "Resource": "arn:aws:ec2:*:<ACCOUNT_ID>:security-group/*",
   "Condition": {"StringEquals": {"aws:ResourceTag/ManagedBy": "VPNSpawner"}}},
  {"Effect": "Allow", "Action": "ssm:GetParameter", "Resource": "arn:aws:ssm:*::parameter/aws/service/canonical/ubuntu/*"},
  {"Effect": "Allow", "Action": ["scheduler:CreateSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule", "scheduler:GetSchedule"],
   "Resource": "arn:aws:scheduler:*:<ACCOUNT_ID>:schedule/default/vpn-spawner-*"},
  {"Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/vpn-spawner-terminate",
   "Condition": {"StringEquals": {"iam:PassedToService": "scheduler.amazonaws.com"}}}
]}
```

Code updates: Lambda → Code → Upload from → `.zip` file (the function keeps its settings).

### 3. Watchdog (backstop for missed self-destructs)

EventBridge → Scheduler → Create schedule `vpn-spawner-watchdog`: recurring, rate-based, every 10 minutes, flexible window Off. Target: AWS Lambda → Invoke → `vpn-spawner-controller`, payload `{"vendor": "aws", "action": "reap"}`. Let it create a new execution role.

### 4. The app's key (invoke only)

IAM → Users → Create user `vpn-spawner-app`, no console access. Inline policy:

```json
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "lambda:InvokeFunction",
  "Resource": "arn:aws:lambda:<REGION>:<ACCOUNT_ID>:function:vpn-spawner-controller"}]}
```

Security credentials → Create access key → "Application running outside AWS". Copy this text with your values, then in the app: Settings → AWS → **Paste credentials** → **Test connection**.

```
access_key_id: AKIA...
secret_access_key: ...
region: <REGION>
function: vpn-spawner-controller
```

## Tencent Cloud

Account prerequisites: identity verified, positive balance, default VPC and subnet in each region used.
Server regions: ap-guangzhou, ap-shanghai, ap-beijing, ap-hongkong, ap-tokyo, ap-singapore.

### 1. Key for the app (both modes)

1. CAM → Policies → Create custom policy → By policy syntax → paste [`permissions/cam-policy.json`](permissions/cam-policy.json) → name `vpn-spawner`. Details and gotchas: [`permissions/README.md`](permissions/README.md).
2. CAM → Users → Create user → Custom → programmatic access only → name `vpn-spawner` → attach the `vpn-spawner` policy.
3. Create an API key for that user. In the app: Settings → Tencent Cloud → **Paste credentials** with:

```
secret_id: AKID...
secret_key: ...
```

That's all for **Runs from: This iPhone**.

### 2. Cloud function (optional, "Runs from: Cloud function")

Servers self-destruct either way (a Tencent-side terminate timer). The function adds a watchdog and keeps working when the phone is offline.

1. CAM → Roles → Create role → Tencent Cloud product service → **SCF** (`scf.qcloud.com`) → attach the `vpn-spawner` policy → name `SCF_VPNSpawner`.
2. SCF → Create → Event function from scratch, region **Guangzhou** (`ap-guangzhou`; the app invokes it there and it manages every region):

| Setting | Value |
|---|---|
| Name | `vpn-spawner-controller` (namespace `default`) |
| Runtime | Python 3.10 |
| Code | local ZIP `build/scf-controller.zip` |
| Handler | `app.main_handler` |
| Memory / timeout | 256 MB / 180 s |
| Execution role | `SCF_VPNSpawner` |

3. Trigger: Timer, name `watchdog`, cron `0 */10 * * * * *` (every 10 min; the handler treats timer events as `reap`).
4. Add to the `vpn-spawner` user a policy allowing only this function:

```json
{"version": "2.0", "statement": [{"effect": "allow", "action": ["scf:InvokeFunction"],
  "resource": ["qcs::scf:ap-guangzhou:uin/<ACCOUNT_ID>:namespace/default/function/vpn-spawner-controller"]}]}
```

5. In the app: Settings → Runs from → **Cloud function**.

Code updates: `TENCENTCLOUD_SECRET_ID=… TENCENTCLOUD_SECRET_KEY=… venv/bin/python controller/deploy_code.py build/scf-controller.zip vpn-spawner-controller ap-guangzhou` (an admin key; `venv/bin/pip install tencentcloud-sdk-python` first), or re-upload the ZIP in the console.

## Removing everything

Destroy any running session in the app first. Then delete what you created above: AWS user, Lambda, schedule `vpn-spawner-watchdog`, the two roles, log group `/aws/lambda/vpn-spawner-controller`; Tencent sub-user, policies, role `SCF_VPNSpawner`, function.
