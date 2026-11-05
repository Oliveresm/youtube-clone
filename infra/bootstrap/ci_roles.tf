locals {
  github_repository = "Oliveresm/youtube-clone"
  oidc_host         = "token.actions.githubusercontent.com"
  account_id        = data.aws_caller_identity.current.account_id

  app_deploy_role_name = "youtube-clone-app-deploy"
  infra_role_name      = "youtube-clone-infra"
  boundary_policy_name = "youtube-clone-infra-boundary"
}

# ---------------------------------------------------------------------------
# Trust policies (arch section 7): StringEquals on both aud and sub, no wildcards.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "app_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${local.github_repository}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "infra_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${local.github_repository}:environment:infra"]
    }
  }
}

# ---------------------------------------------------------------------------
# youtube-clone-app-deploy: no permissions yet (added in Phase 7, T7.1).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "app_deploy" {
  name               = local.app_deploy_role_name
  assume_role_policy = data.aws_iam_policy_document.app_deploy_trust.json
}

# ---------------------------------------------------------------------------
# youtube-clone-infra permissions boundary: Allow everything, explicit Deny on
# the bootstrap resources.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "infra_boundary" {
  statement {
    sid       = "AllowAll"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid     = "DenyIamOnCiRolesAndOidcProvider"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/${local.app_deploy_role_name}",
      "arn:aws:iam::${local.account_id}:role/${local.infra_role_name}",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  # Without this, the role could rewrite the boundary through CreatePolicyVersion
  # (it matches youtube-clone-*) and drop every Deny.
  statement {
    sid       = "DenyIamOnBoundaryPolicy"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${local.account_id}:policy/${local.boundary_policy_name}"]
  }

  statement {
    sid       = "DenyUsersAndAccessKeys"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyStateBucketConfiguration"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket*",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutReplicationConfiguration",
      "s3:PutAccelerateConfiguration",
      "s3:PutAnalyticsConfiguration",
      "s3:PutInventoryConfiguration",
      "s3:PutMetricsConfiguration",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  # Only main/ is writable; reads of bootstrap/ stay allowed.
  statement {
    sid    = "DenyWritesOnBootstrapStateKeys"
    effect = "Deny"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:PutObjectTagging",
      "s3:DeleteObjectTagging",
    ]
    resources = ["${aws_s3_bucket.state.arn}/bootstrap/*"]
  }

  statement {
    sid    = "DenyBudgetChanges"
    effect = "Deny"
    actions = [
      "budgets:Create*",
      "budgets:Modify*",
      "budgets:Update*",
      "budgets:Delete*",
      "budgets:Execute*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyOrganizationsAndAccount"
    effect    = "Deny"
    actions   = ["organizations:*", "account:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "infra_boundary" {
  name   = local.boundary_policy_name
  policy = data.aws_iam_policy_document.infra_boundary.json
}

# ---------------------------------------------------------------------------
# youtube-clone-infra: PowerUserAccess + inline IAM policy limited to
# youtube-clone-* roles and policies. The patterns also match the CI roles and
# the boundary; the boundary Deny is what protects them.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "infra" {
  name                 = local.infra_role_name
  assume_role_policy   = data.aws_iam_policy_document.infra_trust.json
  permissions_boundary = aws_iam_policy.infra_boundary.arn
}

resource "aws_iam_role_policy_attachment" "infra_power_user" {
  role       = aws_iam_role.infra.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "infra_iam" {
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/youtube-clone-*"]
  }

  statement {
    sid    = "ManageProjectPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags",
    ]
    resources = ["arn:aws:iam::${local.account_id}:policy/youtube-clone-*"]
  }

  statement {
    sid       = "PassProjectRolesToPipelineServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/youtube-clone-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "lambda.amazonaws.com",
        "mediaconvert.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "infra_iam" {
  name   = "youtube-clone-infra-iam"
  role   = aws_iam_role.infra.id
  policy = data.aws_iam_policy_document.infra_iam.json
}
