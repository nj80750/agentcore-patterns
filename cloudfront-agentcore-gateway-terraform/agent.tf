# =============================================================================
# Tool target 3 — an MCP server on AgentCore Runtime
# =============================================================================
#
# var.agent_enabled defaults to TRUE — this target ships with the pattern. It is
# gated on a variable only so a reader without Bedrock model access, or without uv,
# can still deploy the front door.
#
# It is also why deploying is two steps: agent/build.sh has to cross-compile the
# package for arm64 Linux before Terraform runs, because the artifact's hash is read
# at plan time.
#
# WHY THERE IS AN S3 BUCKET
#
# Not a choice. CreateAgentRuntime accepts exactly two artifact forms — a container
# image in ECR, or code in S3. There is no inline zip field, unlike Lambda's
# CreateFunction which takes a blob directly. So the code has to live somewhere the
# service can fetch it from, and S3 is the only address the API understands.

locals {
  # agentRuntimeName is validated against [a-zA-Z][a-zA-Z0-9_]{0,47} — no hyphens,
  # unlike every other name in this stack. project allows hyphens, so they are
  # replaced rather than left to fail deep inside an apply.
  agent_runtime_name = replace("${var.project}_agent", "-", "_")

  agent_zip_path = "${path.module}/agent/dist/agent.zip"

  # Whether the built artifact is actually on disk. Checked with fileexists() rather
  # than calling the hash functions straight away, because those are PLAN-TIME
  # functions: a missing zip makes them fail inside this locals block with a bare
  # "no such file" naming filesha256, which tells a reader nothing about build.sh.
  # Guarding here lets the precondition on aws_s3_object.agent_code report something
  # actionable instead.
  agent_zip_present = var.agent_enabled && fileexists(local.agent_zip_path)

  # The artifact's own hash, carried in the S3 key. AgentCore snapshots the code
  # when the Runtime is created or updated, so an unchanged bucket-and-key pair
  # leaves Terraform seeing no change while the Runtime quietly keeps running the
  # previous build. Putting the hash in the key makes a rebuilt zip a visible diff.
  agent_zip_hash = local.agent_zip_present ? filesha256(local.agent_zip_path) : ""

  # Also computed behind the conditional, for the same reason. A file function
  # placed directly in a resource body is evaluated even when count is 0, so
  # `agent_enabled = false` would fail on a missing zip — which would defeat the
  # entire point of that default.
  agent_zip_md5 = local.agent_zip_present ? filemd5(local.agent_zip_path) : ""

  # substr() would itself fail on the empty placeholder above, so the key only
  # carries a hash when there is one to carry. The precondition below stops the run
  # long before this placeholder could reach S3.
  agent_zip_key = "agent/agent-${local.agent_zip_present ? substr(local.agent_zip_hash, 0, 16) : "pending"}.zip"

  # The Gateway addresses the Runtime through the control-plane invocations URL, and
  # the ARN inside that path has to be percent-encoded.
  agent_runtime_arn_encoded = var.agent_enabled ? replace(
    replace(aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_arn, ":", "%3A"),
    "/", "%2F"
  ) : ""

  agent_mcp_endpoint = var.agent_enabled ? join("", [
    "https://bedrock-agentcore.${data.aws_region.current.region}.amazonaws.com",
    "/runtimes/${local.agent_runtime_arn_encoded}/invocations",
    "?qualifier=DEFAULT",
  ]) : ""
}


# --- The deployment package ---------------------------------------------------

