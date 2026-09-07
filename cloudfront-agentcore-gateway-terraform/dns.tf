# =============================================================================
# Certificate and DNS
# =============================================================================
#
# The certificate is ALWAYS created in us-east-1, whatever var.region is, because
# CloudFront accepts nothing else for an alternate domain name.

resource "aws_acm_certificate" "mcp" {
  provider = aws.us_east_1

  domain_name       = var.custom_domain
  validation_method = "DNS"

  # The replacement is issued and validated before the old one is detached from the
  # distribution. Without this, a renewal or rename takes the front door down for
  # the several minutes a CloudFront update takes.
  lifecycle {
    create_before_destroy = true
  }
}

# Looked up only to cross-check custom_domain against it. Route 53 refuses a record
# whose name falls outside the zone, but it does so AFTER the certificate has been
# created — leaving an orphan stuck in PENDING_VALIDATION and an error that talks
# about RRSets rather than about the two variables disagreeing:
#
#   InvalidChangeBatch: [RRSet with DNS name mcp.abc.com. is not permitted
#   in zone example.com.]
data "aws_route53_zone" "this" {
  count   = local.route53_managed ? 1 : 0
  zone_id = var.route53_zone_id
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.route53_managed ? {
    for option in aws_acm_certificate.mcp.domain_validation_options :
    option.domain_name => option
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  # ACM validation records are idempotent by content, and a leftover from a
  # previous certificate would silently block issuance of the new one.
  allow_overwrite = true

  lifecycle {
    precondition {
      condition = endswith(
        var.custom_domain,
        trimsuffix(data.aws_route53_zone.this[0].name, ".")
      )
      error_message = "custom_domain must sit inside the hosted zone named by route53_zone_id. Route 53 rejects out-of-zone record names, but only after the certificate has been created."
    }
  }
}

# Not a resource so much as a barrier: it blocks until ACM reports ISSUED.
#
# On the Route 53 path it is handed the FQDNs it just created and completes within
# a minute or two. On the external path validation_record_fqdns is null, so it
# simply waits for the certificate to become ISSUED by whatever means — which is
# why it must not exist until the reader has actually placed the record.
resource "aws_acm_certificate_validation" "mcp" {
  count    = local.domain_attached ? 1 : 0
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.mcp.arn

  validation_record_fqdns = local.route53_managed ? [
    for record in aws_route53_record.cert_validation : record.fqdn
  ] : null

  timeouts {
    create = "15m"
  }
}

# The alias record. A-type alias rather than CNAME so it would also work at a zone
# apex, and because an alias costs nothing to resolve.
resource "aws_route53_record" "mcp" {
  count = local.route53_managed ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.custom_domain
  type    = "A"

  alias {
    name    = aws_cloudfront_distribution.mcp.domain_name
    zone_id = aws_cloudfront_distribution.mcp.hosted_zone_id

    # CloudFront distributions have no health check to evaluate, and asking for one
    # fails the apply.
    evaluate_target_health = false
  }
}
