output "mcp_url" {
  description = "The MCP endpoint on your custom domain. Null until the certificate is issued and the domain is attached."
  value       = local.domain_attached ? "https://${var.custom_domain}/mcp" : null
}

output "cloudfront_url" {
  description = "The MCP endpoint on the CloudFront-assigned name. Works from the first apply, before any DNS exists, so you can test the pattern immediately."
  value       = "https://${aws_cloudfront_distribution.mcp.domain_name}/mcp"
}

output "custom_domain_status" {
  description = "Whether your domain is live yet, and what to do next if not."
  value = local.domain_attached ? "ATTACHED — ${var.custom_domain} is serving." : join(" ", [
    "PENDING — add dns_validation_record at your DNS provider,",
    "confirm it resolves with dns_validation_check,",
    "then set external_dns_validated = true and apply again.",
  ])
}


# =============================================================================
# External DNS path — the two records you place by hand
# =============================================================================

output "dns_validation_record" {
  description = "Certificate validation record. Add this at your DNS provider, then set external_dns_validated = true. Null on the Route 53 path, where Terraform creates it for you."
  value = local.route53_managed ? null : {
    for option in aws_acm_certificate.mcp.domain_validation_options :
    option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}

output "dns_validation_check" {
  description = "Run this before setting external_dns_validated = true. If it prints nothing, the record has not propagated and the next apply will wait and then time out."
  value = local.route53_managed ? null : join("\n", [
    for option in aws_acm_certificate.mcp.domain_validation_options :
    "dig +short ${trimsuffix(option.resource_record_name, ".")} CNAME"
  ])
}

output "dns_target_record" {
  description = "The record that points your domain at the distribution. Add this after the certificate is issued. Null on the Route 53 path."
  value = local.route53_managed ? null : {
    name  = var.custom_domain
    type  = "CNAME"
    value = aws_cloudfront_distribution.mcp.domain_name
  }
}


# =============================================================================
# Signing in
# =============================================================================

output "cognito_user_pool_id" {
  description = "User pool ID. Needed by the admin-create-user commands in the README. Null when auth_mode = \"external\"."
  value       = local.cognito_enabled ? aws_cognito_user_pool.this[0].id : null
}

output "cognito_client_id" {
  description = "App client ID. Needed by the initiate-auth command in the README. Null when auth_mode = \"external\"."
  value       = local.cognito_enabled ? aws_cognito_user_pool_client.this[0].id : null
}

output "create_user_commands" {
  description = <<-EOT
    Commands to create a user and obtain a token. The pattern deliberately creates
    no users, so no password ever lands in Terraform state.

    Choose your own password rather than pasting a literal from documentation — a
    published example password means every deployment of this pattern shares one.
  EOT
  value = local.cognito_enabled ? join("\n", [
    "# Set a password of your own. Cognito requires 8+ characters with upper,",
    "# lower, digit and symbol.",
    "PW='<choose-a-strong-password>'",
    "",
    "aws cognito-idp admin-create-user \\",
    "  --user-pool-id ${aws_cognito_user_pool.this[0].id} \\",
    "  --username testuser --message-action SUPPRESS",
    "",
    "aws cognito-idp admin-set-user-password \\",
    "  --user-pool-id ${aws_cognito_user_pool.this[0].id} \\",
    "  --username testuser --password \"$PW\" --permanent",
    "",
    "aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \\",
    "  --client-id ${aws_cognito_user_pool_client.this[0].id} \\",
    "  --auth-parameters USERNAME=testuser,PASSWORD=\"$PW\" \\",
    "  --query 'AuthenticationResult.AccessToken' --output text",
  ]) : "auth_mode = \"external\": obtain a token from your own identity provider."
}


# =============================================================================
# Detail, for debugging
# =============================================================================

output "gateway_id" {
  description = "AgentCore Gateway ID."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_id
}

output "gateway_url" {
  description = "The Gateway's own regional MCP URL. Shown for debugging only — clients should use mcp_url, and nothing about this hostname should reach a client config."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_url
}

output "oidc_discovery_url" {
  description = "The discovery document the Gateway validates tokens against."
  value       = local.discovery_url
}

output "tools" {
  description = "Tool names published by this Gateway. The prefix before the three underscores is the target name."
  value = concat(
    [
      "helloLambda___say_hello",
      "helloApi___getHello",
      "helloApi___putHello",
    ],
    var.agent_enabled ? ["helloAgent___say_hello"] : [],
  )
}

output "browser_login" {
  description = "What to enter in a hosted MCP client such as claude.ai when oauth_browser_login_enabled = true. Null otherwise."
  value = local.browser_login_enabled ? {
    mcp_url       = local.domain_attached ? "https://${var.custom_domain}/mcp" : "https://${aws_cloudfront_distribution.mcp.domain_name}/mcp"
    client_id     = aws_cognito_user_pool_client.browser[0].id
    client_secret = "leave blank — this is a public client using PKCE"
    hosted_ui     = "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com"
    authorize_url = "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com/oauth2/authorize"
    token_url     = "https://${aws_cognito_user_pool_domain.this[0].domain}.auth.${var.region}.amazoncognito.com/oauth2/token"
    callback_urls = var.oauth_callback_urls
  } : null
}

output "agent_model_id" {
  description = "The Bedrock model the agent invokes. Null when the agent target is disabled."
  value       = var.agent_enabled ? var.agent_model_id : null
}

output "smoke_test" {
  description = "How to verify the deployment."
  value = join(" ", [
    "export MCP_URL=${local.domain_attached ? "https://${var.custom_domain}/mcp" : "https://${aws_cloudfront_distribution.mcp.domain_name}/mcp"};",
    "export TOKEN=<your access token>;",
    "./test/smoke.sh",
  ])
}
