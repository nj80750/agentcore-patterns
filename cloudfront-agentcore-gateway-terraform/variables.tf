# =============================================================================
# REQUIRED
# =============================================================================

variable "custom_domain" {
  description = <<-EOT
    The hostname you want in front of your AgentCore Gateway, for example
    mcp.example.com. This is the point of the pattern, so it has no default.

    USE A SUBDOMAIN. A CNAME cannot exist at a zone apex, so a bare example.com
    only works if your DNS provider supports ALIAS or ANAME records — Route 53
    does, most registrars do not.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.custom_domain))
    error_message = "custom_domain must be a lowercase hostname such as mcp.example.com, with no scheme, path, port or wildcard."
  }

  validation {
    # Two labels means an apex. Deliberately permits example.co.uk, which has three
    # labels and IS an apex — this only catches the common case, with no false
    # positives.
    condition     = length(split(".", var.custom_domain)) >= 3
    error_message = "Use a subdomain such as mcp.example.com. A CNAME cannot exist at a zone apex."
  }
}


# =============================================================================
# DNS — set route53_zone_id for the automated path, leave it empty otherwise
# =============================================================================

variable "route53_zone_id" {
  description = <<-EOT
    Route 53 public hosted zone ID holding custom_domain, when that zone is in THIS
    AWS account. Terraform then creates the certificate validation record and the
    alias record itself: one apply, nothing to paste.

    Leave empty if your DNS is anywhere else — another provider, or another AWS
    account. The apply then prints the records for you to add by hand. See
    external_dns_validated.
  EOT
  type        = string
  default     = ""

  validation {
    # The console and `aws route53 list-hosted-zones` both return
    # /hostedzone/Z0123..., and pasting that verbatim is the most common mistake.
    condition     = var.route53_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be the bare ID such as Z0123456789ABC. Strip the /hostedzone/ prefix."
  }
}

variable "external_dns_validated" {
  description = <<-EOT
    External-DNS path only. Ignored when route53_zone_id is set.

    Leave false for the first apply. It creates everything and prints
    dns_validation_record. Add that record at your DNS provider, confirm it resolves
    with the dig command in the outputs, then set this to true and apply again — the
    certificate validates and the domain attaches to the distribution.

    Setting this true before the record resolves makes the second apply wait and
    then time out, which is recoverable but slow.
  EOT
  type        = bool
  default     = false
}


# =============================================================================
# AUTH — cognito creates a user pool, external points at your own IdP
# =============================================================================

variable "auth_mode" {
  description = <<-EOT
    "cognito" creates a user pool and an app client, so the pattern deploys with no
    identity prerequisites. Terraform does NOT create any user — you add one and
    sign in to obtain a token.

    "external" points the Gateway at an identity provider you already run. The four
    oidc_* variables below then apply.
  EOT
  type        = string
  default     = "cognito"

  validation {
    condition     = contains(["cognito", "external"], var.auth_mode)
    error_message = "auth_mode must be \"cognito\" or \"external\"."
  }
}

variable "oidc_discovery_url" {
  description = <<-EOT
    auth_mode = "external" only. Your IdP's FULL OpenID discovery document URL.

    Must end in /.well-known/openid-configuration. AgentCore enforces that suffix
    and rejects a bare issuer with a pattern-mismatch error that names nothing
    useful.
  EOT
  type        = string
  default     = ""

  validation {
    condition = var.oidc_discovery_url == "" || (
      startswith(var.oidc_discovery_url, "https://") &&
      endswith(var.oidc_discovery_url, "/.well-known/openid-configuration")
    )
    error_message = "oidc_discovery_url must be an https URL ending in /.well-known/openid-configuration."
  }
}

variable "oidc_allowed_audience" {
  description = <<-EOT
    Accepted "aud" claim values. Use this for Okta, Entra and Auth0, whose access
    tokens carry a real audience such as api://default.

    Set EITHER this or oidc_allowed_clients, not both.
  EOT
  type        = list(string)
  default     = []
}

variable "oidc_allowed_clients" {
  description = <<-EOT
    Accepted "client_id" claim values. Use this for Cognito, whose access tokens
    carry client_id and no aud at all — which is why matching on audience fails
    against a Cognito issuer with a 403 that looks like a scope problem.

    Set EITHER this or oidc_allowed_audience, not both.
  EOT
  type        = list(string)
  default     = []
}

