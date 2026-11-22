#!/bin/bash
# sync-cv.sh - pull the CV from S3 into the web root and stamp the footer.
# Runs once from user-data at boot, then every 5 minutes from cv-sync.timer.
# Credentials come from the instance role (cv-ec2-role-22p-9106). No keys here.

BUCKET="cv-22p-9106"
PREFIX="site/"
REGION="eu-north-1"
WEBROOT="/var/www/html"
LOG="/var/log/cv-sync.log"
IMDS="http://169.254.169.254/latest"

# IMDSv2: get a session token first, then ask for the instance ID with it
TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/instance-id")

STATUS="FAIL"
if [ -n "$INSTANCE_ID" ] &&
   aws s3 sync "s3://$BUCKET/$PREFIX" "$WEBROOT/" --region "$REGION" --delete --only-show-errors &&
   sed -i "s/{{HOSTED_ON}}/EC2 $INSTANCE_ID/" "$WEBROOT/index.html"; then
  STATUS="OK"
fi

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') sync=$STATUS instance=${INSTANCE_ID:-unknown} source=s3://$BUCKET/$PREFIX" >> "$LOG"
[ "$STATUS" = "OK" ]
