#!/usr/bin/env bash
# Prove each engineer's access with the IAM policy simulator. The simulator
# evaluates the user's real group policies, user policies and permissions
# boundary, so no engineer credentials are needed.
#
# Usage:
#   scripts/verify.sh            # day-one access matrix
#   scripts/verify.sh --stress   # also attach AdministratorAccess to the on-call
#                                # group and user, re-test, then detach it
#
# Run as an admin. Output is also saved under evidence/.
set -euo pipefail

PREFIX="${PROJECT_PREFIX:-onward}"
ONCALL_GROUP="${PREFIX}-oncall-observers"
ADMIN_POLICY="arn:aws:iam::aws:policy/AdministratorAccess"
STRESS=false
[ "${1:-}" = "--stress" ] && STRESS=true

mkdir -p evidence
OUT="evidence/verify-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$OUT") 2>&1

FAILURES=0

user_arn() {
  aws iam get-user --user-name "$1" --query 'User.Arn' --output text
}

# expect USER ACTION allowed|denied
# iam:* self-service actions are tested against the user's own ARN; everything
# else against "*".
expect() {
  local user="$1" action="$2" want="$3" arn resource decision got mark
  arn=$(user_arn "$user")
  resource="*"
  case "$action" in iam:*) resource="$arn" ;; esac
  decision=$(aws iam simulate-principal-policy \
    --policy-source-arn "$arn" \
    --action-names "$action" \
    --resource-arns "$resource" \
    --context-entries "ContextKeyName=aws:username,ContextKeyValues=${user},ContextKeyType=string" \
    --query 'EvaluationResults[0].EvalDecision' --output text)
  case "$decision" in
    allowed) got=allowed ;;
    *) got=denied ;;
  esac
  if [ "$got" = "$want" ]; then mark=PASS; else mark=FAIL; FAILURES=$((FAILURES + 1)); fi
  printf '%-5s %-11s %-34s expected=%-8s actual=%s\n' "$mark" "$user" "$action" "$want" "$decision"
}

day_one_matrix() {
  echo "== s3-user (storage engineer) =="
  expect s3-user s3:ListAllMyBuckets allowed
  expect s3-user s3:PutObject allowed
  expect s3-user s3:GetObject allowed
  expect s3-user ec2:DescribeInstances denied
  expect s3-user ec2:RunInstances denied
  expect s3-user iam:CreateUser denied
  expect s3-user iam:ChangePassword allowed

  echo "== ec2-user-1 (compute engineer) =="
  expect ec2-user-1 ec2:DescribeInstances allowed
  expect ec2-user-1 ec2:RunInstances allowed
  expect ec2-user-1 ec2:TerminateInstances allowed
  expect ec2-user-1 s3:ListAllMyBuckets denied
  expect ec2-user-1 iam:PassRole denied
  expect ec2-user-1 iam:CreateUser denied
  expect ec2-user-1 iam:ChangePassword allowed

  echo "== ec2-user-2 (on-call observer) =="
  oncall_matrix
}

oncall_matrix() {
  expect ec2-user-2 ec2:DescribeInstances allowed
  expect ec2-user-2 ec2:DescribeInstanceStatus allowed
  expect ec2-user-2 cloudwatch:GetMetricStatistics allowed
  expect ec2-user-2 ec2:RunInstances denied
  expect ec2-user-2 ec2:TerminateInstances denied
  expect ec2-user-2 ec2:StopInstances denied
  expect ec2-user-2 ec2:CreateFleet denied
  expect ec2-user-2 autoscaling:SetDesiredCapacity denied
  expect ec2-user-2 s3:ListAllMyBuckets denied
  expect ec2-user-2 iam:DeleteUserPermissionsBoundary denied
  expect ec2-user-2 iam:ChangePassword allowed
}

cleanup_stress() {
  echo "-- removing test permissions --"
  aws iam detach-group-policy --group-name "$ONCALL_GROUP" --policy-arn "$ADMIN_POLICY" 2>/dev/null || true
  aws iam detach-user-policy --user-name ec2-user-2 --policy-arn "$ADMIN_POLICY" 2>/dev/null || true
}

echo "Onboarding access verification - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Caller: $(aws sts get-caller-identity --query Arn --output text)"
echo "Boundary on ec2-user-2: $(aws iam get-user --user-name ec2-user-2 \
  --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
echo

day_one_matrix

if $STRESS; then
  echo
  echo "== STRESS TEST: AdministratorAccess attached to ${ONCALL_GROUP} and ec2-user-2 =="
  trap cleanup_stress EXIT
  aws iam attach-group-policy --group-name "$ONCALL_GROUP" --policy-arn "$ADMIN_POLICY"
  aws iam attach-user-policy --user-name ec2-user-2 --policy-arn "$ADMIN_POLICY"
  echo "Attached policies on group: $(aws iam list-attached-group-policies --group-name "$ONCALL_GROUP" \
    --query 'AttachedPolicies[].PolicyName' --output text)"
  echo "Attached policies on user:  $(aws iam list-attached-user-policies --user-name ec2-user-2 \
    --query 'AttachedPolicies[].PolicyName' --output text)"
  sleep 10 # let IAM propagate the attachment
  oncall_matrix
  cleanup_stress
  trap - EXIT
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "RESULT: all checks passed. Saved to $OUT"
else
  echo "RESULT: $FAILURES check(s) failed. Saved to $OUT"
  exit 1
fi
