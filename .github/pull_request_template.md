## Access change

- **Who is affected:** <!-- e.g. new hire ec2-user-3 -->
- **Role / group:** <!-- storage-engineers | compute-engineers | oncall-observers -->
- **Ticket or approval reference:** <!-- e.g. HR-123 -->
- **Why:** <!-- one sentence -->

## Checklist

- [ ] No inline policies (`Policies:` on users, groups or roles; `AWS::IAM::Policy`)
- [ ] Every new user has a `PermissionsBoundary` and a Secrets Manager first-login password
- [ ] Reviewed the Git sync change summary on this pull request
