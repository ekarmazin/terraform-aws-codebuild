data "aws_caller_identity" "default" {
}

data "aws_region" "default" {
}

# Define composite variables for resources
module "label" {
  source     = "git::https://github.com/cloudposse/terraform-terraform-label.git?ref=tags/0.4.0"
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

resource "aws_s3_bucket" "cache_bucket" {
  count         = var.enabled == "true" && var.cache_enabled == "true" ? "1" : "0"
  bucket        = local.cache_bucket_name_normalised
  acl           = "private"
  force_destroy = true
  tags          = module.label.tags

  lifecycle_rule {
    id      = "codebuildcache"
    enabled = true

    prefix = "/"
    tags   = module.label.tags

    expiration {
      days = var.cache_expiration_days
    }
  }
}

resource "random_string" "bucket_prefix" {
  length  = 12
  number  = false
  upper   = false
  special = false
  lower   = true
}

locals {
  cache_bucket_name = join("-", [module.label.id, var.cache_bucket_suffix_enabled == "true" ? random_string.bucket_prefix.result : "" ])

  ## Clean up the bucket name to use only hyphens, and trim its length to 63 characters.
  ## As per https://docs.aws.amazon.com/AmazonS3/latest/dev/BucketRestrictions.html
  cache_bucket_name_normalised = substr(
    join("-", split("_", lower(local.cache_bucket_name))),
    0,
    min(length(local.cache_bucket_name), 63),
  )

  ## This is the magic where a map of a list of maps is generated
  ## and used to conditionally add the cache bucket option to the
  ## aws_codebuild_project
  cache_def = {
    "true" = [
      {
        type     = "S3"
        location = var.enabled == "true" && var.cache_enabled == "true" ? join("", aws_s3_bucket.cache_bucket.*.bucket) : "none"
      },
    ]
    "false" = []
  }

  # Final Map Selected from above
  cache = local.cache_def[var.cache_enabled]
}

resource "aws_iam_role" "default" {
  count              = var.enabled == "true" ? "1" : "0"
  name               = module.label.id
  assume_role_policy = data.aws_iam_policy_document.role.json
}

data "aws_iam_policy_document" "role" {
  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_policy" "default" {
  count  = var.enabled == "true" ? "1" : "0"
  name   = module.label.id
  path   = "/service-role/"
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_iam_policy" "default_cache_bucket" {
  count  = var.enabled == "true" && var.cache_enabled == "true" ? "1" : "0"
  name   = join("-", [module.label.id, "cache-bucket"])
  path   = "/service-role/"
  policy = data.aws_iam_policy_document.permissions_cache_bucket[0].json
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid = ""

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetAuthorizationToken",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecs:RunTask",
      "iam:PassRole",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ssm:GetParameters",
    ]

    effect = "Allow"

    resources = [
      "*",
    ]
  }
}

data "aws_iam_policy_document" "permissions_cache_bucket" {
  count = var.enabled == "true" && var.cache_enabled == "true" ? "1" : "0"

  statement {
    sid = ""

    actions = [
      "s3:*",
    ]

    effect = "Allow"

    resources = [
      aws_s3_bucket.cache_bucket[0].arn,
      join("/",[aws_s3_bucket.cache_bucket[0].arn, "*"]),
    ]
  }
}

resource "aws_iam_role_policy_attachment" "default" {
  count      = var.enabled == "true" ? "1" : "0"
  policy_arn = aws_iam_policy.default[0].arn
  role       = aws_iam_role.default[0].id
}

resource "aws_iam_role_policy_attachment" "default_cache_bucket" {
  count      = var.enabled == "true" && var.cache_enabled == "true" ? "1" : "0"
  policy_arn = element(aws_iam_policy.default_cache_bucket.*.arn, count.index)
  role       = aws_iam_role.default[0].id
}

resource "aws_codebuild_project" "default" {
  count         = var.enabled == "true" ? "1" : "0"
  name          = module.label.id
  service_role  = aws_iam_role.default[0].arn
  badge_enabled = var.badge_enabled
  build_timeout = var.build_timeout

  artifacts {
    type = var.artifact_type
  }

  # The cache as a list with a map object inside.
  dynamic "cache" {
    for_each = [local.cache]
    content {
      # TF-UPGRADE-TODO: The automatic upgrade tool can't predict
      # which keys might be set in maps assigned here, so it has
      # produced a comprehensive set here. Consider simplifying
      # this after confirming which keys can be set in practice.

      location = lookup(cache, "location", "")
      type     = lookup(cache, "type", "")
    }
  }

  environment {
    compute_type    = var.build_compute_type
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = var.privileged_mode

    environment_variable {
      name  = "AWS_REGION"
      value = signum(length(var.aws_region)) == 1 ? var.aws_region : data.aws_region.default.name
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = signum(length(var.aws_account_id)) == 1 ? var.aws_account_id : data.aws_caller_identity.default.account_id
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = signum(length(var.image_repo_name)) == 1 ? var.image_repo_name : "UNSET"
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = signum(length(var.image_tag)) == 1 ? var.image_tag : "latest"
    }
    environment_variable {
      name  = "STAGE"
      value = signum(length(var.stage)) == 1 ? var.stage : "UNSET"
    }
    environment_variable {
      name  = "GITHUB_TOKEN"
      value = signum(length(var.github_token)) == 1 ? var.github_token : "UNSET"
    }
    dynamic "environment_variable" {
      for_each = [var.environment_variables]
      content {
        # TF-UPGRADE-TODO: The automatic upgrade tool can't predict
        # which keys might be set in maps assigned here, so it has
        # produced a comprehensive set here. Consider simplifying
        # this after confirming which keys can be set in practice.

        name  = environment_variable.value.name
        type  = lookup(environment_variable.value, "type", null)
        value = environment_variable.value.value
      }
    }
  }

  source {
    buildspec           = var.buildspec
    type                = var.source_type
    location            = var.source_location
    report_build_status = var.report_build_status
  }

  tags = module.label.tags
}

