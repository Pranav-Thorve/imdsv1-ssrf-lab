#!/usr/bin/env bash
# Tear down resources tagged Project=capone-imds-lab in the current account/region.
set -euo pipefail
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
NAME="capone-imds-lab"

how_to_auth() {
  cat <<'EOF'

destroy.sh uses the same AWS CLI identity as setup.sh.
It does not take an account ID.

  export AWS_PROFILE=lab
  export AWS_REGION=us-east-1    # must match the region you used for setup
  ./destroy.sh

Only resources tagged Project=capone-imds-lab in THAT account/region are removed.
Skip the confirm prompt with: ASSUME_YES=1 ./destroy.sh

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

echo "==> will DELETE lab resources in THIS identity"
echo "    AWS_PROFILE=$CLI_PROFILE"
echo "    account=$ACCOUNT"
echo "    arn=$ARN"
echo "    region=$REGION"

if [[ "${ASSUME_YES:-}" != "1" ]]; then
  read -r -p "Destroy Project=capone-imds-lab in account $ACCOUNT ($REGION)? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

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
for ROLE in capone-WAF-Role capone-imds-lab-instance; do
  if aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$ROLE"
    echo "    deleted instance profile $ROLE"
  fi
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$ROLE" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role-policy --role-name "$ROLE" --policy-name s3-read 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE"
    echo "    deleted role $ROLE"
  fi
done
echo "done"
