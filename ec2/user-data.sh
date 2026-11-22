#!/bin/bash
# user-data.sh - runs once as root on first boot of cv-ec2-22p-9106 (Amazon Linux 2023).
# 1. install and start Apache  2. install sync-cv.sh  3. run it once
# 4. schedule it every 5 minutes with a systemd timer (AL2023 has no cron).
# No access keys: the AWS CLI on the instance uses the attached role.

dnf install -y httpd
systemctl enable --now httpd

# --- sync-cv.sh (same content as ec2/sync-cv.sh in the repo) ---
cat > /usr/local/bin/sync-cv.sh <<'SYNC_SCRIPT'
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
SYNC_SCRIPT
chmod 755 /usr/local/bin/sync-cv.sh

# --- schedule: every 5 minutes ---
cat > /etc/systemd/system/cv-sync.service <<'UNIT'
[Unit]
Description=Sync CV site from S3 into the web root
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
UNIT

cat > /etc/systemd/system/cv-sync.timer <<'UNIT'
[Unit]
Description=Run cv-sync every 5 minutes

[Timer]
OnCalendar=*:0/5
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# first run now, then let the timer take over
/usr/local/bin/sync-cv.sh
systemctl daemon-reload
systemctl enable --now cv-sync.timer
