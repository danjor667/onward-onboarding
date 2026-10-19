"""Fail the build if a template breaks the onboarding access rules.

Rules:
  1. No inline IAM policies: no AWS::IAM::Policy resources, and no `Policies`
     property on AWS::IAM::User, AWS::IAM::Group or AWS::IAM::Role.
  2. Every AWS::IAM::User has a PermissionsBoundary.
  3. Every AWS::IAM::User with a LoginProfile forces a password reset and takes
     its password from Secrets Manager.

Usage: python scripts/check_policy_rules.py TEMPLATE [TEMPLATE ...]
"""

import sys

import yaml

INLINE_CAPABLE_TYPES = {"AWS::IAM::User", "AWS::IAM::Group", "AWS::IAM::Role"}


class CfnLoader(yaml.SafeLoader):
    """SafeLoader that accepts CloudFormation short-form tags such as !Sub."""


def _construct_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    return {f"Fn::{tag_suffix}": value}


CfnLoader.add_multi_constructor("!", _construct_tag)


def check(path):
    with open(path) as f:
        template = yaml.load(f, Loader=CfnLoader)

    errors = []
    for name, resource in (template.get("Resources") or {}).items():
        rtype = resource.get("Type")
        props = resource.get("Properties") or {}

        if rtype == "AWS::IAM::Policy":
            errors.append(f"{name}: AWS::IAM::Policy is an inline policy; use AWS::IAM::ManagedPolicy")
        if rtype in INLINE_CAPABLE_TYPES and "Policies" in props:
            errors.append(f"{name}: inline `Policies` on {rtype}; attach managed policies instead")

        if rtype == "AWS::IAM::User":
            if "PermissionsBoundary" not in props:
                errors.append(f"{name}: user has no PermissionsBoundary")
            login = props.get("LoginProfile")
            if login is not None:
                if login.get("PasswordResetRequired") is not True:
                    errors.append(f"{name}: LoginProfile must set PasswordResetRequired: true")
                if "resolve:secretsmanager" not in str(login.get("Password")):
                    errors.append(f"{name}: LoginProfile password must come from Secrets Manager")
    return errors


def main(paths):
    failed = False
    for path in paths:
        errors = check(path)
        status = "FAIL" if errors else "PASS"
        print(f"[{status}] {path}")
        for error in errors:
            print(f"    - {error}")
        failed = failed or bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
