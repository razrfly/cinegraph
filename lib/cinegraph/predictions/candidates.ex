defmodule Cinegraph.Predictions.Candidates do
  @moduledoc """
  A list's **predicted next additions** (and related rankings) as a reusable read-model — the
  extracted core of `mix predictions.candidates`, shared by the CLI and the `/algorithms/:slug`
  predictive show page (#1038 Phase B).

  Scores off-list films via the Layer-2 `Bus` using the list's active `prediction_models` artifact,
  **frontier-gates** real predictions to the list's cutoff year (`ListFrontier` — an old film that
  was passed over for editions is canon-*fit*, not a prediction), and calibrates scores to
  probabilities — which are exposed **only** when the honesty gate passes (`reliability.grade !=
  :insufficient` and the calibration is an increasing Platt fit —
  `ProbabilityCalibration.informative?/1`). No fake percentages, ever.
  """

  import Ecto.Query

  alias Cinegraph.Movies.Movie

  alias Cinegraph.Predictions.{
    Explanation,
    ListFrontier,
    PreRegistration,
    ProbabilityCalibration,
    Reliability
  }

  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  @modes ~w(predictions candidates members all)
  # Top contribution terms returned per row/probe — enough to answer "why", small enough for a card.
  @why_limit 5

  @doc "Valid ranking modes."
  def modes, do: @modes

  @doc """
  Rank films for `source_key` under the active model.

  Options: `:mode` (#{inspect(@modes)}, default `"predictions"`), `:limit` (default 48),
  `:min_sources` (evidence eligibility — distinct external-metric sources required; defaults to
  2 except in members mode, where members are never gated), `:min_votes` (optional popularity
  filter, default 0 = off), `:since` (override the frontier cutoff year; predictions mode only).

  Returns `{:ok, result}` with:
    * `rows` — `[%{id, title, year, score, prob, member?, also_on, poster_path, slug, why,
      signals_present}]`, score-desc; `prob` is nil unless the honesty gate passes; `why` is the
      film's exact model contribution breakdown (#1076 P1) — top #{@why_limit}
      `%{code, label, value, contribution}` terms, signed; `signals_present` is the **number of
      nonzero contribution terms** (signals actually moving this score — deliberately NOT "populated
      features": derived features can emit a populated 0.0 meaning *known false*, which moves
      nothing). JSON-safe maps.
    * `frontier`, `reliability`, `show_prob?`, `model`, `cutoff`, `scanned`, `member_count`.

  `{:error, :no_active_model}` when nothing is served for the list.
  """
  def rank(source_key, opts \\ []) do
    mode = validate_mode(Keyword.get(opts, :mode, "predictions"))
    limit = Keyword.get(opts, :limit, 48)
    min_votes = Keyword.get(opts, :min_votes, 0)
    min_sources = Keyword.get(opts, :min_sources, default_min_sources(mode))

    case Bus.active_model(source_key) do
      nil ->
        {:error, :no_active_model}

      model ->
        frontier = ListFrontier.resolve(source_key)
        cutoff = if mode == "predictions", do: Keyword.get(opts, :since) || frontier.cutoff_year

        # Reliability gates the probabilities: an Insufficient grade, an identity calibration
        # (fake score/100), or a non-increasing Platt fit (% would anti-correlate with rank) all
        # mean per-row probabilities must NOT be shown.
        reliability = reliability_for(model, frontier)

        show_prob? =
          reliability.grade != :insufficient and
            ProbabilityCalibration.informative?(model.calibration)

        candidates = candidate_movies(source_key, min_votes, min_sources, mode, cutoff)
        scores = Bus.score(candidates, model)

        rows =
          candidates
          |> Enum.map(fn m ->
            score = Map.get(scores, m.id, 0.0)

            %{
              id: m.id,
              title: m.title,
              year: year(m),
              score: score,
              prob:
                if(show_prob?,
                  do: ProbabilityCalibration.apply_calibration(model.calibration, score)
                ),
              member?: Map.has_key?(m.canonical_sources || %{}, source_key),
              also_on: also_on(m, source_key),
              poster_path: m.poster_path,
              slug: m.slug
            }
          end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)
          |> attach_why(candidates, model)

        {:ok,
         %{
           rows: rows,
           frontier: frontier,
           reliability: reliability,
           show_prob?: show_prob?,
           model: model,
           cutoff: cutoff,
           scanned: length(candidates),
           member_count: member_count(source_key)
         }}
    end
  end

  @doc "Frontier-gated next-edition predictions (`mode: \"predictions\"`)."
  def next_additions(source_key, opts \\ []),
    do: rank(source_key, Keyword.put(opts, :mode, "predictions"))

  @doc """
  A list's member movies for a poster grid — `%Movie{}` structs (id/title/release_date/poster_path/
  slug/canonical_sources), newest first. Deliberately *not* the Search/Flop infra: `/lists/:slug`
  remains the full browser; this feeds the show page's Members tab.
  """
  def members(source_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 48)

    Repo.all(
      from m in Movie,
        where: m.import_status == "full",
        where: fragment("? \\? ?", m.canonical_sources, ^source_key),
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          poster_path: m.poster_path,
          slug: m.slug,
          canonical_sources: m.canonical_sources
        },
        order_by: [desc_nulls_last: m.release_date],
        limit: ^limit
    )
  end

  @doc """
  Score ONE movie for the list under the served model (the show page's live probe). Scores through
  the same Bus path as `rank/2` — **not** the lens engine, which would be a different model.

  Returns `{:ok, %{score, prob, show_prob?, member?, eligible?, frontier, reliability, why,
  present_features, total_features}}` or `{:error, :no_active_model}`. `eligible?` = past the
  frontier cutoff (a genuine prediction candidate) — nil when the list has no cutoff. `why` is the
  exact contribution breakdown (#1076 P1). `present_features` is the **number of nonzero
  contribution terms** — signals actually moving this score, deliberately not "populated features"
  (a populated 0.0 derived feature moves nothing); `total_features` = the model's full surface.
  """
  def probe(source_key, %Movie{} = movie) do
    case Bus.active_model(source_key) do
      nil ->
        {:error, :no_active_model}

      model ->
        frontier = ListFrontier.resolve(source_key)
        reliability = reliability_for(model, frontier)

        show_prob? =
          reliability.grade != :insufficient and
            ProbabilityCalibration.informative?(model.calibration)

        score = Bus.score([movie], model) |> Map.get(movie.id, 0.0)

        {why_terms, present} =
          case Bus.contributions([movie], model) do
            {:error, _} -> {[], nil}
            by_id -> by_id |> Map.get(movie.id, []) |> then(&{&1, length(&1)})
          end

        eligible? =
          case {frontier.cutoff_year, year(movie)} do
            {nil, _} -> nil
            {_, nil} -> nil
            {cutoff, y} -> y >= cutoff
          end

        {:ok,
         %{
           score: score,
           prob:
             if(show_prob?,
               do: ProbabilityCalibration.apply_calibration(model.calibration, score)
             ),
           show_prob?: show_prob?,
           member?: Map.has_key?(movie.canonical_sources || %{}, source_key),
           eligible?: eligible?,
           frontier: frontier,
           reliability: reliability,
           why: shape_why(why_terms),
           present_features: present,
           total_features: map_size(model.weights || %{})
         }}
    end
  end

  @doc "Reliability scorecard for a served model, reusing an already-resolved frontier."
  def reliability_for(model, frontier) do
    prereg = Repo.preload(model, :pre_registration).pre_registration

    Reliability.score(model.integrity_report, model.calibration, %{
      is_stale: model.is_stale,
      frontier: frontier,
      threshold: prereg && PreRegistration.threshold_value(prereg),
      prereg?: not is_nil(prereg)
    })
  end

  @doc "How many movies are on the list."
  def member_count(source_key) do
    Repo.aggregate(
      from(m in Movie, where: fragment("? \\? ?", m.canonical_sources, ^source_key)),
      :count
    )
  end

  @doc "Members ÷ fully-imported catalog (the needle-in-haystack base rate)."
  def base_rate(member_count) do
    total = Repo.aggregate(from(m in Movie, where: m.import_status == "full"), :count)
    if total > 0, do: member_count / total, else: nil
  end

  # ── internals ────────────────────────────────────────────────────────────────────────
  defp validate_mode(mode) when mode in @modes, do: mode

  defp validate_mode(other),
    do:
      raise(ArgumentError, "invalid mode #{inspect(other)} (expected one of #{inspect(@modes)})")

  # The exact "why" (#1076 P1) — per-film linear contributions, computed only for the returned
  # top-`limit` rows (one batched feature load, not the whole scanned pool). Labeled and capped
  # to the top #{@why_limit} terms; an empty list when the model class can't expose terms.
  # `signals_present` = nonzero-term count BEFORE the cap — intentionally "signals moving this
  # score", not "populated features" (a populated 0.0 derived feature moves nothing).
  defp attach_why(rows, candidates, model) do
    row_ids = MapSet.new(rows, & &1.id)
    top_movies = Enum.filter(candidates, &MapSet.member?(row_ids, &1.id))

    case Bus.contributions(top_movies, model) do
      {:error, _} ->
        Enum.map(rows, &Map.merge(&1, %{why: [], signals_present: nil}))

      by_id ->
        Enum.map(rows, fn row ->
          terms = Map.get(by_id, row.id, [])
          Map.merge(row, %{why: shape_why(terms), signals_present: length(terms)})
        end)
    end
  end

  defp shape_why(terms) do
    terms
    |> Enum.take(@why_limit)
    |> Enum.map(fn t ->
      %{
        code: t.code,
        label: Explanation.label_for(t.code),
        value: t.value,
        contribution: t.contribution
      }
    end)
  end

  # Other canonical lists this film is on (target excluded) — supporting evidence only;
  # the model is leakage-blind to membership.
  defp also_on(movie, source_key) do
    (movie.canonical_sources || %{})
    |> Map.keys()
    |> Enum.reject(&(&1 == source_key))
    |> Enum.sort()
  end

  @doc """
  The composable (unscored) candidate-universe query for a list — fully-imported films, gated by
  **evidence** (`:min_sources`) and optionally popularity (`:min_votes`), scoped by `:mode`
  (+ `:cutoff` for predictions). Public so the embedded tuner can re-rank the *same* universe
  through the lens-cache path (`DiscoveryScoringSimple.apply_scoring/3`) without duplicating the
  scoping rules.

  **Eligibility principle (#1078 §0):** absence of one metric never disqualifies a film. The
  default gate is `min_sources: 2` — the film has been observed by ≥2 independent systems
  (tmdb + any of imdb/omdb/rotten_tomatoes/metacritic/…) — a presence-of-evidence rule, never a
  value threshold on any single metric. Members mode is never gated (`min_sources: 0`): list
  membership is the truth, not a candidate.
  """
  def universe_query(source_key, opts \\ []) do
    mode = validate_mode(Keyword.get(opts, :mode, "predictions"))
    min_votes = Keyword.get(opts, :min_votes, 0)
    min_sources = Keyword.get(opts, :min_sources, default_min_sources(mode))
    cutoff = Keyword.get(opts, :cutoff)

    base =
      from m in Movie,
        where: m.import_status == "full",
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          canonical_sources: m.canonical_sources,
          poster_path: m.poster_path,
          slug: m.slug
        }

    base
    |> scope_by_mode(source_key, mode, cutoff)
    |> maybe_min_sources(min_sources)
    |> maybe_min_votes(min_votes)
  end

  defp default_min_sources("members"), do: 0
  defp default_min_sources(_mode), do: 2

  # Fully-imported films, gated by evidence (+ optional votes) and scoped by mode:
  #   predictions → off-list AND release_year ≥ cutoff   candidates → off-list, all eras
  #   members → only members   all → no filter
  defp candidate_movies(source_key, min_votes, min_sources, mode, cutoff) do
    source_key
    |> universe_query(mode: mode, min_votes: min_votes, min_sources: min_sources, cutoff: cutoff)
    |> Repo.all(timeout: :timer.seconds(120))
  end

  defp scope_by_mode(query, source_key, "predictions", cutoff) do
    query
    |> where([m], not fragment("? \\? ?", m.canonical_sources, ^source_key))
    |> recency_gate(cutoff)
  end

  defp scope_by_mode(query, source_key, "candidates", _cutoff),
    do: where(query, [m], not fragment("? \\? ?", m.canonical_sources, ^source_key))

  defp scope_by_mode(query, source_key, "members", _cutoff),
    do: where(query, [m], fragment("? \\? ?", m.canonical_sources, ^source_key))

  defp scope_by_mode(query, _source_key, "all", _cutoff), do: query

  defp recency_gate(query, nil), do: query

  defp recency_gate(query, cutoff),
    do: where(query, [m], fragment("EXTRACT(YEAR FROM ?) >= ?", m.release_date, ^cutoff))

  # Evidence eligibility (#1078 §0): the film must have been observed by >= N independent metric
  # sources. A presence rule, not a value threshold — no single metric's absence or staleness can
  # exclude a film (the failure mode that shrank the 1001 pool to 41 films and ranked Smile 2
  # while excluding The Brutalist).
  defp maybe_min_sources(query, n) when is_integer(n) and n <= 0, do: query

  defp maybe_min_sources(query, n) do
    where(
      query,
      [m],
      fragment(
        "(SELECT count(DISTINCT em.source) FROM external_metrics em WHERE em.movie_id = ?) >= ?",
        m.id,
        ^n
      )
    )
  end

  # OPTIONAL popularity filter (off by default — eligibility is min_sources, never a vote count).
  # When requested, floors on ANY maintained vote source: TMDb counts are written once at import
  # and go stale, while IMDb votes are refreshed daily by the ratings worker.
  defp maybe_min_votes(query, 0), do: query

  defp maybe_min_votes(query, min_votes) do
    where(
      query,
      [m],
      fragment(
        "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source IN ('imdb', 'tmdb') AND em.metric_type = 'rating_votes' AND em.value >= ?)",
        m.id,
        ^min_votes
      )
    )
  end

  defp year(%{release_date: %Date{year: y}}), do: y
  defp year(_), do: nil
end
