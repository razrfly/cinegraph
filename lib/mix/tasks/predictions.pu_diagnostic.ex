defmodule Mix.Tasks.Predictions.PuDiagnostic do
  @moduledoc """
  Positive-Unlabeled / SAR diagnostic (#1070 Lever C de-risk).

  **Question:** is our "not on a list" set *unlabeled* in a feature-dependent way (SAR), or are labeled
  positives a random sample of all positives (SCAR)? This decides the next slice:

    * **SAR-strong** → labeling propensity depends on observable features; a binary "unlabeled = negative"
      model is systematically biased against the scarce-coverage arthouse canon → **build Lever C**
      (propensity / coverage-aware PU reweighting).
    * **SCAR-ish** → coverage/era/language don't bias membership beyond genuine canonicity → PU
      reweighting won't help (much of it was already banked by #1055's era-stratified negatives) →
      **skip C, go to Lever E** (text embeddings, the genuinely new channel).

  **The decisive signal — the inverted coverage confound.** Canon members (arthouse/old/foreign) tend
  to have *fewer* objective metrics populated than the popular films that dominate the unlabeled pool
  (#1068 noted this). If so, an unlabeled-as-negative learner conflates "low coverage" with "negative"
  — exactly mislabeling canon. We measure it three ways, holdout-free, on a sample:

    1. **Coverage gap** — median objective-metric coverage of members vs a random pool sample.
    2. **Coverage→membership AUC** (Mann-Whitney, tie-aware). **< 0.5 ⇒ members are under-covered**
       (the SAR confound); ≈ 0.5 ⇒ coverage is neutral (SCAR-ish on coverage).
    3. **Language / era skew** — members %non-English and median decade vs the pool sample.

  This is a *measurement only* — no training, no holdout, no DB writes.

  ## Usage
      mix predictions.pu_diagnostic                 # pooled: all canonical members vs pool
      mix predictions.pu_diagnostic --source-key criterion
      mix predictions.pu_diagnostic --sample 12000 --json
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Repo

  @shortdoc "PU/SAR diagnostic: is canon under-covered? (decides Lever C vs E) (#1070)"

  # Core objective raw metrics whose *presence* varies across films (the coverage surface that the SAR
  # confound bites). release_year/original_language are ~universal → excluded so coverage discriminates.
  @coverage_codes ~w(imdb_rating tmdb_rating metacritic_metascore rotten_tomatoes_tomatometer
                     rotten_tomatoes_audience_score imdb_rating_votes tmdb_rating_votes
                     tmdb_popularity_score tmdb_budget tmdb_revenue_worldwide runtime)
  @n_codes length(@coverage_codes)
  @chunk 1500

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [source_key: :string, sample: :integer, seed: :integer, json: :boolean]
      )

    json? = Keyword.get(opts, :json, false)
    sample_n = Keyword.get(opts, :sample, 8000)
    seed = Keyword.get(opts, :seed, 1337)
    sk = Keyword.get(opts, :source_key)

    member_ids = member_ids(sk)
    nonmember_ids = nonmember_sample(member_ids, sample_n, seed)

    cov = coverage_map(member_ids ++ nonmember_ids)
    attrs = attr_map(member_ids ++ nonmember_ids)

    m_cov = Enum.map(member_ids, &Map.get(cov, &1, 0))
    n_cov = Enum.map(nonmember_ids, &Map.get(cov, &1, 0))

    result = %{
      scope: sk || "ALL_LISTS",
      n_members: length(member_ids),
      n_pool_sample: length(nonmember_ids),
      coverage_codes: @n_codes,
      member_cov_median: median(m_cov),
      member_cov_mean: mean(m_cov),
      pool_cov_median: median(n_cov),
      pool_cov_mean: mean(n_cov),
      pct_members_below_pool_median: pct_below(m_cov, median(n_cov)),
      coverage_auc: auc(m_cov, n_cov),
      member_pct_non_english: pct_non_english(member_ids, attrs),
      pool_pct_non_english: pct_non_english(nonmember_ids, attrs),
      member_median_decade: median_decade(member_ids, attrs),
      pool_median_decade: median_decade(nonmember_ids, attrs),
      member_cov_hist: hist(m_cov),
      pool_cov_hist: hist(n_cov)
    }

    verdict = verdict(result)

    if json? do
      IO.puts(Jason.encode!(Map.put(result, :verdict, verdict), pretty: true))
    else
      print(result, verdict)
    end
  end

  # ── data ──────────────────────────────────────────────────────────────────────────
  defp member_ids(nil) do
    Repo.all(
      from m in "movies",
        where: fragment("? <> '{}'::jsonb", m.canonical_sources),
        select: m.id
    )
  end

  defp member_ids(sk) do
    Repo.all(
      from m in "movies", where: fragment("? \\? ?", m.canonical_sources, ^sk), select: m.id
    )
  end

  # Deterministic pseudo-random pool sample of non-members (import_status full), seeded.
  defp nonmember_sample(member_ids, n, seed) do
    member_set = MapSet.new(member_ids)

    Repo.all(
      from m in "movies",
        where: m.import_status == "full",
        order_by: fragment("md5(? || ?::text)", m.id, ^to_string(seed)),
        select: m.id,
        limit: ^(n + length(member_ids))
    )
    |> Enum.reject(&MapSet.member?(member_set, &1))
    |> Enum.take(n)
  end

  # %{movie_id => count of @coverage_codes present with a non-null normalized_value}. Chunked.
  defp coverage_map(ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT movie_id, count(*)::int
          FROM metric_values_view
          WHERE movie_id = ANY($1) AND metric_code = ANY($2) AND normalized_value IS NOT NULL
          GROUP BY movie_id
          """,
          [chunk, @coverage_codes]
        )

      Enum.reduce(rows, acc, fn [id, c], a -> Map.put(a, id, c) end)
    end)
  end

  # %{movie_id => {original_language, release_year}}
  defp attr_map(ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      rows =
        Repo.all(
          from m in "movies",
            where: m.id in ^chunk,
            select:
              {m.id, m.original_language, fragment("EXTRACT(YEAR FROM ?)::int", m.release_date)}
        )

      Enum.reduce(rows, acc, fn {id, lang, year}, a -> Map.put(a, id, {lang, year}) end)
    end)
  end

  # ── stats ─────────────────────────────────────────────────────────────────────────
  # Mann-Whitney AUC with average-rank tie handling. P(member cov > pool cov) + 0.5·P(tie).
  # < 0.5 ⇒ members systematically LOWER coverage than pool (the inverted SAR confound).
  defp auc([], _), do: 0.5
  defp auc(_, []), do: 0.5

  defp auc(pos, neg) do
    np = length(pos)
    nn = length(neg)

    ranks =
      (Enum.map(pos, &{&1, :pos}) ++ Enum.map(neg, &{&1, :neg}))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {{v, _}, _} -> v end)
      |> Enum.flat_map(fn group ->
        positions = Enum.map(group, fn {_, pos} -> pos end)
        avg = Enum.sum(positions) / length(positions)
        Enum.map(group, fn {{_, label}, _} -> {avg, label} end)
      end)

    sum_pos = ranks |> Enum.filter(&(elem(&1, 1) == :pos)) |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    Float.round((sum_pos - np * (np + 1) / 2) / (np * nn), 4)
  end

  defp median([]), do: 0.0

  defp median(xs) do
    s = Enum.sort(xs)
    n = length(s)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(s, mid) * 1.0,
      else: (Enum.at(s, mid - 1) + Enum.at(s, mid)) / 2
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Float.round(Enum.sum(xs) / length(xs), 2)

  defp pct_below([], _), do: 0.0
  defp pct_below(xs, t), do: Float.round(100 * Enum.count(xs, &(&1 < t)) / length(xs), 1)

  defp pct_non_english(ids, attrs) do
    langs = Enum.map(ids, fn id -> attrs |> Map.get(id, {nil, nil}) |> elem(0) end)
    known = Enum.reject(langs, &is_nil/1)

    if known == [],
      do: 0.0,
      else: Float.round(100 * Enum.count(known, &(&1 != "en")) / length(known), 1)
  end

  defp median_decade(ids, attrs) do
    years =
      ids
      |> Enum.map(fn id -> attrs |> Map.get(id, {nil, nil}) |> elem(1) end)
      |> Enum.reject(&is_nil/1)

    if years == [], do: nil, else: trunc(median(years) / 10) * 10
  end

  defp hist(xs) do
    buckets = [{"0-2", 0..2}, {"3-5", 3..5}, {"6-8", 6..8}, {"9-11", 9..11}]
    n = max(length(xs), 1)

    Map.new(buckets, fn {label, range} ->
      {label, Float.round(100 * Enum.count(xs, &(&1 in range)) / n, 1)}
    end)
  end

  # ── verdict ─────────────────────────────────────────────────────────────────────────
  # DIRECTIONAL. Lever C (PU reweighting) only helps when positives look like the "negative-looking"
  # unlabeled set — i.e. members are UNDER-covered / MORE foreign than the pool, so a binary learner
  # mislabels them. Members being BETTER-covered/less-foreign is the *opposite*: coverage then helps
  # separate canon, and PU reweighting toward low-coverage positives would hurt, not help.
  defp verdict(r) do
    under_covered = r.coverage_auc <= 0.45
    cov_gap_neg = r.pool_cov_median - r.member_cov_median >= 2.0
    foreign_skew = r.member_pct_non_english - r.pool_pct_non_english >= 15.0
    over_covered = r.coverage_auc >= 0.65
    sar_signals = Enum.count([under_covered, cov_gap_neg, foreign_skew], & &1)

    cond do
      sar_signals >= 2 ->
        %{
          label: "SAR-STRONG",
          recommend: "Build Lever C (PU / coverage-aware reweighting)",
          why:
            "Members are systematically under-covered/foreign vs the pool (coverage AUC #{r.coverage_auc}) — " <>
              "an unlabeled-as-negative learner mislabels canon. PU reweighting targets exactly this."
        }

      over_covered ->
        %{
          label: "NOT-SAR (inverted)",
          recommend: "Skip Lever C → go to Lever E (text embeddings)",
          why:
            "Members are BETTER-covered (coverage AUC #{r.coverage_auc}) and less-foreign than the pool — " <>
              "the SAR coverage-confound runs the *opposite* way to Lever C's premise. Coverage already helps " <>
              "separate canon; the remaining difficulty (canon vs other well-documented films) is a *content* " <>
              "gap that embeddings (E) address, not a labeling-bias gap that PU fixes."
        }

      sar_signals == 1 ->
        %{
          label: "SAR-WEAK",
          recommend: "Lever C marginal — prefer Lever E, or a per-archetype C spike",
          why:
            "Only one SAR signal fired; the confound is modest and direction-dependent. Limited PU upside."
        }

      true ->
        %{
          label: "SCAR-ISH",
          recommend: "Skip Lever C → go to Lever E (text embeddings)",
          why:
            "Coverage/era/language don't bias membership in C's direction (coverage AUC #{r.coverage_auc}) — " <>
              "#1055's era-stratified negatives already banked any SAR correction. PU reweighting won't move it."
        }
    end
  end

  defp print(r, v) do
    sh = fn msg -> Mix.shell().info(msg) end
    sh.("\nPU / SAR diagnostic — #{r.scope}")
    sh.(String.duplicate("=", 64))

    sh.(
      "members: #{r.n_members}   pool sample: #{r.n_pool_sample}   coverage surface: #{r.coverage_codes} objective metrics\n"
    )

    sh.("COVERAGE (objective-metric presence, 0..#{r.coverage_codes}):")
    sh.("  members  median #{r.member_cov_median}  mean #{r.member_cov_mean}")
    sh.("  pool     median #{r.pool_cov_median}  mean #{r.pool_cov_mean}")
    sh.("  #{r.pct_members_below_pool_median}% of members are BELOW the pool's median coverage")

    sh.(
      "  coverage→membership AUC = #{r.coverage_auc}  (<0.5 ⇒ members under-covered = SAR confound)\n"
    )

    sh.("coverage histogram (% of group):")
    sh.("  bucket    members   pool")

    for b <- ["0-2", "3-5", "6-8", "9-11"] do
      sh.(
        "  #{String.pad_trailing(b, 8)}  #{pad(r.member_cov_hist[b])}   #{pad(r.pool_cov_hist[b])}"
      )
    end

    sh.("")
    sh.("LANGUAGE / ERA:")
    sh.("  non-English:  members #{r.member_pct_non_english}%   pool #{r.pool_pct_non_english}%")
    sh.("  median decade: members #{r.member_median_decade}s   pool #{r.pool_median_decade}s\n")

    sh.("VERDICT: #{v.label}")
    sh.("  → #{v.recommend}")
    sh.("  #{v.why}\n")
  end

  defp pad(x), do: "#{x}%" |> String.pad_leading(7)
end
