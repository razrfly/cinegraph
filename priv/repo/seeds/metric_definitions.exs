# Seed file for the Layer-0 metric-definition catalog (#1036).
# Run with: mix run priv/repo/seeds/metric_definitions.exs
#
# The definitions live in Cinegraph.Metrics.CatalogSeed so the seed and tests
# share one source of truth.

count = Cinegraph.Metrics.CatalogSeed.seed!()
IO.puts("Upserted #{count} metric definitions")
