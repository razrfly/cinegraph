defmodule Mix.Tasks.Predictions.TextSpike do
  @moduledoc """
  Text-signal feasibility spike for Lever E / text embeddings (#1070).

  **Question the PU diagnostic left us with:** the model already separates canon from the obscure
  long-tail via coverage; the *hard* part is **canon vs other well-documented, similar-era films**,
  which look identical on metrics. Does the **plot text** separate that hard pair? If yes → real
  embeddings (Lever E) are worth building; if even crude text can't, embeddings are a riskier bet.

  **Method (a conservative lower bound on real embeddings):** TF-IDF of `movies.overview` +
  nearest-centroid cosine, k-fold. Negatives are **matched to members on (decade × coverage-bucket)**,
  so coverage/era — which we *know* already separate canon — are neutralized and **only the text can
  carry signal**. This is bag-of-words: it ignores synonymy, paraphrase, and cross-lingual meaning that
  semantic embeddings capture, so **real embeddings would do at least as well.** A positive here is a
  green light; a null here is weaker evidence (embeddings might still help).

  Pure measurement — no training of the production model, no holdout, no DB writes.

  ## Usage
      mix predictions.text_spike                       # pooled canon members
      mix predictions.text_spike --source-key criterion
      mix predictions.text_spike --vocab 4000 --folds 5 --json
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.Repo

  @shortdoc "Text-signal feasibility spike for Lever E (embeddings) (#1070)"

  @coverage_codes ~w(imdb_rating tmdb_rating metacritic_metascore rotten_tomatoes_tomatometer
                     rotten_tomatoes_audience_score imdb_rating_votes tmdb_rating_votes
                     tmdb_popularity_score tmdb_budget tmdb_revenue_worldwide runtime)
  @chunk 1500
  @stop ~w(the a an and or of to in is it for on with as at by from this that be are was were
           his her its their he she they we you i but not no all out up so if into about after
           who whom which when while their them then than too very can will just one two
           film movie story life young man woman world)

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          source_key: :string,
          vocab: :integer,
          folds: :integer,
          seed: :integer,
          json: :boolean
        ]
      )

    json? = Keyword.get(opts, :json, false)
    vocab_k = Keyword.get(opts, :vocab, 3000)
    folds = Keyword.get(opts, :folds, 5)
    seed = Keyword.get(opts, :seed, 1337)
    sk = Keyword.get(opts, :source_key)
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    members = load_docs(member_ids(sk))
    neg_pool = load_docs(nonmember_sample(Enum.map(members, & &1.id), 25_000, seed))

    matched_negs = match_negatives(members, neg_pool)

    pos = Enum.map(members, &Map.put(&1, :label, 1))
    neg = Enum.map(matched_negs, &Map.put(&1, :label, 0))
    docs = tfidf(pos ++ neg, vocab_k)

    aucs = cross_val_auc(docs, folds)
    mean_auc = Float.round(Enum.sum(aucs) / length(aucs), 4)

    result = %{
      scope: sk || "ALL_LISTS",
      n_pos: length(pos),
      n_neg: length(neg),
      vocab: vocab_k,
      folds: folds,
      fold_aucs: Enum.map(aucs, &Float.round(&1, 4)),
      text_auc: mean_auc,
      verdict: verdict(mean_auc)
    }

    if json?, do: IO.puts(Jason.encode!(result, pretty: true)), else: print(result)
  end

  # ── data ───────────────────────────────────────────────────────────────────────────
  defp member_ids(nil) do
    Repo.all(
      from m in "movies",
        where: fragment("? <> '{}'::jsonb", m.canonical_sources) and not is_nil(m.overview),
        select: m.id
    )
  end

  defp member_ids(sk) do
    Repo.all(
      from m in "movies",
        where: fragment("? \\? ?", m.canonical_sources, ^sk) and not is_nil(m.overview),
        select: m.id
    )
  end

  defp nonmember_sample(member_ids, n, seed) do
    member_set = MapSet.new(member_ids)

    Repo.all(
      from m in "movies",
        where:
          m.import_status == "full" and m.canonical_sources == fragment("'{}'::jsonb") and
            not is_nil(m.overview),
        order_by: fragment("md5(? || ?::text)", m.id, ^to_string(seed)),
        select: m.id,
        limit: ^(n + length(member_ids))
    )
    |> Enum.reject(&MapSet.member?(member_set, &1))
    |> Enum.take(n)
  end

  # %{id, overview, decade, covb} for the given ids (overview + decade in one query; coverage joined).
  defp load_docs(ids) do
    cov = coverage_map(ids)

    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from m in "movies",
          where: m.id in ^chunk,
          select: {m.id, m.overview, fragment("EXTRACT(YEAR FROM ?)::int", m.release_date)}
      )
    end)
    |> Enum.map(fn {id, ov, year} ->
      c = Map.get(cov, id, 0)
      %{id: id, overview: ov || "", decade: decade(year), covb: div(min(c, 11), 3)}
    end)
  end

  defp coverage_map(ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT movie_id, count(*)::int FROM metric_values_view WHERE movie_id = ANY($1) AND metric_code = ANY($2) AND normalized_value IS NOT NULL GROUP BY movie_id",
          [chunk, @coverage_codes]
        )

      Enum.reduce(rows, acc, fn [id, c], a -> Map.put(a, id, c) end)
    end)
  end

  defp decade(nil), do: 0
  defp decade(y), do: div(y, 10) * 10

  # Draw, per (decade × coverage-bucket) stratum, as many negatives as members in that stratum, so the
  # matched negative set has the members' joint coverage/era distribution → only text can separate.
  defp match_negatives(members, neg_pool) do
    neg_by = Enum.group_by(neg_pool, &{&1.decade, &1.covb})

    {matched, _} =
      members
      |> Enum.group_by(&{&1.decade, &1.covb})
      |> Enum.reduce({[], neg_by}, fn {stratum, ms}, {acc, pool} ->
        avail = Map.get(pool, stratum, [])
        take = Enum.take(avail, length(ms))
        {acc ++ take, Map.put(pool, stratum, Enum.drop(avail, length(ms)))}
      end)

    matched
  end

  # ── TF-IDF (sparse maps) ─────────────────────────────────────────────────────────────
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stop))
  end

  # → [%{label, terms: %{term => tfidf}, norm}] with vocab = top-K terms by document frequency.
  defp tfidf(docs, vocab_k) do
    toks = Enum.map(docs, fn d -> {d.label, tokenize(d.overview)} end)
    n = length(toks)

    df =
      Enum.reduce(toks, %{}, fn {_l, ts}, acc ->
        Enum.reduce(Enum.uniq(ts), acc, fn t, a -> Map.update(a, t, 1, &(&1 + 1)) end)
      end)

    vocab =
      df |> Enum.sort_by(fn {_t, c} -> -c end) |> Enum.take(vocab_k) |> Map.new()

    idf = Map.new(vocab, fn {t, d} -> {t, :math.log((n + 1) / (d + 1)) + 1.0} end)

    Enum.map(toks, fn {label, ts} ->
      tf =
        Enum.reduce(ts, %{}, fn t, a ->
          if(Map.has_key?(vocab, t), do: Map.update(a, t, 1, &(&1 + 1)), else: a)
        end)

      vec = Map.new(tf, fn {t, c} -> {t, (1.0 + :math.log(c)) * idf[t]} end)
      norm = vec |> Map.values() |> Enum.reduce(0.0, fn w, s -> s + w * w end) |> :math.sqrt()
      %{label: label, terms: vec, norm: norm}
    end)
  end

  # ── nearest-centroid cosine, k-fold AUC ──────────────────────────────────────────────
  defp cross_val_auc(docs, folds) do
    shuffled = Enum.shuffle(docs)
    chunks = chunk_into(shuffled, folds)

    Enum.map(0..(folds - 1), fn i ->
      test = Enum.at(chunks, i)
      train = chunks |> List.delete_at(i) |> List.flatten()
      {pc, nc} = centroids(train)
      scored = Enum.map(test, fn d -> {cos(d, pc) - cos(d, nc), d.label} end)
      auc(scored)
    end)
  end

  defp centroids(train) do
    {pos, neg} = Enum.split_with(train, &(&1.label == 1))
    {centroid(pos), centroid(neg)}
  end

  # Mean of L2-normalized doc vectors, then L2-normalized → a unit-ish centroid map.
  defp centroid(docs) do
    sum =
      Enum.reduce(docs, %{}, fn d, acc ->
        if d.norm == 0.0 do
          acc
        else
          Enum.reduce(d.terms, acc, fn {t, w}, a ->
            Map.update(a, t, w / d.norm, &(&1 + w / d.norm))
          end)
        end
      end)

    k = max(length(docs), 1)
    mean = Map.new(sum, fn {t, w} -> {t, w / k} end)
    norm = mean |> Map.values() |> Enum.reduce(0.0, fn w, s -> s + w * w end) |> :math.sqrt()
    %{terms: mean, norm: norm}
  end

  defp cos(_doc, %{norm: +0.0}), do: 0.0
  defp cos(%{norm: +0.0}, _c), do: 0.0

  defp cos(doc, c) do
    dot = Enum.reduce(doc.terms, 0.0, fn {t, w}, s -> s + w * Map.get(c.terms, t, 0.0) end)
    dot / (doc.norm * c.norm)
  end

  # Mann-Whitney AUC, tie-aware. scored = [{score, label}]
  defp auc(scored) do
    pos = for {s, 1} <- scored, do: s
    neg = for {s, 0} <- scored, do: s
    np = length(pos)
    nn = length(neg)
    if np == 0 or nn == 0, do: 0.5, else: do_auc(pos, neg, np, nn)
  end

  defp do_auc(pos, neg, np, nn) do
    ranks =
      (Enum.map(pos, &{&1, :p}) ++ Enum.map(neg, &{&1, :n}))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {{v, _}, _} -> v end)
      |> Enum.flat_map(fn g ->
        ps = Enum.map(g, fn {_, p} -> p end)
        avg = Enum.sum(ps) / length(ps)
        Enum.map(g, fn {{_, l}, _} -> {avg, l} end)
      end)

    sum_pos = ranks |> Enum.filter(&(elem(&1, 1) == :p)) |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    (sum_pos - np * (np + 1) / 2) / (np * nn)
  end

  defp chunk_into(list, k) do
    list
    |> Enum.with_index()
    |> Enum.group_by(fn {_x, i} -> rem(i, k) end, fn {x, _i} -> x end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp verdict(auc) do
    cond do
      auc >= 0.65 ->
        %{
          label: "GREEN",
          recommend: "Build Lever E (text embeddings)",
          why:
            "Even crude bag-of-words separates canon from coverage/era-matched non-canon (AUC #{auc}) — real semantic embeddings will do at least as well. The content channel carries the signal metrics can't."
        }

      auc >= 0.57 ->
        %{
          label: "AMBER",
          recommend:
            "Lever E is promising — build a small real-embedding spike before full commit",
          why:
            "Bag-of-words shows moderate separation (AUC #{auc}); since BoW is a lower bound, semantic embeddings likely clear the bar — but confirm with a real-embedding spike (Bumblebee/API) before the full pgvector build."
        }

      true ->
        %{
          label: "RED",
          recommend: "Lever E is uncertain — don't commit on this evidence",
          why:
            "Crude text barely separates the matched pair (AUC #{auc}). Embeddings *might* still help (BoW misses semantics), but the cheap signal is weak — consider a real-embedding spike or accept a near-fundamental metadata ceiling and pivot to honest per-archetype labeling."
        }
    end
  end

  defp print(r) do
    sh = fn m -> Mix.shell().info(m) end
    sh.("\nText-signal feasibility spike — #{r.scope}  (Lever E de-risk)")
    sh.(String.duplicate("=", 64))
    sh.("task: canon vs (decade × coverage)-MATCHED non-canon — only TEXT can separate")

    sh.(
      "docs: #{r.n_pos} canon / #{r.n_neg} matched non-canon   vocab #{r.vocab}   #{r.folds}-fold\n"
    )

    sh.("TF-IDF + nearest-centroid cosine AUC (bag-of-words = lower bound on real embeddings):")
    sh.("  per-fold: #{inspect(r.fold_aucs)}")
    sh.("  mean AUC = #{r.text_auc}\n")
    sh.("VERDICT: #{r.verdict.label}")
    sh.("  → #{r.verdict.recommend}")
    sh.("  #{r.verdict.why}\n")
  end
end
