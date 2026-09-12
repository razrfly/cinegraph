# Movie discovery GraphQL API

This is the provider contract for Dictionary/Wordhoard and other server-side
consumers that discover films through stored TMDb keywords and genres. Cinegraph
reports the metadata intersection that produced a result; it does not make or
store an editorial claim about what a film means.

## Endpoint and authentication

The deployed public endpoint is:

```text
https://cinegraph.org/api/graphql
```

Recommended consumer-side configuration names are:

```text
CINEGRAPH_GRAPHQL_URL=https://cinegraph.org/api/graphql
CINEGRAPH_API_KEY=<one-time provisioned key for this consumer environment>
```

Send the key only from the consumer server:

```text
Authorization: Bearer <CINEGRAPH_API_KEY>
```

Do not expose a service credential in a browser bundle or native app. No browser
CORS change is required for this server-to-server integration. Each deployed
consumer environment has a distinct client and may have multiple overlapping
keys during rotation. Application identity never creates a Cinegraph user or
grants user-only access. A Clerk user token alone does not grant catalog access.

Missing, malformed, expired, revoked, disabled, or incorrect credentials produce
a GraphQL `unauthorized` error (normally in an HTTP 200 response), so consumers
must inspect `errors` and not use HTTP status alone as the success signal. A
registry credential begins `cg_`; any failed credential in that format is denied
without retrying the legacy, Clerk, or anonymous paths.

No-key access is denied by default everywhere. Local development can opt in with
`CINEGRAPH_API_AUTH_LOCAL_BYPASS=true`; production refuses to boot with that
setting. A production registry with zero valid keys boots successfully so the
first key can be issued through the release command, but all catalog requests are
denied until one is issued.

Deployment and consumer secret provisioning are separate operational steps.
Source availability does not prove that this contract is live.

## Credential operator workflow

The only allowed scope is currently `catalog:read`. Client environment is an
operational label for the consumer deployment, not a claim about which Cinegraph
database it can access. Choose `--no-expiry` deliberately or provide a UTC
expiration; there is no implicit expiry default.

Local/Mix commands:

```sh
mix cinegraph.api_credentials client-create \
  --slug wordhoard-preview \
  --label "Wordhoard preview" \
  --owner-contact dictionary-ops@example.com \
  --environment preview

mix cinegraph.api_credentials client-list

mix cinegraph.api_credentials key-issue \
  --client wordhoard-preview \
  --label initial \
  --created-by operator@example.com \
  --no-expiry

mix cinegraph.api_credentials key-list --client wordhoard-preview
mix cinegraph.api_credentials client-disable --slug wordhoard-preview
mix cinegraph.api_credentials key-revoke --public-id PUBLIC_ID
```

Rotation deliberately creates the replacement without revoking the old key:

```sh
mix cinegraph.api_credentials key-rotate \
  --client wordhoard-preview \
  --old-public-id OLD_PUBLIC_ID \
  --label 2026-rotation \
  --created-by operator@example.com \
  --expires-at 2027-09-12T00:00:00Z
```

Capture the plaintext only from the issuance command and place it directly in
the target deployment's normal secret store. It is not recoverable. Client/key
list output contains metadata only, and revocation preserves the row.

Production releases do not require Mix. Exact invocation examples are:

```sh
bin/cinegraph eval 'Cinegraph.Release.api_client_create(%{slug: "wordhoard-preview", label: "Wordhoard preview", owner_contact: "dictionary-ops@example.com", environment: "preview"})'
bin/cinegraph eval 'Cinegraph.Release.api_client_list()'
bin/cinegraph eval 'Cinegraph.Release.api_key_issue("wordhoard-preview", %{label: "initial", created_by: "operator@example.com", expires_at: nil})'
bin/cinegraph eval 'Cinegraph.Release.api_key_list("wordhoard-preview")'
bin/cinegraph eval 'Cinegraph.Release.api_key_rotate("wordhoard-preview", "OLD_PUBLIC_ID", %{label: "rotation", created_by: "operator@example.com", expires_at: ~U[2027-09-12 00:00:00Z]})'
bin/cinegraph eval 'Cinegraph.Release.api_key_revoke("PUBLIC_ID")'
bin/cinegraph eval 'Cinegraph.Release.api_client_disable("wordhoard-preview")'
```

`api_key_issue/2` requires the `expires_at` key even when its intentional value
is `nil`. Release issuance starts the application directly and does not require
an existing catalog credential.

### Initial consumer inventory

No secret values belong in this inventory or in tickets/logs.

| Client slug | Consumer deployment | Operational owner | Key ID / verification |
|---|---|---|---|
| `wordhoard-preview` | Dictionary/Wordhoard preview | Dictionary deployment owner | record during provisioning |
| `wordhoard-production` | Dictionary/Wordhoard production | Dictionary deployment owner | record during provisioning |
| `eventasaurus-production` | Eventasaurus web/jobs production | Eventasaurus deployment owner | record during provisioning |

