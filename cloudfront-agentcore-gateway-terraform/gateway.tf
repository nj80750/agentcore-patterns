# =============================================================================
# The Gateway's own role — outbound auth to its targets
# =============================================================================

data "aws_iam_policy_document" "gateway_trust" {
  statement {
    sid     = "GatewayAssumeRolePolicy"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    # Confused-deputy guards. Scoping SourceArn to one specific gateway ARN is not
    # possible here: the role must exist before the gateway, and the gateway's ID
    # is generated. A wildcard over this account and region is the tightest form
    # that still applies from the very first apply.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:gateway/*",
      ]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.project}-gateway-role"
  description        = "Assumed by AgentCore Gateway to invoke its targets."
  assume_role_policy = data.aws_iam_policy_document.gateway_trust.json
}

data "aws_iam_policy_document" "gateway_targets" {
  # Same-account Lambda, so an identity-based policy is enough. A resource-based
  # policy on the function is only required cross-account.
  statement {
    sid       = "InvokeLambdaTarget"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.hello.arn]
  }

  # The execute-api ARN's trailing segments are METHOD/PATH. Kept as the
  # documented "/*/*" rather than naming GET/hello and PUT/hello: the Gateway may
  # probe the stage while creating the target, and a 403 there surfaces as a
  # validation failure with nothing pointing at IAM. Still scoped to this one API
  # and this one stage.
  statement {
    sid     = "InvokeApiGatewayTarget"
    effect  = "Allow"
    actions = ["execute-api:Invoke"]
    resources = [
      "arn:${data.aws_partition.current.partition}:execute-api:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.hello.id}/${aws_api_gateway_stage.hello.stage_name}/*/*",
    ]
  }
}

resource "aws_iam_role_policy" "gateway_targets" {
  name   = "invoke-targets"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway_targets.json
}


# =============================================================================
# The Gateway — an OAuth 2.0 resource server speaking MCP
# =============================================================================
#
# CUSTOM_JWT makes the Gateway validate bearer tokens itself. It reads the
# discovery document for signing keys, checks each token, and answers an
# unauthenticated request with 401 plus a WWW-Authenticate header.
#
# protocol_configuration is deliberately omitted, leaving MCP sessions at their
# default. Stateful sessions bind a conversation to one region, which becomes a
# problem the moment you put more than one region behind this front door.

resource "aws_bedrockagentcore_gateway" "mcp" {
  name            = "${var.project}-gateway"
  description     = "MCP server fronted by CloudFront on a custom domain."
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = local.discovery_url

      # Exactly one of these is populated. Cognito tokens carry client_id and no
      # aud; Okta, Entra and Auth0 carry aud. Setting the wrong one produces a 403
      # on every call that looks identical to a scope problem.
      #
      # null rather than [] is load-bearing. The API rejects an empty list outright:
      #
      #   Value '[]' at 'authorizerConfiguration.customJWTAuthorizer.allowedAudience'
      #   failed to satisfy constraint: Member must have length greater than or
      #   equal to 1
      #
      # So "not used" has to be expressed as omission, and in Terraform that means
      # null. An empty list is a value, and the API validates it.
      allowed_clients  = length(local.allowed_clients) > 0 ? local.allowed_clients : null
      allowed_audience = length(local.allowed_audience) > 0 ? local.allowed_audience : null
      allowed_scopes   = length(local.allowed_scopes) > 0 ? local.allowed_scopes : null
    }
  }

  lifecycle {
    precondition {
      condition     = var.auth_mode != "external" || var.oidc_discovery_url != ""
      error_message = "auth_mode is \"external\", so oidc_discovery_url must be set."
    }

    precondition {
      condition = var.auth_mode != "external" || (
        length(var.oidc_allowed_audience) > 0 || length(var.oidc_allowed_clients) > 0
      )
      error_message = "auth_mode is \"external\", so set oidc_allowed_audience (Okta, Entra, Auth0) or oidc_allowed_clients (Cognito). Without one of them the Gateway accepts any token its issuer signed."
    }

    precondition {
      condition     = !(length(var.oidc_allowed_audience) > 0 && length(var.oidc_allowed_clients) > 0)
      error_message = "Set oidc_allowed_audience OR oidc_allowed_clients, not both. The behaviour when both are populated is not documented."
    }
  }

  depends_on = [aws_iam_role_policy.gateway_targets]
}


# =============================================================================
# Targets — what turns the two backends into MCP tools
# =============================================================================
#
# TARGET NAMES ARE LOAD-BEARING. The Gateway publishes every tool as
#
#     <target name>___<tool name>          (three underscores)
#
# so "helloLambda" produces "helloLambda___say_hello", and the Lambda strips that
# prefix to find its own tool name. Renaming a target renames the tool for every
# connected client.

resource "aws_bedrockagentcore_gateway_target" "lambda_hello" {
  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = "helloLambda"
  description        = "Lambda-backed hello world tool."

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.hello.arn

        # A Lambda target has no schema to discover — unlike API Gateway there is
        # no OpenAPI document to read — so the contract is declared here. This
        # description is the only thing a model sees, so it decides whether the
        # tool gets chosen correctly.
        tool_schema {
          inline_payload {
            name        = "say_hello"
            description = "Returns a greeting naming AWS Lambda as the component that produced it, and the AWS region it ran in. Takes no arguments."

            # An object with no properties: the tool takes no arguments, and there
            # is nothing for a model to fill in incorrectly.
            input_schema {
              type        = "object"
              description = "No input required."
            }
          }
        }
      }
    }
  }

  credential_provider_configuration {
    # Empty by design. Both attributes are optional, and leaving them unset lets
    # AgentCore derive the signing service from the target type.
    gateway_iam_role {}
  }
}

resource "aws_bedrockagentcore_gateway_target" "api_hello" {
  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = "helloApi"
  description        = "API Gateway-backed hello world tools (GET and PUT)."

  target_configuration {
    mcp {
      api_gateway {
        rest_api_id = aws_api_gateway_rest_api.hello.id
        stage       = aws_api_gateway_stage.hello.stage_name

        # Creating this target makes AgentCore call GetExport on the stage using
        # the CALLER's credentials through a forward access session — not the
        # gateway role. So whoever runs Terraform needs read access to this API.
        api_gateway_tool_configuration {
          # An allow list, not a hint. Only these method and path pairs become
          # tools; anything added to the API later stays invisible until named.
          tool_filter {
            filter_path = "/hello"
            methods     = ["GET", "PUT"]
          }
        }
      }
    }
  }

  credential_provider_configuration {
    gateway_iam_role {}
  }
}
