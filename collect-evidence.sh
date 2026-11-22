#!/bin/bash
# collect-evidence.sh - gathers the evidence for the CV-on-AWS lab into evidence.txt
#
# usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
#   e.g. ./collect-evidence.sh cv-22p-9106 http://13.60.1.2 https://abc.lambda-url.eu-north-1.on.aws/
#
# If a command fails, the failure is written into its section and the script carries on.

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <bucket-name> <ec2-address> <lambda-address>" >&2
  exit 1
fi

BUCKET="$1"
EC2_URL="${2%/}"
LAMBDA_URL="${3%/}"
OUT="evidence.txt"

ROLL="22p-9106"
REGION="${AWS_REGION:-eu-north-1}"
EC2_ROLE="cv-ec2-role-$ROLL"
LAMBDA_ROLE="cv-lambda-role-$ROLL"
INSTANCE_NAME="cv-ec2-$ROLL"
FUNCTION="cv-func-$ROLL"
LOG_GROUP="/aws/lambda/$FUNCTION"

export AWS_PAGER=""
export AWS_REGION="$REGION"

# check for the http:// part so curl gets full addresses
case "$EC2_URL" in http*) ;; *) EC2_URL="http://$EC2_URL" ;; esac
case "$LAMBDA_URL" in http*) ;; *) LAMBDA_URL="https://$LAMBDA_URL" ;; esac

section() { printf '\n== %s ==\n' "$1" >> "$OUT"; }

# run a command, capture its output; on failure note it and keep going
run() {
  echo "\$ $*" >> "$OUT"
  if ! "$@" >> "$OUT" 2>&1; then
    echo "!! command failed (exit $?): $*" >> "$OUT"
  fi
}

probe() {  # status and content type of one address
  local url="$1"
  printf '%-75s ' "$url" >> "$OUT"
  if ! curl -s -o /dev/null --max-time 15 -w 'status=%{http_code} content_type=%{content_type}\n' "$url" >> "$OUT" 2>&1; then
    echo "!! curl failed for $url" >> "$OUT"
  fi
}

{
  echo "Evidence for CV on AWS - roll $ROLL"
  echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "bucket=$BUCKET ec2=$EC2_URL lambda=$LAMBDA_URL region=$REGION"
} > "$OUT"

section caller
run aws sts get-caller-identity

section public-access
run aws s3api get-public-access-block --bucket "$BUCKET"

section versioning
run aws s3api get-bucket-versioning --bucket "$BUCKET"

section objects
run aws s3 ls "s3://$BUCKET/site/" --recursive

section ec2-policy
for p in $(aws iam list-role-policies --role-name "$EC2_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  run aws iam get-role-policy --role-name "$EC2_ROLE" --policy-name "$p"
done
run aws iam list-attached-role-policies --role-name "$EC2_ROLE"

section lambda-policy
run aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
for p in $(aws iam list-role-policies --role-name "$LAMBDA_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  run aws iam get-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$p"
done

section security-group
SG_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text 2>/dev/null)
if [ -n "$SG_IDS" ]; then
  # shellcheck disable=SC2086
  run aws ec2 describe-security-groups --group-ids $SG_IDS \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Inbound:IpPermissions}'
else
  echo "!! could not find a running instance named $INSTANCE_NAME" >> "$OUT"
fi

section instance
run aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,Type:InstanceType,ImageId:ImageId,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,HttpEndpoint:MetadataOptions.HttpEndpoint,InstanceProfile:IamInstanceProfile.Arn,Tags:Tags}'

section endpoints
for path in / /style.css /cv.pdf; do probe "$EC2_URL$path"; done
for path in / /style.css /cv.pdf /anything; do probe "$LAMBDA_URL$path"; done
probe "https://$BUCKET.s3.$REGION.amazonaws.com/site/index.html"

section lambda-logs
echo "\$ aws logs tail $LOG_GROUP --since 1h --format short | tail -n 20" >> "$OUT"
if LOGS=$(aws logs tail "$LOG_GROUP" --since 1h --format short 2>&1); then
  printf '%s\n' "$LOGS" | tail -n 20 >> "$OUT"
else
  printf '%s\n!! command failed: aws logs tail %s\n' "$LOGS" "$LOG_GROUP" >> "$OUT"
fi

section log-retention
run aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].{logGroupName:logGroupName,retentionInDays:retentionInDays}'

echo "DONE"