Add a separate Eventasaurus client for every additional actually deployed
environment; do not infer one. The database `owner_contact` must be a concrete,
current contact when each client is created.

### Legacy cutover

During migration only, the previous shared value remains in Cinegraph's
`CINEGRAPH_API_KEY`. It is accepted only when
`CINEGRAPH_LEGACY_API_KEY_EXPIRES_AT` is an unexpired ISO 8601 UTC timestamp.
Missing or blank configuration denies this path. Legacy traffic is attributed as
`legacy-shared-key`; registry-looking credentials are never considered legacy.

1. Before deploying, set `CINEGRAPH_LEGACY_API_KEY_EXPIRES_AT` in the deployment's
   normal secret/configuration store to the agreed future UTC cutover deadline.
   Keep the existing `CINEGRAPH_API_KEY` during the transition. Production refuses
   to boot with a configured shared key and no deadline. Confirm the old key does
   not use the reserved `cg_` prefix through the controlled operator workflow.
   Apply the additive migration and deploy this registry-capable release to every
   serving instance before issuing a registry key.
2. Record this release as the oldest safe rollback release. A shared-key-only
   release is not a safe rollback after cutover because it cannot enforce registry
   revocation.
3. Issue a distinct key for every inventoried environment, update that
   environment's normal secret store, and restart every web/job process.
4. Verify fresh upstream traffic and the observed client/key attribution. Cached
   UI data is not verification.
5. Observe legacy attribution across normal scheduled use. Explicitly exercise
   Eventasaurus's weekly sweep path if the observation window does not include it.
6. Revoke superseded keys. After zero legacy traffic across the recorded window,
   remove both legacy environment variables before their fixed deadline. Never
   extend the deadline silently or restore a revoked key for rollback.

An auth lookup beginning after a committed disable/revocation reads the primary
database and denies on every instance; an already authenticated request may
finish. There is intentionally no auth cache.

## Contract

All public keyword and genre identifiers are TMDb IDs, never Cinegraph database
IDs. Eligible movies have exactly `import_status = "full"`; discovery applies no
popularity, rating, or poster requirement.

### `searchMovieKeywords(query: String!, limit: Int = 10)`

Returns `{ tmdbId, name, movieCount }`. The query is trimmed, has a maximum length
of 100 characters, and uses case-insensitive literal substring matching. `%` and
`_` are ordinary characters. Results are ranked by exact name, then prefix, then
substring, followed by case-insensitive name and TMDb ID for deterministic ties.
`limit` is 1–50. No match returns `[]`.

```graphql
query SearchMovieKeywords($query: String!, $limit: Int = 10) {
  searchMovieKeywords(query: $query, limit: $limit) {
    tmdbId
    name
    movieCount
  }
}
```

Variables:

```json
{"query":"war","limit":10}
```

The consumer should present these candidates and deliberately persist the TMDb
keyword IDs it selects. It must not hardcode an unverified ID based on a label.

### `movieGenres`

Returns the complete small genre vocabulary as `{ tmdbId, name, movieCount }`,
ordered case-insensitively by name and then by TMDb ID. Counts use the same full
import eligibility rule.

```graphql
query MovieGenres {
  movieGenres {
    tmdbId
    name
    movieCount
  }
}
```

### `discoverMovies`

```graphql
query DiscoverMovies(
  $keywordTmdbIds: [Int!]
  $genreTmdbIds: [Int!]
  $keywordMatch: MovieDiscoveryMatch = ALL
  $genreMatch: MovieDiscoveryMatch = ALL
  $first: Int = 12
  $after: String
) {
  discoverMovies(
    keywordTmdbIds: $keywordTmdbIds
    genreTmdbIds: $genreTmdbIds
    keywordMatch: $keywordMatch
    genreMatch: $genreMatch
    first: $first
    after: $after
  ) {
    edges {
      cursor
      node {
        movie {
          tmdbId
          imdbId
          title
          releaseDate
          overview
          posterPath
          cinegraphUrl
          keywords { tmdbId name }
          genres { tmdbId name }
        }
        matchedKeywords { tmdbId name }
        matchedGenres { tmdbId name }
      }
    }
    pageInfo { endCursor hasNextPage }
  }
}
```

Variables for a keyword page:

```json
{
  "keywordTmdbIds": [273967],
  "genreTmdbIds": [],
  "keywordMatch": "ALL",
  "genreMatch": "ALL",
  "first": 12,
  "after": null
}
```

The example ID above is dated observed corpus evidence for the exact stored name
`war`; production consumers must still resolve and select IDs through
`searchMovieKeywords`.

