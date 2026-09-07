data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# The partition, so IAM policies are correct outside the commercial regions.
# A literal arn:aws: silently matches nothing in GovCloud (arn:aws-us-gov:) or
# China (arn:aws-cn:), and the resulting failure is a permission denial that
# mentions no partition.
data "aws_partition" "current" {}

locals {
  # --- DNS mode -------------------------------------------------------------
  # A zone ID means Terraform owns the records: one apply, nothing to paste.
  route53_managed = var.route53_zone_id != ""

  # Whether the custom domain can be attached to the distribution yet.
  #
  # CloudFront refuses an alternate domain name until its certificate is ISSUED.
  # On the Route 53 path that happens inside the same apply, because Terraform
  # writes the validation record itself. On the external path it cannot happen
  # until a human has placed that record, which is what external_dns_validated
  # signals. Until then the distribution runs on its own cloudfront.net name and
  # is already fully functional.
  domain_attached = local.route53_managed || var.external_dns_validated

  # --- Auth mode ------------------------------------------------------------
  cognito_enabled = var.auth_mode == "cognito"

  # Browser sign-in only makes sense for a pool this pattern controls.
  browser_login_enabled = local.cognito_enabled && var.oauth_browser_login_enabled

  # Cognito publishes discovery at the user pool's issuer. No hosted UI domain is
  # needed for this, which is why the pattern does not create one — that would
  # add a globally-unique name to worry about for no benefit.
  discovery_url = local.cognito_enabled ? format(
    "https://cognito-idp.%s.amazonaws.com/%s/.well-known/openid-configuration",
    var.region,
    aws_cognito_user_pool.this[0].id,
  ) : var.oidc_discovery_url

  # Cognito access tokens carry client_id and no aud, so authorization is by
  # client. An external IdP may use either, so both pass through.
  #
  # BOTH clients are listed when browser login is on. The Gateway matches the
  # client_id claim, and a token minted through the browser flow carries the
  # browser client's ID — omit it and every claude.ai call gets a 403 that looks
  # exactly like a scope problem.
  allowed_clients = local.cognito_enabled ? concat(
    [aws_cognito_user_pool_client.this[0].id],
    local.browser_login_enabled ? [aws_cognito_user_pool_client.browser[0].id] : [],
  ) : var.oidc_allowed_clients
  allowed_audience = local.cognito_enabled ? [] : var.oidc_allowed_audience

  # Empty for Cognito on purpose. A username-password sign-in returns the scope
  # aws.cognito.signin.user.admin, never a custom one — those only appear through
  # the hosted-UI OAuth flow — so requiring a scope here would reject every token
  # the documented sign-in produces.
  allowed_scopes = local.cognito_enabled ? [] : var.oidc_allowed_scopes

  # Scopes ADVERTISED in the protected-resource document, which is a different
  # thing from the scopes the Gateway requires.
  #
  # Stating them explicitly is what stops a client guessing. With this field absent
  # a client falls back to the authorization server's full advertised list, and if
  # any entry there is not permitted on the app client, Cognito rejects the whole
  # authorize request with an unexplained invalid_request.
  #
  # When browser login is off there is nothing useful to advertise, so the field is
  # omitted rather than sent empty — an empty array reads as "no scopes supported"
  # rather than "scopes are not used here".
  prm_scopes = local.browser_login_enabled ? ["openid", "profile"] : local.allowed_scopes

  # The BARE issuer, with no /.well-known suffix. This is what the
  # protected-resource document advertises, and appending the well-known path is
  # the client's job. Confusing the two produces a document clients cannot follow.
  issuer = local.cognito_enabled ? format(
    "https://cognito-idp.%s.amazonaws.com/%s",
    var.region,
    aws_cognito_user_pool.this[0].id,
  ) : trimsuffix(var.oidc_discovery_url, "/.well-known/openid-configuration")

  # --- The origin -----------------------------------------------------------
  # The Gateway's hostname, with scheme and path stripped. CloudFront wants a bare
  # domain name for a custom origin.
  gateway_host = replace(
    replace(aws_bedrockagentcore_gateway.mcp.gateway_url, "https://", ""),
    "/mcp",
    "",
  )
}
