# Clerk Authentication Configuration
#
# This file configures Clerk as an authentication provider for Cinegraph.
# Credentials are loaded from environment variables in runtime.exs.
#
# NOTE: Wombi/Eventasaurus is the *reference implementation* this was ported
# from — it is NOT a shared Clerk tenant. Cinegraph uses its own dedicated
# Clerk application.
#
# Required environment variables:
#   CLERK_PUBLISHABLE_KEY - Frontend publishable key (pk_test_... or pk_live_...)
#   CLERK_SECRET_KEY      - Backend secret key (sk_test_... or sk_live_...)

import Config

# Clerk configuration (credentials + derived domain/jwks_url loaded at runtime).
config :cinegraph, :clerk,
  # Enabled when both keys are present (resolved in runtime.exs).
  enabled: false,
  # Clerk domain extracted from the publishable key at runtime.
  domain: nil,
  # JWKS endpoint for JWT verification (set at runtime based on domain).
  jwks_url: nil,
  # Expected JWT issuer (https://<domain>); set at runtime. When nil, issuer
  # validation is skipped (dev/test convenience).
  issuer: nil,
  # Authorized parties for token verification (your app URLs).
  authorized_parties: ["http://localhost:4000"],
  # Cache JWKS keys for this duration (in milliseconds).
  jwks_cache_ttl: 3_600_000