Rules:

- At least one nonempty filter group is required.
- Each group accepts at most 10 positive IDs. Duplicate IDs are normalized away.
- Unknown IDs are validation errors; they are not silently dropped.
- `ALL` requires every ID within that group. `ANY` requires at least one.
- Nonempty keyword and genre groups combine with `AND`.
- A movie appears at most once. `matchedKeywords` and `matchedGenres` are the real
  intersections between requested IDs and stored movie metadata.
- `first` is 1–50.
- Order is release date descending, nulls last, then TMDb movie ID descending.
- `after` is opaque and is bound to normalized IDs and match modes. Malformed or
  filter-incompatible cursors fail. Page size may change between pages.
- Pagination is stable for unchanged data but does not provide snapshot isolation
  across concurrent corpus updates.

The `Movie` type also exposes batched `keywords` and `genres` fields with
`{ tmdbId, name }`. Existing movie lookup and title search behavior is unchanged.

## Copy-pastable request

```sh
curl --fail-with-body \
  --request POST \
  "$CINEGRAPH_GRAPHQL_URL" \
  --header "Authorization: Bearer $CINEGRAPH_API_KEY" \
  --header "Content-Type: application/json" \
  --header "User-Agent: Dictionary-Cinegraph/1.0" \
  --data '{"query":"query Search($query: String!, $limit: Int!) { searchMovieKeywords(query: $query, limit: $limit) { tmdbId name movieCount } }","variables":{"query":"war","limit":10}}'
```

The explicit user agent is recommended because the live readiness audit on
2026-09-12 Europe/Warsaw (2026-09-11 UTC) observed HTTP 403 responses from a
default Python user agent, while a named user agent reached GraphQL. The cause
was not established.

## Safety and query cost

The endpoint analyzes each GraphQL operation with a maximum complexity of 2,500,
limits parsed documents to 5,000 tokens, and caps an HTTP transport batch at 10
operations. Discovery list complexity scales with `first`; vocabulary list
complexity is also weighted. These controls complement the field-level bounds.
They are not a general quota or rate-limiting platform. Authentication telemetry
attributes the client/key and counts protected top-level fields as request-cost
units without including bearer tokens; per-consumer quotas remain deferred.

The supervised `Cinegraph.Telemetry.ApiAuthLogger` writes `catalog_api` JSON
records at info level for authentication outcomes and protected-field counts.
Filter production logs by that marker and `client_slug: legacy-shared-key` to
observe legacy traffic; `outcome` distinguishes rejected credentials from success.
These counts are protected-field units, not calculated GraphQL complexity.
Retain logs across the entire cutover observation window. No request payloads,
bearer tokens, secret digests, or arbitrary telemetry metadata enter these records.

Discovery uses a keyword-first `(keyword_id, movie_id)` index, the existing
genre-first index, grouped metadata matches, and batched metadata loads. A page
request with both filter groups and both Movie metadata fields executes five SQL
queries regardless of the number of returned movies: two ID-validation queries,
one page query, and two association preloads.

Implementation-time read-only measurements on local `cinegraph_dev`, run on
2026-09-12 Europe/Warsaw (2026-09-11 UTC), after one warm-up and with 12-result
pages (three observations each):

| Probe | Latency (ms) |
|---|---:|
| Keyword vocabulary search, `war` | 46.950, 35.269, 36.642 |
| Broad keyword vocabulary search, `a` | 69.224, 63.514, 67.270 |
| Keyword discovery, `war` | 21.474, 20.771, 20.276 |
| Keyword discovery, `nepotism` | 16.029, 12.735, 8.568 |
| Broad genre discovery, Drama (TMDb 18) | 330.030, 342.738, 344.238 |
| Combined `war` + Drama | 66.051, 67.812, 67.720 |

These are single-process local corpus observations, not production service-level
claims. The development database had not applied the new keyword-first migration
for this run, so deployment benchmarking should be repeated after migrating.
Keyword search filters and limits candidates before joining movie associations.
The 15-minute genre-vocabulary cache measured 872.345 ms for a cold aggregation
and 0.010, 0.002, and 0.001 ms for the next three local reads (19 genres).

## Provenance, images, and interpretation

Keywords, genres, metadata, and image paths originate from TMDb; Cinegraph is the
API provider and may have incomplete or stale stored metadata. A result explains
only “found through the keyword/genre …”. A later human or bot selection and its
rationale belong to the consuming application and must be separately attributed.

