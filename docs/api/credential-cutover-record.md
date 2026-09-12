# API credential registry cutover record

This record prevents implementation, deployment, provisioning, and live
verification from being conflated for Cinegraph issue #1128. Never paste a raw
credential here.

## Current status

| Gate | Status | Evidence required before changing status |
|---|---|---|
| Cinegraph registry implementation | complete locally | migrations, registry auth, lifecycle commands, legacy boundary, docs |
| Cinegraph focused tests | complete locally | `mix test` command and result below |
| Cinegraph admin key UI | implemented/tested; walkthrough pending | `/admin/api-credentials`; create clients, issue/copy once, overlap rotation, revoke and disable |
| Eventasaurus canary companion fix | implemented/tested; deployment pending | [companion branch](https://github.com/razrfly/eventasaurus/tree/codex/cinegraph-1128-auth-cutover); 23 tests pass, including fan-out prevention, cached state/timestamp preservation and auth-error metrics |
| Dictionary readiness check | implemented/tested; deployment pending | [issue-88 branch](https://github.com/razrfly/dictionary/tree/codex/issue-88), commit `90e81f2`; `mix dd.discovery.check` and 878 passing precommit tests |
| Cinegraph migration/deploy | not performed | deployed release and migration timestamp |
| Every Cinegraph instance registry-capable | not verified | instance/fleet evidence |
| Consumer credentials issued | not performed | non-secret client and key IDs per environment |
| Consumer secret stores/process reload | not performed | environment and reload timestamp |
| Wordhoard live demonstration | not performed | fresh-server `war`/`nepotism`/`grief`, cache reuse, and genuine empty result evidence |
| Eventasaurus live verification | not performed | fresh known-movie request, single-job persisted result, sweep path, and attribution |
| Legacy observation/removal | not started | observation window, exercised weekly path, zero remaining legacy traffic, removal time |

## Local validation

On 2026-09-12:

```text
mix test test/cinegraph/api_credentials_test.exs \
  test/cinegraph/api_credentials \
  test/cinegraph/configuration_test.exs \
  test/cinegraph/auth/clerk \
  test/cinegraph_web/controllers/graphql_api_test.exs \
  test/cinegraph_web/middleware \
  test/cinegraph_web/schema \
  test/cinegraph_web/plugs/clerk_auth_plug_test.exs \
  test/cinegraph_web/live/admin/api_credentials_live_test.exs \
  test/cinegraph_web/live/admin_dashboard_live_test.exs

106 tests, 0 failures
```

`mix assets.build` passes. The admin UI was checked in a disposable local
test-database preview at desktop and mobile widths. No production credentials
were issued. The UI lifecycle, one-time display, validation and admin access
boundary are covered by LiveView tests.

Built an actual test-environment release with `MIX_ENV=test mix release` and
exercised the structured release helpers for client creation/list/disable and key
issue/list/overlapping rotation/revoke. The production-facing
`mix cinegraph.prod.api_credentials` command uses `Cinegraph.ProdRpc` to run those
helpers through Kamal and accepts an explicit UTC expiry or `--no-expiry`.
Generated test credentials stayed captured in memory and the local database
transaction rolled back. This is release-command verification, not a production
deployment or production provisioning claim.

Eventasaurus: the client and sync-worker suites pass (23 tests), including
HTTP-200 unauthorized responses, partial data rejection, sweep fan-out prevention,
auth-error ledger classification, and unchanged cache/sync timestamps on failure.
Existing optional ML dependency warnings remain outside this change.

Dictionary: `mix precommit` passes (878 tests). The isolated worktree uses the
existing local dependency and corpus files; no corpus downloads or production
requests were needed. The preflight explicitly reports configuration readiness
separately from credential validity and live discovery.

The previous implementation's broader `mix test test/cinegraph_web` run reported
nine existing unrelated failures. This follow-up reran the focused suites above;
it does not claim the entire Cinegraph web suite is green.

## Before the first production deployment

Set `CINEGRAPH_LEGACY_API_KEY_EXPIRES_AT` to the agreed future UTC deadline before
deploying while `CINEGRAPH_API_KEY` is configured. Deploy the consumer companion
fixes first. Retain `catalog_api` info-level JSON logs across the observation
window; inspect `outcome`, `client_slug`, and protected-field `request_cost` counts.
Never record raw tokens here. Production gates below are still outstanding.
When the observation gate is complete, remove `CINEGRAPH_API_KEY` and
`CINEGRAPH_LEGACY_API_KEY_EXPIRES_AT` atomically from both `config/deploy.yml` and
the deployment secret store; removing only the secret-store values leaves Kamal
with unresolved manifest entries.

## Deployment record

Fill this section during the ordered deployment. Identifiers are safe to record;
tokens and digests are not.

```text
Registry-capable release:
Oldest safe rollback release:
Migration applied at (UTC):
All serving instances verified at (UTC):
Legacy fixed expiry (UTC):
Legacy observation window:

wordhoard-preview       client_id=  key_id=  configured_at=  verified_at=
wordhoard-production    client_id=  key_id=  configured_at=  verified_at=
eventasaurus-production client_id=  key_id=  configured_at=  verified_at=

Remaining legacy callers:
Legacy configuration removed at (UTC):
Operator:
```

Do not mark #1128 complete from this local record alone. Complete every external
gate, then attach non-secret telemetry/request evidence to the issue.
