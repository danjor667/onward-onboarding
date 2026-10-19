# Architecture

## How a change to access reaches AWS

```mermaid
flowchart LR
    dev[Engineer or admin<br/>opens pull request] --> pr[GitHub pull request<br/>CI: cfn-lint + policy rules<br/>CODEOWNERS: security approves]
    pr -->|merge to master| repo[(GitHub repo<br/>onboarding.yaml<br/>stack-config.yaml)]
    repo -->|CodeConnections| sync[CloudFormation Git sync<br/>assumes onward-gitsync-role]
    sync -->|change set, passes| exec[onward-cfn-execution-role<br/>scoped to /onward/ IAM path]
    exec --> stack[Stack: onward-onboarding]
    stack --> iam[IAM users, groups,<br/>boundaries]
    stack --> sm[Secrets Manager<br/>first-login passwords]
    stack --> ct[CloudTrail trail<br/>+ log bucket]
```

## How access is controlled

Effective permissions are the **intersection** of what the group grants and
what the boundary allows. An explicit deny anywhere always wins.

```mermaid
flowchart TB
    subgraph S3[Storage engineer]
        u1[s3-user] --> g1[onward-storage-engineers<br/>AmazonS3FullAccess<br/>IAMUserChangePassword]
        u1 -. boundary .-> b1[onward-boundary-storage-engineer<br/>allow s3:*<br/>deny account public-access changes]
    end
    subgraph C[Compute engineer]
        u2[ec2-user-1] --> g2[onward-compute-engineers<br/>AmazonEC2FullAccess<br/>IAMUserChangePassword]
        u2 -. boundary .-> b2[onward-boundary-compute-engineer<br/>allow ec2, elb, autoscaling, cloudwatch<br/>no iam:PassRole]
    end
    subgraph O[On-call engineer]
        u3[ec2-user-2] --> g3[onward-oncall-observers<br/>AmazonEC2ReadOnlyAccess<br/>IAMUserChangePassword]
        u3 -. boundary .-> b3[onward-boundary-oncall-observer<br/>allow Describe/Get/List only<br/>DENY Run/Start/Stop/Terminate/CreateFleet]
        x[Later: AdministratorAccess added<br/>to group or user] -.-> g3
        x -. still capped by .-> b3
    end
    sm[(Secrets Manager<br/>onward/onboarding/&lt;user&gt;/initial-password)] -->|dynamic reference,<br/>PasswordResetRequired| u1 & u2 & u3
```