resource "aws_s3_bucket" "agent_code" {
  count = var.agent_enabled ? 1 : 0

  # Bucket names are globally unique, so account and region are part of the name.
  bucket        = "${var.project}-agent-code-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "agent_code" {
  count = var.agent_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.agent_code[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "agent_code" {
  count = var.agent_enabled ? 1 : 0

  bucket = aws_s3_bucket.agent_code[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "agent_code" {
  count = var.agent_enabled ? 1 : 0

  bucket = aws_s3_bucket.agent_code[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "agent_code" {
  count = var.agent_enabled ? 1 : 0

  bucket = aws_s3_bucket.agent_code[0].id
  key    = local.agent_zip_key
  source = local.agent_zip_path

  # source_hash, NOT etag. The zip is large enough that S3 stores it as a multipart
  # upload, and a multipart ETag is a hash of the part hashes with a "-<n>" suffix —
  # it is not the MD5 of the file and can never equal filemd5(). Using etag here
  # produces a diff on every plan, forever. source_hash exists for this case.
  source_hash = local.agent_zip_md5

  depends_on = [aws_s3_bucket_ownership_controls.agent_code]

  lifecycle {
    # The one thing a reader can get wrong here: turning the agent on without
    # building it. Without this they get "Error in function call ... filesha256",
    # twice, naming neither the agent nor the build script.
    precondition {
      condition     = local.agent_zip_present
      error_message = <<-EOT
        agent_enabled = true, but agent/dist/agent.zip does not exist.

        Build it first, then re-run terraform apply:

            ./agent/build.sh

        Terraform cannot build this itself. The package needs its dependencies
        compiled for arm64 Linux, which archive_file cannot do, and the artifact's
        hash is read at plan time — before any provisioner could create it. That is
        why building is a separate first step rather than part of the apply.

        If you cannot install uv or do not have Bedrock model access, set
        agent_enabled = false to deploy without this target.
      EOT
    }
  }
}


# --- The Runtime's execution role --------------------------------------------

data "aws_iam_policy_document" "agent_runtime_trust" {
  count = var.agent_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*",
      ]
    }
  }
}

resource "aws_iam_role" "agent_runtime" {
  count = var.agent_enabled ? 1 : 0

  name               = "${var.project}-agent-runtime-role"
  description        = "Execution role for the AgentCore Runtime MCP server."
  assume_role_policy = data.aws_iam_policy_document.agent_runtime_trust[0].json
}

resource "aws_iam_role_policy" "agent_runtime" {
  count = var.agent_enabled ? 1 : 0

  name = "runtime"
  role = aws_iam_role.agent_runtime[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Reading the deployment package. The Runtime cannot start without this, and
        # the failure is a start-up error that does not mention S3.
        Sid      = "ReadDeploymentPackage"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.agent_code[0].arn}/*"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/*"
      },
      {
        # The Runtime emits its own operational metrics.
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        # Calling the model. Both actions are needed: a cross-region inference
        # profile is itself an invokable resource, and invoking it fans out to the
        # underlying foundation models, so the policy has to permit both the profile
        # and the models behind it.
        Sid    = "InvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
        ]
      },
    ]
  })
}


# --- The Runtime -------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  count = var.agent_enabled ? 1 : 0

  agent_runtime_name = local.agent_runtime_name
  description        = "MCP server exposed as an AgentCore Gateway target."
  role_arn           = aws_iam_role.agent_runtime[0].arn

  agent_runtime_artifact {
    code_configuration {
      # A bare command. AWS's example prefixes this with opentelemetry-instrument,
      # which is omitted here because the OTel packages are not vendored — adding
      # the prefix without them fails at start-up.
      entry_point = ["main.py"]

      # Must match PYTHON_VERSION in agent/build.sh, or the vendored wheels are for
      # the wrong interpreter ABI.
      runtime = "PYTHON_3_12"

      code {
        s3 {
          bucket = aws_s3_bucket.agent_code[0].id
          prefix = aws_s3_object.agent_code[0].key
        }
      }
    }
  }

  # MCP rather than HTTP. The Gateway can attach an MCP endpoint through its
  # mcp_server target; there is no dedicated AgentCore Runtime target type in the
  # provider, so the HTTP shape would leave this unattachable from Terraform.
  protocol_configuration {
    server_protocol = "MCP"
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  # Read by main.py at invocation time. Parameter-driven so the model can be
  # changed without touching the agent source or rebuilding the artifact.
  environment_variables = {
    MODEL_ID = var.agent_model_id
  }
}


# --- Letting the Gateway invoke it -------------------------------------------
#
# Kept as its own policy resource rather than another statement in gateway_targets,
# because the Gateway declares depends_on that policy. Folding the Runtime ARN into
# it would make the Gateway wait on the Runtime — an ordering coupling between two
# things with no real relationship, and one that bites the moment agent_enabled is
# toggled.

resource "aws_iam_role_policy" "gateway_invoke_agent_runtime" {
  count = var.agent_enabled ? 1 : 0

  name = "invoke-agent-runtime"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "InvokeAgentRuntime"
      Effect = "Allow"
      Action = ["bedrock-agentcore:InvokeAgentRuntime"]
      # The Runtime's generated ID is a suffix on the name, so this is a prefix
      # match rather than an exact ARN — the policy must exist before the target is
      # created, and the target creation is what needs the permission.
      Resource = [
        "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:runtime/${local.agent_runtime_name}-*",
      ]
    }]
  })
}


# --- The target --------------------------------------------------------------

resource "aws_bedrockagentcore_gateway_target" "agent" {
  count = var.agent_enabled ? 1 : 0

  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = "helloAgent"
  description        = "AgentCore Runtime-backed MCP server. Greets the caller and names the region that answered."

  target_configuration {
    mcp {
      mcp_server {
        endpoint = local.agent_mcp_endpoint

        # DEFAULT, stated rather than inherited. In DEFAULT mode the Gateway
        # synchronises the tool catalog at target creation and folds it into the
        # unified listing. DYNAMIC defers discovery to invocation time, which means
        # the target could be created successfully while being entirely unreachable.
        # DEFAULT fails loudly at create time instead.
        listing_mode = "DEFAULT"
      }
    }
  }

  credential_provider_configuration {
    gateway_iam_role {
      # REQUIRED here, unlike the Lambda and API Gateway targets where an empty
      # block lets AgentCore infer the signing service from the target type. An
      # mcp_server target is just a URL, so there is nothing to infer from.
      service = "bedrock-agentcore"
    }
  }

  # Target creation performs a real tools/list against the endpoint, so the
  # permission must be in place first or creation fails with a synchronisation
  # error that says nothing about IAM.
  depends_on = [aws_iam_role_policy.gateway_invoke_agent_runtime]
}
