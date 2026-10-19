# Onward Logistics: Secure Onboarding at Scale

New-engineer AWS access, defined as code and deployed by CloudFormation Git sync.
Every change is a reviewed pull request, every engineer gets a generated first-login
password they must change, and the on-call engineer can never create or terminate
compute, even if someone later attaches more permissions.

| Engineer | Group (what they get) | Permissions boundary (the most they can ever get) |
| --- | --- | --- |
| `s3-user` | `AmazonS3FullAccess` | S3 only |
| `ec2-user-1` | `AmazonEC2FullAccess` | EC2, ELB, Auto Scaling, CloudWatch; no `iam:PassRole` |
| `ec2-user-2` | `AmazonEC2ReadOnlyAccess` | Describe/Get/List only; explicit deny on run, start, stop, terminate |

Every group also has `IAMUserChangePassword` so engineers can complete the forced reset.
Diagrams: [docs/architecture.md](docs/architecture.md).

## Repository layout

```
onboarding.yaml                  Users, groups, boundaries, secrets, CloudTrail
stack-config.yaml                Git sync stack deployment file (parameters + tags)
pipeline-roles.yaml              One-time: Git sync role + scoped CloudFormation execution role
scripts/verify.sh                Evidence: access matrix and the "add more permissions" stress test
scripts/audit.sh                 Evidence: Git history, CloudTrail IAM events, drift detection
scripts/get-initial-password.sh  Read a new hire's first-login password from Secrets Manager
scripts/check_policy_rules.py    CI rule: no inline policies, boundary + secret on every user
.github/                         CI workflow, CODEOWNERS, pull request template
```

## Design decisions

- **Groups grant, boundaries cap.** Groups use AWS managed policies, so there are no
  policies written per person. A boundary is set on each user and is shared by
  everyone in that role. AWS allows an action only if both the group (or user)
  policies **and** the boundary allow it. That is why attaching `AdministratorAccess`
  to `ec2-user-2` later changes nothing for compute.
- **No inline policies.** All IAM permissions are managed policies. The only
  `PolicyDocument` on a non-IAM resource is the S3 bucket policy required by
  CloudTrail. It is a resource policy, not an inline IAM policy. `scripts/check_policy_rules.py` enforces this in CI.
- **No plain-text credentials.** Secrets Manager generates each password, and the
  template passes it to the login profile through a dynamic reference. It never appears in Git,
  the template or the stack parameters. `PasswordResetRequired: true` forces a change at
  first sign-in.
- **Traceable changes.** Git shows who proposed and approved each change. Git sync makes
  merged pull requests the only deployment path. CloudTrail (multi-region, global events,
  log-file validation, retained bucket) records every IAM call, including any made outside the
  template.
- **Least-privilege pipeline.** CloudFormation runs as a scoped execution role that can only
  touch IAM entities under the `/onward/` path, attach the four approved AWS managed policies,
  and set only `/onward/boundaries/` policies as boundaries.

## Deploy

Region: **eu-central-1 (Frankfurt)**. Create the connection and both stacks there, and select
Frankfurt in the console before step 4. IAM users, groups and boundaries are global; the secrets,
stacks, trail and log bucket live in Frankfurt.

1. **Create the GitHub repository** `onward-onboarding` and push this folder to `master`. Turn on branch
   protection for `master`: require a pull request, one approval, CODEOWNERS review and the
   `validate` check. `.github/CODEOWNERS` names the approver (currently `@danjor667`).
2. **Connect GitHub to AWS.** Create a CodeConnections connection to GitHub. Approving the GitHub
   app is an OAuth handshake, so it has to happen in a browser:
   ```bash
   aws codeconnections create-connection --region eu-central-1 --provider-type GitHub --connection-name onward-github
   # then open Developer Tools > Settings > Connections in the console and choose "Update pending connection"
   ```
3. **Bootstrap the roles** (once):
   ```bash
   aws cloudformation deploy --region eu-central-1 \
     --stack-name onward-gitsync-bootstrap \
     --template-file pipeline-roles.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides ConnectionArn=<connection-arn>
   aws cloudformation describe-stacks --region eu-central-1 --stack-name onward-gitsync-bootstrap --query 'Stacks[0].Outputs'
   ```
4. **Create the Git sync stack.** In CloudFormation, choose **Create stack**, then **Sync from Git**, and set:
   - Stack name `onward-onboarding`, with your repository and branch `master`.
   - Deployment file path `stack-config.yaml`.
   - IAM role = `GitSyncRoleArn`.
   - Under stack options, IAM role = `CloudFormationExecutionRoleArn`.
   - Turn on **comments on pull requests**.

   From then on, merging a change deploys it.
5. **Hand over first-login passwords** through a secure channel:
   ```bash
   scripts/get-initial-password.sh s3-user
   ```

## Onboard the next engineer

Copy the `…InitialPassword` secret and the `AWS::IAM::User` block for the role, change the
username in both, and open a pull request. The new user gets the same group, the same boundary
and a new generated password. Nothing is written per person.

## Prove it (evidence for the Head of Security)

| Objective | How to prove it |
| --- | --- |
| 1. Each engineer can do their job and no more | `scripts/verify.sh` produces an allowed/denied matrix per user from the IAM policy simulator. Back it up with console screenshots: s3-user lists buckets, but EC2 shows "not authorized". |
| 2. Secure first login | Show the secret in Secrets Manager with no password in Git (`git grep -i password`). Record the first sign-in being forced to change the password. |
| 3. On-call can never create or terminate compute | `scripts/verify.sh --stress` attaches `AdministratorAccess` to the on-call group and user, shows `RunInstances` and `TerminateInstances` still denied, then removes it. In the console as `ec2-user-2`, Launch instance fails. |
| 4. Repeatable and auditable | `scripts/audit.sh` shows Git history, stack deployments, CloudTrail IAM events (including the stress-test attachments) and drift status. Show a pull request with the Git sync change summary and approval. |
| 5. Rebuild from the repository | Delete the stack and recreate it from Git sync. The same users, groups and boundaries come back. Audit logs survive because the bucket is retained. |

Evidence files are written to `evidence/`, which is ignored by Git and should be attached to the submission.

## Validate locally

```bash
pip install cfn-lint pyyaml
cfn-lint onboarding.yaml pipeline-roles.yaml
python scripts/check_policy_rules.py onboarding.yaml pipeline-roles.yaml
```

## Known limits

- An administrator with full IAM rights can still remove a boundary. This is detected
  (CloudTrail, drift) but not prevented. An AWS Organizations SCP would prevent it.
- MFA isn't enforced, and IAM users have long-lived passwords. AWS IAM Identity Center is the
  long-term direction.
- Storage and compute access covers all buckets and instances in the account. Scope it by tag
  once naming standards exist.