`posterPath` and `backdropPath` are paths, not rehosting permission. Missing
paths are valid results. Build a preview using TMDb image configuration (commonly
`https://image.tmdb.org/t/p/w500` plus the returned poster path), and retain
TMDb's current attribution, branding, licensing, and display requirements. See
TMDb's official [image URL documentation](https://developer.themoviedb.org/docs/image-basics)
and [attribution requirements](https://developer.themoviedb.org/docs/faq).

`cinegraphUrl` uses `CINEGRAPH_BASE_URL`; the non-development default and explicit
deployment setting are `https://cinegraph.org`. The earlier `.app` movie link
returned 404 during the release audit; the corresponding `.org` link returned
200. Consumers should use the returned canonical URL after this configuration
change is deployed.

## Coverage and freshness limitations

Local `cinegraph_dev` audit on 2026-09-12 Europe/Warsaw (2026-09-11 UTC; not
production):

| Measure | Result |
|---|---:|
| Fully imported movies | 934,224 |
| Full movies with keywords | 238,637 (25.5%) |
| Full movies with genres | 608,846 (65.2%) |
| Exact `war` keyword | TMDb 273967; 600 eligible movies |
| Exact `nepotism` keyword | TMDb 316148; 5 eligible movies |
| Exact `grief` keyword | TMDb 9872; 855 eligible movies |

Absence of a tag is not evidence that a film lacks a theme. Keyword refreshes
currently add associations without removing obsolete ones, preserve an existing
keyword name, and genre synchronization follows a different refresh path. If a
pilot term is missing or stale, use the existing targeted TMDb movie-refresh
infrastructure. Do not infer title matches, substitute broader meanings, or start
a full-corpus rebuild. A future synchronization change should distinguish a
successful empty upstream response from a fetch failure before replacing stored
associations.

### Pre-deployment live baseline

An authorized request on 2026-09-12 Europe/Warsaw (2026-09-11 UTC) to
`https://cinegraph.org/api/graphql` verified the existing
`movie(tmdbId: 667216)` lookup with the configured Bearer token. It returned
*Infinity Pool*, IMDb `tt10365998`, and
`https://cinegraph.app/movies/infinity-pool-2023`. Missing and incorrect tokens
both returned GraphQL `unauthorized` errors. This proves existing endpoint and
credential access only; it is not evidence that the discovery fields are
deployed.

## Deployment smoke checklist

After deploying the schema and migration, run this authenticated sequence against
the configured public endpoint without logging the key:

1. Search each pilot term (`war`, `nepotism`, `grief`) and record the actual IDs
   and eligible counts returned by that environment.
2. Deliberately select returned IDs and call `discoverMovies`; verify result
   metadata and `matchedKeywords`/`matchedGenres`.
3. Feed one returned `tmdbId` into the existing `movie(tmdbId: ...)` lookup.
4. Repeat one field with a missing and incorrect token and inspect GraphQL errors.
5. Record the deployed revision, environment, query counts, and representative
   broad/selective latency. Do not label fixture timings as production evidence.

For Wordhoard, start a fresh configured server, visit `war`, `nepotism`, and
`grief`, and verify keyword lookup → movie discovery → cards, cache reuse, and a
genuine empty result. Do not invent mappings or films. For Eventasaurus, run a
fresh known-movie lookup and a single-movie job, verify its persisted result and
the existing response shape, then exercise the scheduled sweep canary. Record the
environment, non-secret client ID/key ID, verification time, deployed release,
and observed attribution.

Code/test completion must not be reported as deployed or provisioned evidence.
Until this checklist is executed with deployment access, consumer provisioning
and live verification remain explicit completion gates.

## Release audit fixes and validation (2026-09-12 Europe/Warsaw; 2026-09-11 UTC)

The request guard checks merged body/query parameters, including decoded arrays
and JSON-encoded `_json`/`operations` values. Both keys are checked to prevent a
smaller batch from hiding an oversized one. HTTP regression tests cover GET and
POST, the 10-operation boundary, and conflicting parameters. Keyword candidates
are limited before movie-count aggregation, and genre counts use a short-lived
single-flight cache. The query-count assertion is scoped to the test process and
its supervised preload callers. Canonical movie links use `.org` in the runtime
default and deployment configuration. Pagination tests cross equal dates and
null dates one result at a time.

Validation: `mix test test/cinegraph_web/controllers/graphql_api_test.exs
test/cinegraph_web/schema test/cinegraph/configuration_test.exs` — 58 tests,
zero failures. Formatting checks pass for the changed Elixir files.

The pre-deployment live probe was repeated during PR review on 2026-09-12
Europe/Warsaw (2026-09-11 UTC): `searchMovieKeywords` still returned an unknown
field error, the historical `.app` movie URL returned HTTP 404, and the configured
`.org` URL returned HTTP 200. Deploy the schema, configuration, and index migration
before enabling Dictionary's production discovery adapter, then complete the
authenticated smoke checklist above. These checks do not certify a production
rollout.
