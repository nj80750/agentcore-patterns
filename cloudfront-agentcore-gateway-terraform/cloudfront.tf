# =============================================================================
# Lambda@Edge — the protected-resource document
# =============================================================================
#
# Constraints, all hard failures rather than warnings:
#
#   us-east-1 only     whatever regions it later runs in
#   x86_64 only        arm64 is rejected, unlike the Lambda target
#   no env vars        hence templating config into the source
#   published version  CloudFront cannot associate $LATEST
#   edgelambda trust   the role must be assumable by edgelambda.amazonaws.com too
#
# A CloudFront Function would be enough for this one function on its own. Lambda@Edge
# is used because this pattern is phase one of a multi-region design whose edge also
# runs an origin-request router reading a regional flag from DynamoDB, which a
# CloudFront Function cannot do — it has no network access.

data "aws_iam_policy_document" "edge_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "lambda.amazonaws.com",
        # Without this the function deploys fine and CloudFront refuses to
        # associate it, with an error that never mentions trust policies.
        "edgelambda.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "prm_edge" {
  provider = aws.us_east_1

  name               = "${var.project}-prm-edge-role"
  description        = "Lambda@Edge role for the OAuth protected-resource document."
  assume_role_policy = data.aws_iam_policy_document.edge_trust.json
}

resource "aws_iam_role_policy" "prm_edge_logs" {
  provider = aws.us_east_1

  name = "logs"
  role = aws_iam_role.prm_edge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      # Lambda@Edge writes logs into the region NEAREST THE VIEWER, in a log group
      # named /aws/lambda/us-east-1.<function-name>. There is no single log group to
      # point at and they cannot be pre-created, so the region is a wildcard.
      Resource = "arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
    }]
  })
}

data "archive_file" "prm_edge" {
  type        = "zip"
  output_path = "${path.module}/.build/prm-edge.zip"

  source {
    filename = "index.js"
    content = templatefile("${path.module}/lambda/prm/index.js.tftpl", {
      # jsonencode so these arrive as JS array literals.
      authorization_servers = jsonencode([local.issuer])
      scopes_supported      = jsonencode(local.prm_scopes)
    })
  }
}

resource "aws_lambda_function" "prm_edge" {
  provider = aws.us_east_1

  function_name = "${var.project}-prm-edge"
  description   = "Serves OAuth protected resource metadata naming the front door."
  role          = aws_iam_role.prm_edge.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"

  # Not a preference. Lambda@Edge rejects arm64.
  architectures = ["x86_64"]

  filename         = data.archive_file.prm_edge.output_path
  source_code_hash = data.archive_file.prm_edge.output_base64sha256

  # Required: CloudFront can only associate a numbered version.
  publish = true

  # Viewer-request functions are capped at 5s and 128 MB. This one concatenates
  # strings, so the floor is ample.
  timeout     = 5
  memory_size = 128

  depends_on = [aws_iam_role_policy.prm_edge_logs]
}


# =============================================================================
# The distribution
# =============================================================================

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# THE IMPORTANT ONE. AllViewer would forward the viewer's Host header, and the
# Gateway would receive a Host naming CloudFront rather than itself — which it
# rejects with 400 Invalid GatewayId, because it derives its gateway ID from the
# first label of Host.
#
# This variant forwards everything EXCEPT Host, and AWS documents that CloudFront
# then substitutes the origin's own domain name. That is exactly what the Gateway
# needs, and it is why a single-region front door requires no routing function.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "mcp" {
  enabled     = true
  comment     = "${var.project} MCP front door -> AgentCore Gateway"
  price_class = var.cloudfront_price_class

  # Attached only once the certificate is ISSUED. Note that an alternate domain
  # name can belong to exactly ONE distribution account-wide.
  aliases = local.domain_attached ? [var.custom_domain] : []

  # HTTP/2 only. Some MCP clients and proxies handle h3 inconsistently and there is
  # nothing to gain here — this is an API, not a media endpoint.
  http_version    = "http2"
  is_ipv6_enabled = true

  origin {
    origin_id   = "agentcore-gateway"
    domain_name = local.gateway_host

    # No origin_path. Requests must reach the Gateway with their path intact
    # because both /mcp and /.well-known/... are served through this one
    # distribution. Setting origin_path = "/mcp" would rewrite the discovery path
    # to /mcp/.well-known/... and 404.
    custom_origin_config {
      origin_protocol_policy = "https-only"
      http_port              = 80
      https_port             = 443
      origin_ssl_protocols   = ["TLSv1.2"]

      origin_read_timeout      = var.origin_read_timeout
      origin_keepalive_timeout = 60
    }
  }

  # --- MCP traffic: a transparent proxy ------------------------------------
  default_cache_behavior {
    target_origin_id       = "agentcore-gateway"
    viewer_protocol_policy = "https-only"

    # MCP is JSON-RPC over POST. Without ALLOW_ALL, CloudFront rejects the only
    # method that matters.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # Caching disabled, not merely short. Tool calls are not cacheable and the
    # Authorization header must reach the origin on every request.
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    compress = false
  }

  # --- Discovery: answered at the edge, never reaching the origin -----------
  ordered_cache_behavior {
    path_pattern           = "/.well-known/oauth-protected-resource*"
    target_origin_id       = "agentcore-gateway"
    viewer_protocol_policy = "https-only"

    # RFC 9728 requires this document to answer an ANONYMOUS caller, because it is
    # how a client discovers where to authenticate. GET and HEAD are all it needs.
    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.prm_edge.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Exactly one of these two paths is active. Before the certificate is issued
    # the distribution serves on its own cloudfront.net name, which is already a
    # working MCP endpoint.
    cloudfront_default_certificate = local.domain_attached ? null : true
    acm_certificate_arn            = local.domain_attached ? aws_acm_certificate.mcp.arn : null
    ssl_support_method             = local.domain_attached ? "sni-only" : null
    minimum_protocol_version       = local.domain_attached ? "TLSv1.2_2021" : null
  }

  # Attaching an unvalidated certificate fails, and the error names neither the
  # certificate nor the validation.
  depends_on = [aws_acm_certificate_validation.mcp]
}
