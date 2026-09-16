#!/usr/bin/env bash
# Tear down resources tagged Project=capone-imds-lab in the current account/region.
set -euo pipefail
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAME="capone-imds-lab"

echo "==> terminating instances"
IDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=${NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -n "${IDS:-}" && "$IDS" != "None" ]]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS >/dev/null
  echo "    waiting: $IDS"
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $IDS
fi

echo "==> security groups"
for sg in $(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:Project,Values=${NAME}" --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg" && echo "    deleted $sg" || true
done

echo "==> buckets tagged ${NAME}"
for b in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  tag="$(aws s3api get-bucket-tagging --bucket "$b" --query "TagSet[?Key=='Project'].Value" --output text 2>/dev/null || true)"
  if [[ "$tag" == "$NAME" ]]; then
    aws s3 rb "s3://$b" --force
    echo "    deleted s3://$b"
  fi
done

echo "==> instance profile / role"
if aws iam get-instance-profile --instance-profile-name "${NAME}-instance" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name "${NAME}-instance" --role-name "${NAME}-instance" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "${NAME}-instance"
fi
if aws iam get-role --role-name "${NAME}-instance" >/dev/null 2>&1; then
  aws iam detach-role-policy --role-name "${NAME}-instance" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role-policy --role-name "${NAME}-instance" --policy-name s3-read 2>/dev/null || true
  aws iam delete-role --role-name "${NAME}-instance"
fi
echo "done"
