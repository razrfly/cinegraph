defmodule Mix.Tasks.Predictions.Candidates do
  @moduledoc """
  Show a list's **predicted next additions** — films NOT on the list, ranked by the active
  model's score, with a calibrated probability of belonging (#1036 / #1038 preview).

  This is the CLI preview of the `/algorithms/:slug` predictive show page: known members +
  predicted next additions + held-out accuracy. It scores via the Layer-2 bus using the list's
  active `prediction_models` artifact and calibrates the score to a probability.

      mix predictions.candidates --list 1001_movies                  # next-edition predictions (default)
      mix predictions.candidates --list 1001_movies --mode candidates # canon-fit, all eras (NOT predictions)
      mix predictions.candidates --list 1001_movies --mode members   # known members + their numbers
      mix predictions.candidates --list 1001_movies --mode all       # everything, tagged
      mix predictions.candidates --list 1001_movies --since 2020     # override the cutoff year
      mix predictions.candidates --list 1001_movies --json

  Options:
    --list       source_key of the list (default 1001_movies)
    --mode       what to rank (default `predictions`):
                   * `predictions` — off-list films AT/AFTER the list's frontier cutoff. The real
                     next-edition prediction (old films can't appear — they were already passed over)
                   * `candidates`  — off-list films, ALL eras. Canon-FIT but NOT predictions
                     (many older ones were considered over editions and never added)
                   * `members`     — ONLY films already on the list, ranked by the model's score
                   * `all`         — everything together, tagged `[MEMBER]`/`[PREDICT]`
    --since      override the cutoff year (default: the resolved frontier — see below)
    --limit      how many rows to show (default 25)
    --min-votes  only score films with ≥ this many TMDb votes (default 1000). 0 = whole catalog.
    --json       machine-readable output

  The **frontier cutoff** is resolved per list by `ListFrontier`: the list's edition/published
  year if it has one, else its newest member's release year. Predictions are gated to that year
  forward, so a "prediction" is never an old film that already had its chance. A member is never
  a prediction; the default mode cannot show one. Each row lists the OTHER canonical lists the
  film is on as supporting evidence; the model is leakage-blind to membership.
  """
  use Mix.Task

  import Ecto.Query

  alias Cinegraph.Movies.{Movie, MovieLists}
  alias Cinegraph.Predictions.{ListFrontier, PreRegistration, ProbabilityCalibration, Reliability}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  @shortdoc "Rank off-list films by predicted probability of belonging to a list"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          list: :string,
          mode: :string,
          since: :integer,
          limit: :integer,
          min_votes: :integer,
          json: :boolean
        ]
      )

    list = opts[:list] || "1001_movies"
    mode = parse_mode(opts[:mode])
    limit = opts[:limit] || 25
    min_votes = opts[:min_votes] || 1000

    model =
      Bus.active_model(list) ||
        Mix.raise(
          "No active model for #{list}. Train one first: " <>
            "mix predictions.train --integrity --list-key #{list} --save"
        )

    frontier = ListFrontier.resolve(list)
    cutoff = if mode == "predictions", do: opts[:since] || frontier.cutoff_year

    # Reliability gates the predictions: when it's Insufficient or the model is only
    # identity-calibrated, the per-row probability is a fake `score/100` and must NOT be shown.
    reliability = reliability_for(model, frontier)
    show_prob? = reliability.grade != :insufficient and reliability.calibration != "identity"

    candidates = candidate_movies(list, min_votes, mode, cutoff)
    scores = Bus.score(candidates, model)

    ranked =
      candidates
      |> Enum.map(fn m ->
        score = Map.get(scores, m.id, 0.0)

        %{
          id: m.id,
          title: m.title,
          year: year(m),
          score: score,
          prob:
            if(show_prob?, do: ProbabilityCalibration.apply_calibration(model.calibration, score)),
          member?: Map.has_key?(m.canonical_sources || %{}, list),
          also_on: also_on(m, list)
        }
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    ctx = %{
      list: list,
      mode: mode,
      model: model,
      frontier: frontier,
      reliability: reliability,
      cutoff: cutoff,
      members: member_count(list),
      base_rate: nil,
      scanned: length(candidates),
      min_votes: min_votes,
      ranked: ranked
    }

    ctx = %{ctx | base_rate: list_base_rate(ctx.members)}

    if opts[:json] do
      IO.puts(
        Jason.encode!(
          %{
            list: list,
            mode: mode,
            model_id: model.id,
            frontier: frontier,
            reliability: reliability_json(reliability),
            rows: ranked
          },
          pretty: true
        )
      )
    else
      print(ctx)
    end
  end

  # Reliability via the pure core, reusing the already-resolved frontier (no second DB resolve).
  # `Bus.active_model/1` does not preload the prereg, so load it here for the threshold cap.
  defp reliability_for(model, frontier) do
    prereg = Repo.preload(model, :pre_registration).pre_registration

    Reliability.score(model.integrity_report, model.calibration, %{
      is_stale: model.is_stale,
      frontier: frontier,
      threshold: prereg && PreRegistration.threshold_value(prereg),
      prereg?: not is_nil(prereg)
    })
  end

  defp reliability_json(r) do
    {lo, hi} = r.ci

    %{
      grade: to_string(r.grade),
      band_grade: to_string(r.band_grade),
      headline_pct: r.headline_pct,
      ci: [lo, hi],
      reasons: r.reasons
    }
  end

  defp parse_mode(nil), do: "predictions"
  defp parse_mode(m) when m in ~w(predictions candidates members all), do: m

  defp parse_mode(m),
    do:
      Mix.raise(
        "invalid --mode #{inspect(m)} (expected predictions | candidates | members | all)"
      )

  # Other canonical lists this film is on (target excluded) — supporting evidence.
  defp also_on(movie, list) do
    (movie.canonical_sources || %{})
    |> Map.keys()
    |> Enum.reject(&(&1 == list))
    |> Enum.sort()
  end

  defp print(ctx) do
    name = MovieLists.get_by_source_key(ctx.list) |> then(&((&1 && &1.name) || ctx.list))
    recall = ctx.model.integrity_report["recall_at_k"]
    pop = get_in(ctx.model.integrity_report, ["baselines", "popularity"])
    tagged? = ctx.mode == "all"

    Mix.shell().info("""

    "#{name}" — model #{ctx.model.feature_set["granularity"]}, held-out recall@K #{pct(recall)} (vs popularity #{pct(pop)})
    #{reliability_line(ctx.reliability)}
    known members: #{ctx.members} · base rate ≈ #{pct(ctx.base_rate)} · scanned #{ctx.scanned} films (min votes #{ctx.min_votes})
    #{frontier_line(ctx.frontier)}
    #{mode_intro(ctx.mode, ctx.cutoff)}

      #   #{if tagged?, do: "STATUS     ", else: ""}SCORE  TITLE (year)            also on
    """)

    Enum.each(ctx.frontier.warnings, &Mix.shell().info("    ⚠ #{&1}"))
    if ctx.frontier.warnings != [], do: Mix.shell().info("")

    ctx.ranked
    |> Enum.with_index(1)
    |> Enum.each(fn {c, i} ->
      tag = if tagged?, do: pad(if(c.member?, do: "[MEMBER]", else: "[PREDICT]"), 11), else: ""
      title = "#{c.title}#{year_suffix(c.year)}"
      evidence = if c.also_on == [], do: "—", else: Enum.join(c.also_on, ", ")

      Mix.shell().info(
        "  #{pad(i, 3)}  #{tag}#{pad(Float.round(c.score, 1), 5)}  #{pad(title, 22)}  #{evidence}"
      )
    end)

    Mix.shell().info("\n#{mode_footer(ctx.mode)}")
  end

  defp reliability_line(r) do
    grade = r.grade |> to_string() |> String.upcase()

    # When caps lowered the grade below what the headline earns, say so — otherwise a LOW next
    # to a high Wilson headline reads as a contradiction.
    capped =
      if r.band_grade != r.grade,
        do: "capped from #{r.band_grade |> to_string() |> String.upcase()} · ",
        else: ""

    headline =
      case r.headline_pct do
        "—" -> "—"
        pct -> "headline #{pct}% Wilson-95"
      end

    reason =
      cond do
        r.reasons != [] -> hd(r.reasons)
        r.grade == :high -> "clears every gate"
        true -> "no integrity penalties — grade reflects the accuracy lower bound itself"
      end

    suppressed =
      unless r.sufficient? and r.calibration != "identity", do: " · per-film probabilities hidden"

    "reliability: #{grade} (#{capped}#{headline}) — #{reason}#{suppressed}"
  end

  defp frontier_line(%{cutoff_year: nil}),
    do: "frontier: no cutoff (no edition year, no dated members) — recency gate OFF"

  defp frontier_line(f) do
    src = if f.cutoff_source == :edition, do: "edition", else: "newest member"

    newest =
      if f.newest_member_title,
        do: " · newest member #{f.newest_member_title} (#{f.newest_member_year})",
        else: ""

    fresh = if f.fresh?, do: "fresh ✓", else: "STALE ⚠"

    "frontier: cutoff #{f.cutoff_year} (from #{src})#{newest} · imported #{import_short(f.last_import_at)} #{fresh}"
  end

  defp import_short(nil), do: "never"
  defp import_short(dt), do: dt |> to_string() |> String.slice(0, 10)

  defp mode_intro("predictions", nil),
    do: "PREDICTIONS — off-list films (no frontier cutoff available, so ALL eras are shown)"

  defp mode_intro("predictions", cutoff),
    do:
      "NEXT-EDITION PREDICTIONS — off-list films released #{cutoff}+ (older films already had their chance)"

  defp mode_intro("candidates", _),
    do:
      "CANON-FIT CANDIDATES (all eras) — off-list films that FIT the canon but are NOT predictions"

  defp mode_intro("members", _),
    do:
      "KNOWN MEMBERS — already on the list, NOT predictions; ranked to inspect how it rates canon"

  defp mode_intro("all", _),
    do: "ALL — members + off-list films together; `[MEMBER]` rows are NOT predictions"

  defp mode_footer("candidates"),
    do:
      "Canon-FIT, but NOT predictions — older off-list films were eligible across editions and not\n" <>
        "added. For the genuine next-edition list use `--mode predictions` (frontier-gated)."

  defp mode_footer("members"),
    do:
      "These are existing members (not predictions). The model is leakage-blind to membership,\n" <>
        "so high scores here = it independently recognizes canon — the validation signal."

  defp mode_footer("all"),
    do:
      "`[PREDICT]` = NOT on the list. `[MEMBER]` = existing member, shown for validation only\n" <>
        "(the model never saw membership). A member is never a prediction."

  defp mode_footer(_predictions),
    do:
      "Every row is a genuine prediction: off-list AND past the list's frontier. `--mode candidates`\n" <>
        "for all-era canon-fit films; `--mode members` / `all` to validate."

  # Fully-imported films, gated by min votes and scoped by mode:
  #   predictions → off-list AND release_year ≥ cutoff   candidates → off-list, all eras
  #   members → only members   all → no filter
  defp candidate_movies(list, min_votes, mode, cutoff) do
    base =
      from m in Movie,
        where: m.import_status == "full",
        select: %Movie{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          canonical_sources: m.canonical_sources
        }

    base
    |> scope_by_mode(list, mode, cutoff)
    |> maybe_min_votes(min_votes)
    |> Repo.all(timeout: :timer.seconds(120))
  end

  defp scope_by_mode(query, list, "predictions", cutoff) do
    query
    |> where([m], not fragment("? \\? ?", m.canonical_sources, ^list))
    |> recency_gate(cutoff)
  end

  defp scope_by_mode(query, list, "candidates", _cutoff),
    do: where(query, [m], not fragment("? \\? ?", m.canonical_sources, ^list))

  defp scope_by_mode(query, list, "members", _cutoff),
    do: where(query, [m], fragment("? \\? ?", m.canonical_sources, ^list))

  defp scope_by_mode(query, _list, "all", _cutoff), do: query

  defp recency_gate(query, nil), do: query

  defp recency_gate(query, cutoff),
    do: where(query, [m], fragment("EXTRACT(YEAR FROM ?) >= ?", m.release_date, ^cutoff))

  defp maybe_min_votes(query, 0), do: query

  defp maybe_min_votes(query, min_votes) do
    where(
      query,
      [m],
      fragment(
        "EXISTS (SELECT 1 FROM external_metrics em WHERE em.movie_id = ? AND em.source = 'tmdb' AND em.metric_type = 'rating_votes' AND em.value >= ?)",
        m.id,
        ^min_votes
      )
    )
  end

  defp member_count(list) do
    Repo.aggregate(
      from(m in Movie, where: fragment("? \\? ?", m.canonical_sources, ^list)),
      :count
    )
  end

  defp list_base_rate(members) do
    total = Repo.aggregate(from(m in Movie, where: m.import_status == "full"), :count)
    if total > 0, do: members / total, else: nil
  end

  defp year(%{release_date: %Date{year: y}}), do: y
  defp year(_), do: nil
  defp year_suffix(nil), do: ""
  defp year_suffix(y), do: " (#{y})"

  defp pct(nil), do: "—"
  defp pct(f) when is_float(f), do: "#{Float.round(f * 100, 2)}%"
  defp pct(_), do: "—"

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end
