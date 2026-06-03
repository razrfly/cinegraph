defmodule Cinegraph.Predictions.CandidateUniverse do
  @moduledoc """
  The id-level candidate universe (#1051) — a single source for "which movies count as
  realistic prediction candidates for a list", used by the Stage A1 coverage audit and the
  Stage A2 scoped backfill.

  Mirrors the predicate set in `Cinegraph.Predictions.Trainer.candidate_universe/2` (list
  members + the most-voted non-members), but returns only movie **ids** (no Movie structs),
  so it is cheap to call for auditing and for scoping a backfill to ~5K movies instead of the
  whole catalog. Keep the predicates in sync with the Trainer if that one changes.
  """

  import Ecto.Query
  alias Cinegraph.Repo

  @default_min_votes 1000

  @doc """
  `{member_ids, negative_ids}` for one list — a vote-gated candidate set for **coverage diagnostics
  and backfill targeting** (the `audit_coverage --source-key` confound report, the `eval_indicators`
  control). Members = movies whose `canonical_sources` contains `source_key` (import_status
  `"full"`); negatives = the most-voted non-members with tmdb `rating_votes >= :min_votes`, capped.

  NOTE (#1055): this is NOT the model **evaluation** universe. Curated negatives (vote-gated here)
  are selection-biased and gameable; honest model evaluation ranks members against the FULL decade
  pool via `Cinegraph.Predictions.Credibility.evaluate/3`. Use `ids_for/2` only for diagnostics.
  """
  def ids_for(source_key, opts \\ []) when is_binary(source_key) do
    min_votes = Keyword.get(opts, :min_votes, @default_min_votes)

    members =
      Repo.all(
        from m in "movies",
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          where: m.import_status == "full",
          select: m.id
      )

    cap = Keyword.get(opts, :universe_cap, max(5000, length(members) * 25))

    negs =
      Repo.all(
        from(m in "movies",
          join: em in "external_metrics",
          on:
            em.movie_id == m.id and em.source == "tmdb" and
              em.metric_type == "rating_votes" and em.value >= ^min_votes,
          where: m.import_status == "full",
          where: not fragment("? \\? ?", m.canonical_sources, ^source_key),
          order_by: [desc: em.value, asc: m.id],
          limit: ^cap,
          select: m.id
        ),
        timeout: :timer.seconds(120)
      )

    {members, negs}
  end

  @doc """
  The **global** vote-gated universe across every canonical list: `{member_ids, negative_ids}` where
  members = movies on ANY canonical list (`canonical_sources <> '{}'`), and negatives = the
  most-voted off-list movies with tmdb `rating_votes >= :min_votes`, capped.

  For *backfill targeting* (densify the high-value, most-watched movies) — NOT model evaluation.
  """
  def global_ids(opts \\ []) do
    min_votes = Keyword.get(opts, :min_votes, @default_min_votes)

    members =
      Repo.all(
        from m in "movies",
          where: fragment("? <> '{}'::jsonb", m.canonical_sources),
          where: m.import_status == "full",
          select: m.id
      )

    cap = Keyword.get(opts, :universe_cap, max(5000, length(members) * 5))

    negs =
      Repo.all(
        from(m in "movies",
          join: em in "external_metrics",
          on:
            em.movie_id == m.id and em.source == "tmdb" and
              em.metric_type == "rating_votes" and em.value >= ^min_votes,
          where: m.import_status == "full",
          where: fragment("? = '{}'::jsonb", m.canonical_sources),
          order_by: [desc: em.value, asc: m.id],
          limit: ^cap,
          select: m.id
        ),
        timeout: :timer.seconds(120)
      )

    {members, negs}
  end
end
