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
CINEGRAPH_API_KEY=<provisioned shared secret>
```

Send the key only from the consumer server:

```text
Authorization: Bearer <CINEGRAPH_API_KEY>
```

Do not expose this shared credential in browser bundles. No browser CORS change
is required for this integration. Cinegraph uses its existing shared
server-to-server key; this change does not rotate it or create a second key.
Production startup fails if `CINEGRAPH_API_KEY` is missing, empty, or whitespace
only. Development and test retain the documented no-key bypass when the setting
is absent. Missing and incorrect request tokens produce a GraphQL `unauthorized`
error (normally in an HTTP 200 response), so consumers must inspect `errors` and
not use HTTP status alone as the success signal.

Deployment and consumer secret provisioning are separate operational steps.
Source availability does not prove that this contract is live.

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
They are not a general quota, per-client auditing, or rate-limiting platform.

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

Until that checklist is executed, live availability of the new fields and
consumer credential provisioning remain outstanding.

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
