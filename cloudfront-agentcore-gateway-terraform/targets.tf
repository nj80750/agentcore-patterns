# =============================================================================
# Tool target 1 — AWS Lambda
# =============================================================================

data "aws_iam_policy_document" "hello_lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hello_lambda" {
  name               = "${var.project}-hello-lambda-role"
  description        = "Execution role for the hello-world Lambda tool."
  assume_role_policy = data.aws_iam_policy_document.hello_lambda_trust.json
}

resource "aws_cloudwatch_log_group" "hello_lambda" {
  name              = "/aws/lambda/${var.project}-hello"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role_policy" "hello_lambda_logs" {
  name = "logs"
  role = aws_iam_role.hello_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.hello_lambda.arn}:*"
    }]
  })
}

data "archive_file" "hello" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/hello"
  output_path = "${path.module}/.build/hello.zip"
}

resource "aws_lambda_function" "hello" {
  function_name = "${var.project}-hello"
  description   = "Hello-world tool, exposed through AgentCore Gateway."
  role          = aws_iam_role.hello_lambda.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  filename         = data.archive_file.hello.output_path
  source_code_hash = data.archive_file.hello.output_base64sha256

  # Generous for a string return, but a cold start should not read as a timeout
  # when you are measuring latency through the front door.
  timeout = 10

  depends_on = [
    aws_iam_role_policy.hello_lambda_logs,
    aws_cloudwatch_log_group.hello_lambda,
  ]
}


# =============================================================================
# Tool target 2 — Amazon API Gateway
# =============================================================================
#
# Constraints AgentCore Gateway places on an API Gateway target, all satisfied
# deliberately below:
#
#   REST API only     HTTP and WebSocket APIs are not supported
#   REGIONAL          private endpoint types are not supported
#   Same account      and same region as the Gateway
#   No {proxy+}       proxy resources are not supported, so the path is /hello
#   operationId       the Gateway reads the OpenAPI export and uses operationId as
#                     the MCP tool name. API Gateway emits it from the method's
#                     operation_name. Omit it and target creation fails validation.

resource "aws_api_gateway_rest_api" "hello" {
  name        = "${var.project}-hello-api"
  description = "Hello-world REST API, exposed through AgentCore Gateway."

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "hello" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  parent_id   = aws_api_gateway_rest_api.hello.root_resource_id
  path_part   = "hello"
}

resource "aws_api_gateway_method" "hello_get" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = "GET"

  # The Gateway signs its calls with its own IAM role, so the API is never
  # publicly callable even though the endpoint is a public one.
  authorization = "AWS_IAM"

  # Becomes operationId in the OpenAPI export, and therefore the MCP tool name:
  # helloApi___getHello
  operation_name = "getHello"
}

resource "aws_api_gateway_method" "hello_put" {
  rest_api_id    = aws_api_gateway_rest_api.hello.id
  resource_id    = aws_api_gateway_resource.hello.id
  http_method    = "PUT"
  authorization  = "AWS_IAM"
  operation_name = "putHello"
}

# MOCK integrations — no backend to run or pay for. The {"statusCode": 200}
# request template is what tells the MOCK backend which integration response to
# select; without it the method returns a 500.
resource "aws_api_gateway_integration" "hello_get" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_integration" "hello_put" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_put.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "hello_get_200" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_get.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_method_response" "hello_put_200" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_put.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "hello_get_200" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_get.http_method
  status_code = aws_api_gateway_method_response.hello_get_200.status_code

  response_templates = {
    "application/json" = jsonencode({
      message = "Hello from Amazon API Gateway (GET) in ${var.region}"
    })
  }

  depends_on = [aws_api_gateway_integration.hello_get]
}

resource "aws_api_gateway_integration_response" "hello_put_200" {
  rest_api_id = aws_api_gateway_rest_api.hello.id
  resource_id = aws_api_gateway_resource.hello.id
  http_method = aws_api_gateway_method.hello_put.http_method
  status_code = aws_api_gateway_method_response.hello_put_200.status_code

  response_templates = {
    "application/json" = jsonencode({
      message = "Hello from Amazon API Gateway (PUT) in ${var.region}"
    })
  }

  depends_on = [aws_api_gateway_integration.hello_put]
}

resource "aws_api_gateway_deployment" "hello" {
  rest_api_id = aws_api_gateway_rest_api.hello.id

  # API Gateway deployments are immutable snapshots. Without a trigger, editing a
  # method changes the API but leaves the deployed stage serving the old
  # definition — and Terraform reports no changes.
  #
  # These are individual CONFIGURED attributes, deliberately not the whole
  # resource objects. Hashing the objects is the common shorthand and it makes
  # every plan dirty: API Gateway returns `cache_key_parameters = []` and
  # `request_parameters = {}` for an integration that was created without them,
  # where Terraform recorded null. The hash then differs on the next refresh, so
  # the deployment is replaced and the stage updated on every single apply, with
  # nothing having actually changed.
  #
  # Listing attributes explicitly means this covers exactly the values that define
  # the API surface. Add to this list if you add to the API.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.hello.path_part,

      aws_api_gateway_method.hello_get.http_method,
      aws_api_gateway_method.hello_get.authorization,
      aws_api_gateway_method.hello_get.operation_name,
      aws_api_gateway_method.hello_put.http_method,
      aws_api_gateway_method.hello_put.authorization,
      aws_api_gateway_method.hello_put.operation_name,

      aws_api_gateway_integration.hello_get.type,
      aws_api_gateway_integration.hello_get.request_templates,
      aws_api_gateway_integration.hello_put.type,
      aws_api_gateway_integration.hello_put.request_templates,

      aws_api_gateway_method_response.hello_get_200.status_code,
      aws_api_gateway_method_response.hello_get_200.response_models,
      aws_api_gateway_method_response.hello_put_200.status_code,
      aws_api_gateway_method_response.hello_put_200.response_models,

      aws_api_gateway_integration_response.hello_get_200.status_code,
      aws_api_gateway_integration_response.hello_get_200.response_templates,
      aws_api_gateway_integration_response.hello_put_200.status_code,
      aws_api_gateway_integration_response.hello_put_200.response_templates,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "hello" {
  rest_api_id   = aws_api_gateway_rest_api.hello.id
  deployment_id = aws_api_gateway_deployment.hello.id
  stage_name    = var.api_stage_name
}