variable "oidc_allowed_scopes" {
  description = <<-EOT
    Scopes the Gateway requires, and what it advertises in its protected-resource
    metadata. Optional.

    LEAVE EMPTY for a username-password sign-in. Those tokens carry the scope
    aws.cognito.signin.user.admin rather than any custom scope — custom scopes only
    appear through the hosted-UI OAuth flow — so requiring one here rejects every
    token from that flow.
  EOT
  type        = list(string)
  default     = []
}


# =============================================================================
# OPTIONAL
# =============================================================================

variable "project" {
  description = <<-EOT
    Prefix for resource names. Does not need to be globally unique — a random
    suffix is appended where AWS demands it, such as the Cognito hosted domain.
  EOT
  type        = string
  default     = "agentcore-mcp"

  validation {
    # Flows into IAM role names, which cap at 64 characters, and into the Cognito
    # domain prefix, which allows only lowercase, digits and hyphens.
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.project))
    error_message = "project must be 2-25 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = <<-EOT
    Region for the Gateway, the Lambda target and the REST API. Confirm AgentCore
    Gateway is available there before changing it.

    The ACM certificate and the Lambda@Edge function are always created in
    us-east-1 regardless, because CloudFront requires it.
  EOT
  type        = string
  default     = "us-east-1"
}

variable "agent_enabled" {
  description = <<-EOT
    The third tool target: an MCP server on AgentCore Runtime that invokes a Bedrock
    model. ON by default — it is part of this pattern, not an add-on.

    Because of it, deploying is two steps rather than one. The agent's package has to
    be cross-compiled for arm64 Linux with vendored dependencies, which archive_file
    cannot do, so `./agent/build.sh` has to run before terraform:

        ./agent/build.sh
        terraform apply

    That ordering is not a preference. The artifact's hash is read at PLAN time, so
    the zip must exist before Terraform starts — a provisioner would run during
    apply, too late.

    Set this to false only if you cannot get Bedrock model access or cannot install
    uv. You then get the Lambda and API Gateway targets, which need no build step.
  EOT
  type        = bool
  default     = true
}

variable "oauth_browser_login_enabled" {
  description = <<-EOT
    Adds a Cognito hosted UI and a second app client for the browser
    authorization-code flow, so hosted MCP clients such as claude.ai can sign a
    user in rather than being handed a static bearer token.

    Only meaningful when auth_mode = "cognito".

    Needed because Anthropic does not support a pure machine-to-machine
    client_credentials grant — every connection requires user consent — so a
    hosted client has no way to use the username-password flow the CLI examples
    use.

    Two app clients rather than one, deliberately. The documented `initiate-auth`
    sign-in needs ALLOW_USER_PASSWORD_AUTH; the browser flow needs `code` with a
    callback URL. Keeping them separate means enabling this does not break the
    curl path.
  EOT
  type        = bool
  default     = false
}

variable "oauth_callback_urls" {
  description = <<-EOT
    Redirect URIs permitted for the browser flow. Ignored unless
    oauth_browser_login_enabled = true.

    The claude.ai default is taken from community documentation rather than from
    Anthropic's own reference, so treat it as unverified. If the connection fails
    at the redirect step, Cognito's error page shows the exact redirect_uri the
    client sent — add that value here.
  EOT
  type        = list(string)
  default     = ["https://claude.ai/api/mcp/auth_callback"]
}

variable "agent_model_id" {
  description = <<-EOT
    Bedrock model the agent invokes. Only used when agent_enabled = true.

    Must be a cross-region INFERENCE PROFILE, not a bare model ID — a bare ID fails
    with ValidationException. The leading "us." is a GEOGRAPHY, so deploying outside
    the US needs a different identifier, for example "eu.anthropic..." in Europe.

    The model must be accessible in your account and region. Check with:
      aws bedrock list-inference-profiles --region <region>
  EOT
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "api_stage_name" {
  description = "REST API stage name. Also the only value the Gateway accepts for the generated basePath input — see the README's Known limitations."
  type        = string
  default     = "v1"
}

variable "cloudfront_price_class" {
  description = "PriceClass_100 is the cheapest and covers North America and Europe. Widen only if you have viewers elsewhere."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "origin_read_timeout" {
  description = <<-EOT
    Seconds CloudFront waits for the Gateway to respond. CloudFront's own default is
    30, which is tight for a real tool call — a tool invocation is a backend request,
    not a cache miss, and a slow tool should surface as a slow tool rather than a
    CloudFront 504.

    The default service quota allows 1 to 120.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 120
    error_message = "origin_read_timeout must be between 1 and 120 seconds without a quota increase."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Only the values CloudWatch accepts are valid."
  type        = number
  default     = 7

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of the values CloudWatch accepts: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

variable "tags" {
  description = "Tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}
