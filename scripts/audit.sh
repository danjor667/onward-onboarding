#!/usr/bin/env bash
# Show who changed access and when, from both sources of truth:
#   1. Git history: who wrote and merged each change to the template.
#   2. CloudTrail: every IAM API call made in the account, including any made
#      outside the template.
#
# Usage: scripts/audit.sh [DAYS]   (default 7; CloudTrail event history keeps 90)
set -euo pipefail

DAYS="${1:-7}"
export AWS_REGION="${AWS_REGION:-eu-central-1}" # where the stack and secrets live
mkdir -p evidence
OUT="evidence/audit-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$OUT") 2>&1

if date -v-1d >/dev/null 2>&1; then
  START=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
else
  START=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
fi

echo "== Git history of access definitions =="
git log --date=iso --pretty='%h  %ad  %an <%ae>  %s' -- onboarding.yaml stack-config.yaml pipeline-roles.yaml || true

echo
echo "== Stack deployments (who/what CloudFormation applied) =="
aws cloudformation describe-stack-events --stack-name "${STACK_NAME:-onward-onboarding}" \
  --query 'StackEvents[?ResourceType==`AWS::CloudFormation::Stack`].[Timestamp,ResourceStatus,ResourceStatusReason]' \
  --output table 2>/dev/null || echo "(stack ${STACK_NAME:-onward-onboarding} not found; set STACK_NAME)"

echo
echo "== CloudTrail: IAM changes since ${START} =="
# IAM is a global service: CloudTrail event history records its events in
 whichever region the trail and stack are in.
aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=iam.amazonaws.com \
  --start-time "$START" \
  --query 'Events[?ReadOnly==`"false"`].[EventTime,Username,EventName,Resources[0].ResourceName]' \
  --output table

echo
echo "== Drift: has anything been changed outside the template? =="
STACK="${STACK_NAME:-onward-onboarding}"
if DRIFT_ID=$(aws cloudformation detect-stack-drift --stack-name "$STACK" \
    --query StackDriftDetectionId --output text 2>/dev/null); then
  while [ "$(aws cloudformation describe-stack-drift-detection-status \
      --stack-drift-detection-id "$DRIFT_ID" --query DetectionStatus --output text)" = "DETECTION_IN_PROGRESS" ]; do
    sleep 3
  done
  aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$DRIFT_ID" \
    --query '[StackDriftStatus,DriftedStackResourceCount]' --output text
  aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" \
    --stack-resource-drift-status-filters MODIFIED DELETED \
    --query 'StackResourceDrifts[].[LogicalResourceId,StackResourceDriftStatus]' --output table
else
  echo "(could not run drift detection on ${STACK})"
fi

echo
echo "Saved to $OUT"
