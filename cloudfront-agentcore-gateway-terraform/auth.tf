# =============================================================================
# Cognito — created only when auth_mode = "cognito"
# =============================================================================
#
# Deliberately minimal: a user pool and one app client. No hosted UI domain, no
# resource server, no users.
#
# No hosted domain because the documented sign-in is InitiateAuth, which talks to
# the regional cognito-idp endpoint. A hosted domain is only needed for browser
# redirect flows, and its prefix must be unique across every AWS account — a
# constraint worth avoiding when nothing here uses it.
#
# No resource server because that only exists to define custom scopes, and custom
# scopes never appear in a username-password token. See local.allowed_scopes.
#
# NO USERS. Creating one would put a password in Terraform state, and a published
# pattern's state file sits on the reader's disk. The README shows the two commands
# to add a user instead.

resource "aws_cognito_user_pool" "this" {
  count = local.cognito_enabled ? 1 : 0

  name = "${var.project}-pool"

  # Defaults are 8 characters with upper, lower, digit and symbol. Left alone so
  # the password in the README's example actually satisfies the policy.
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  # Nothing self-registers. Users are added by an administrator, which is what the
  # README's admin-create-user command does.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

resource "aws_cognito_user_pool_client" "this" {
  count = local.cognito_enabled ? 1 : 0

  name         = "${var.project}-client"
  user_pool_id = aws_cognito_user_pool.this[0].id

  # No secret, and that is a usability decision. With a secret, every InitiateAuth
  # call must carry a SECRET_HASH — an HMAC of username plus client ID keyed on the
  # secret — which cannot be produced with the AWS CLI alone. A public client keeps
  # the documented sign-in to a single command.
  generate_secret = false

  # ALLOW_USER_PASSWORD_AUTH is what makes the README's InitiateAuth call legal.
  # Without it the API returns InvalidParameterException naming the auth flow, which
  # reads like a malformed request rather than a missing setting.
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # An hour is the Cognito default. Long enough to test with, short enough that a
  # token pasted into a client config is not a durable credential.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}


# =============================================================================
# Browser sign-in — only when oauth_browser_login_enabled = true
# =============================================================================
#
# Hosted MCP clients such as claude.ai cannot use the username-password flow
# above: Anthropic does not support a machine-to-machine client_credentials grant,
# because every connection requires user consent. They need a real
# authorization-code flow with a browser redirect.
#
# Cognito serves those endpoints only once a hosted UI domain exists. Without one
# the pool's discovery document advertises /authorize and /token paths that look
# plausible and do not work — which is a confusing failure to debug.

resource "aws_cognito_user_pool_domain" "this" {
  count = local.browser_login_enabled ? 1 : 0

  # The prefix must be unique across EVERY AWS account, not just yours, so a
  # random suffix is appended. This is the only resource here with that
  # constraint, and it is why var.project does not need to be globally unique.
  domain       = "${var.project}-${random_string.domain_suffix[0].result}"
  user_pool_id = aws_cognito_user_pool.this[0].id
}

resource "random_string" "domain_suffix" {
  count = local.browser_login_enabled ? 1 : 0

  length  = 8
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_client" "browser" {
  count = local.browser_login_enabled ? 1 : 0

  name         = "${var.project}-browser-client"
  user_pool_id = aws_cognito_user_pool.this[0].id

  # A SECOND client rather than reconfiguring the first. The two flows have
  # different requirements and the existing client is what the documented curl
  # sign-in uses — enabling browser login must not break it.
  generate_secret = false

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  # ALL FOUR standard scopes, and this matters more than it looks.
  #
  # Cognito rejects an authorize request naming any scope the client does not
  # allow, and the rejection is a bare error=invalid_request with no indication of
  # which scope was at fault. Measured:
  #
  #   scope=openid          accepted
  #   scope=openid profile  accepted
  #   scope=openid email    REJECTED  error=invalid_request
  #
  # A client that has not been told what to ask for falls back to the scopes the
  # authorization server advertises, and Cognito's discovery document lists
  # openid, email, phone and profile. Allowing only a subset therefore breaks any
  # client that trusts that list — which is what happened with claude.ai.
  #
  # These are identity scopes only. They grant no access to anything: the Gateway
  # authorizes on the client_id claim, not on scope.
  allowed_oauth_scopes = ["openid", "email", "phone", "profile"]

  callback_urls = var.oauth_callback_urls

  # No implicit grant. The authorization-code flow with PKCE is the only
  # appropriate choice for a public client, and Cognito supports S256.
  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}
