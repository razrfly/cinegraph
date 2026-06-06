defmodule Mix.Tasks.Predictions.Candidates do
  @moduledoc """
  Show a list's **predicted next additions** — films NOT on the list, ranked by the active
  model's score, with a calibrated probability of belonging (#1036 / #1038 preview).

  This is the CLI face of `Cinegraph.Predictions.Candidates` — the same read-model that powers the
  `/algorithms/:slug` predictive show page: known members + predicted next additions + held-out
  accuracy. It scores via the Layer-2 bus using the list's active `prediction_models` artifact and
  calibrates the score to a probability.

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
    --since        override the cutoff year (default: the resolved frontier — see below)
    --limit        how many rows to show (default 25)
    --min-sources  evidence eligibility (#1078 §0): require ≥ N distinct external-metric sources
                   (default 2; members mode is never gated). A presence rule — no single metric's
                   value can ever exclude a film.
    --min-votes    OPTIONAL popularity filter on any maintained vote source (default 0 = off)
    --why          print each row's exact model contributions (top terms, signed)
    --json         machine-readable output (rows include `why` + `signals_present`)

  The **frontier cutoff** is resolved per list by `ListFrontier`: the list's edition/published
  year if it has one, else its newest member's release year. Predictions are gated to that year
  forward, so a "prediction" is never an old film that already had its chance. A member is never
  a prediction; the default mode cannot show one. Each row lists the OTHER canonical lists the
  film is on as supporting evidence; the model is leakage-blind to membership.
  """
  use Mix.Task

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.Candidates

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
          min_sources: :integer,
          why: :boolean,
          json: :boolean
        ]
      )

    list = opts[:list] || "1001_movies"
    mode = parse_mode(opts[:mode])
    limit = opts[:limit] || 25
    # Eligibility is evidence-based (min_sources, #1078 §0); --min-votes is an OPTIONAL
    # popularity filter, off by default. The effective min_sources mirrors Candidates.rank/2:
    # members mode is never gated, otherwise --min-sources or the default 2.
    min_votes = opts[:min_votes] || 0
    min_sources = if mode == "members", do: 0, else: opts[:min_sources] || 2

    rank_opts =
      [mode: mode, limit: limit, min_votes: min_votes, since: opts[:since]]
      |> then(fn o ->
        if opts[:min_sources], do: Keyword.put(o, :min_sources, opts[:min_sources]), else: o
      end)

    case Candidates.rank(list, rank_opts) do
      {:error, :no_active_model} ->
        Mix.raise(
          "No active model for #{list}. Train one first: " <>
            "mix predictions.train --integrity --list-key #{list} --save"
        )

      {:ok, result} ->
        ctx = %{
          list: list,
          mode: mode,
          model: result.model,
          frontier: result.frontier,
          reliability: result.reliability,
          cutoff: result.cutoff,
          members: result.member_count,
          base_rate: Candidates.base_rate(result.member_count),
          scanned: result.scanned,
          min_votes: min_votes,
          min_sources: min_sources,
          why?: opts[:why] == true,
          ranked: result.rows
        }

        if opts[:json] do
          IO.puts(
            Jason.encode!(
              %{
                list: list,
                mode: mode,
                model_id: result.model.id,
                frontier: result.frontier,
                reliability: reliability_json(result.reliability),
                rows: result.rows
              },
              pretty: true
            )
          )
        else
          print(ctx)
        end
    end
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

  defp eligibility_label(min_sources, 0), do: "evidence-eligible: ≥#{min_sources} metric sources"

  defp eligibility_label(min_sources, min_votes),
    do: "evidence-eligible: ≥#{min_sources} metric sources + min votes #{min_votes}"

  defp signed(c) when is_number(c) and c >= 0,
    do: "+#{:erlang.float_to_binary(c * 1.0, decimals: 1)}"

  defp signed(c), do: :erlang.float_to_binary(c * 1.0, decimals: 1)

  defp parse_mode(nil), do: "predictions"
  defp parse_mode(m) when m in ~w(predictions candidates members all), do: m

  defp parse_mode(m),
    do:
      Mix.raise(
        "invalid --mode #{inspect(m)} (expected predictions | candidates | members | all)"
      )

  defp print(ctx) do
    name = MovieLists.get_by_source_key(ctx.list) |> then(&((&1 && &1.name) || ctx.list))
    recall = ctx.model.integrity_report["recall_at_k"]
    pop = get_in(ctx.model.integrity_report, ["baselines", "popularity"])
    tagged? = ctx.mode == "all"

    Mix.shell().info("""

    "#{name}" — model #{ctx.model.feature_set["granularity"]}, held-out recall@K #{pct(recall)} (vs popularity #{pct(pop)})
    #{reliability_line(ctx.reliability)}
    known members: #{ctx.members} · base rate ≈ #{pct(ctx.base_rate)} · scanned #{ctx.scanned} films (#{eligibility_label(ctx.min_sources, ctx.min_votes)})
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

      # --why: the film's exact linear contributions (#1076 P1), top terms signed.
      if ctx.why? and c[:why] not in [nil, []] do
        why_line =
          c.why
          |> Enum.map(fn t -> "#{t.label} #{signed(t.contribution)}" end)
          |> Enum.join(" · ")

        Mix.shell().info("        why: #{why_line}")
      end
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

  defp year_suffix(nil), do: ""
  defp year_suffix(y), do: " (#{y})"

  defp pct(nil), do: "—"
  defp pct(f) when is_float(f), do: "#{Float.round(f * 100, 2)}%"
  defp pct(_), do: "—"

  defp pad(v, n), do: v |> to_string() |> String.pad_trailing(n)
end
