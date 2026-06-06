defmodule Mix.Tasks.Predictions.EmbedSpike do
  @moduledoc """
  Real-embedding spike for Lever E (#1070) — the semantic upgrade of `predictions.text_spike`.

  Same hard task (canon vs non-canon **matched on decade × coverage**, so only the plot text can
  separate them) and same nearest-centroid-cosine k-fold AUC — but features are **real sentence
  embeddings** (`Cinegraph.Embeddings`, all-MiniLM-L6-v2) instead of TF-IDF bag-of-words. This
  confirms whether semantic embeddings clear (and by how much) the BoW lower bound (~0.65 pooled)
  before committing to the full pgvector + catalog-wide build.

  Measurement only — no production training, no holdout, no DB writes. First run downloads the model.

  ## Usage
      mix predictions.embed_spike                          # pooled
      mix predictions.embed_spike --source-key criterion
      mix predictions.embed_spike --limit 2500 --folds 5 --json
  """
  use Mix.Task
  import Ecto.Query

  alias Cinegraph.{Embeddings, Repo}

  @shortdoc "Real-embedding spike for Lever E — semantic upgrade of text_spike (#1070)"

  @coverage_codes ~w(imdb_rating tmdb_rating metacritic_metascore rotten_tomatoes_tomatometer
                     rotten_tomatoes_audience_score imdb_rating_votes tmdb_rating_votes
                     tmdb_popularity_score tmdb_budget tmdb_revenue_worldwide runtime)
  @chunk 1500

  @impl Mix.Task
  def run(args) do
    Cinegraph.Predictions.TaskSupport.start_lean()
    Logger.configure(level: :warning)

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          source_key: :string,
          limit: :integer,
          folds: :integer,
          seed: :integer,
          head: :string,
          json: :boolean
        ]
      )

    json? = Keyword.get(opts, :json, false)
    limit = Keyword.get(opts, :limit, 2500)
    folds = Keyword.get(opts, :folds, 5)
    seed = Keyword.get(opts, :seed, 1337)
    head = Keyword.get(opts, :head, "centroid")
    sk = Keyword.get(opts, :source_key)
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    members = load_docs(member_ids(sk)) |> cap(limit)

    negs =
      match_negatives(
        members,
        load_docs(nonmember_sample(Enum.map(members, & &1.id), 25_000, seed))
      )

    pos = Enum.map(members, &Map.put(&1, :label, 1))
    neg = Enum.map(negs, &Map.put(&1, :label, 0))
    all = pos ++ neg

    unless json?,
      do: Mix.shell().info("embedding #{length(all)} overviews via #{Embeddings.model()} …")

    vecs = Embeddings.embed(Enum.map(all, & &1.overview))
    docs = Enum.zip_with(all, vecs, fn d, v -> %{label: d.label, vec: v} end)

    aucs = cross_val_auc(docs, folds, head)
    mean_auc = Float.round(Enum.sum(aucs) / length(aucs), 4)

    result = %{
      scope: sk || "ALL_LISTS",
      model: Embeddings.model(),
      head: head,
      n_pos: length(pos),
      n_neg: length(neg),
      folds: folds,
      fold_aucs: Enum.map(aucs, &Float.round(&1, 4)),
      embed_auc: mean_auc,
      verdict: verdict(mean_auc)
    }

    if json?, do: IO.puts(Jason.encode!(result, pretty: true)), else: print(result)
  end

  defp cap(list, n), do: Enum.take(Enum.shuffle(list), n)

  # ── data (mirrors predictions.text_spike) ────────────────────────────────────────────
  defp member_ids(nil),
    do:
      Repo.all(
        from m in "movies",
          where: fragment("? <> '{}'::jsonb", m.canonical_sources) and not is_nil(m.overview),
          select: m.id
      )

  defp member_ids(sk),
    do:
      Repo.all(
        from m in "movies",
          where: fragment("? \\? ?", m.canonical_sources, ^sk) and not is_nil(m.overview),
          select: m.id
      )

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
      %{
        id: id,
        overview: ov || "",
        decade: decade(year),
        covb: div(min(Map.get(cov, id, 0), 11), 3)
      }
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

  defp match_negatives(members, neg_pool) do
    neg_by = Enum.group_by(neg_pool, &{&1.decade, &1.covb})

    {matched, _} =
      members
      |> Enum.group_by(&{&1.decade, &1.covb})
      |> Enum.reduce({[], neg_by}, fn {stratum, ms}, {acc, pool} ->
        avail = Map.get(pool, stratum, [])

        {acc ++ Enum.take(avail, length(ms)),
         Map.put(pool, stratum, Enum.drop(avail, length(ms)))}
      end)

    matched
  end

  # ── k-fold AUC, scorer = centroid-cosine or logistic head ────────────────────────────
  defp cross_val_auc(docs, folds, head) do
    chunks = docs |> Enum.shuffle() |> chunk_into(folds)

    Enum.map(0..(folds - 1), fn i ->
      test = Enum.at(chunks, i)
      train = chunks |> List.delete_at(i) |> List.flatten()
      auc(score_fold(head, train, test))
    end)
  end

  # → [{score, label}] for the test fold.
  defp score_fold("logistic", train, test) do
    x = Nx.tensor(Enum.map(train, & &1.vec), type: :f32)
    y = Nx.tensor(Enum.map(train, & &1.label), type: :u32)

    model =
      Scholar.Linear.LogisticRegression.fit(x, y,
        num_classes: 2,
        max_iterations: 1000,
        alpha: 1.0
      )

    tx = Nx.tensor(Enum.map(test, & &1.vec), type: :f32)
    probs = Scholar.Linear.LogisticRegression.predict_probability(model, tx)
    scores = probs[[.., 1]] |> Nx.to_list()
    Enum.zip(scores, Enum.map(test, & &1.label))
  end

  defp score_fold(_centroid, train, test) do
    {pc, nc} = {centroid(train, 1), centroid(train, 0)}
    Enum.map(test, fn d -> {dot(d.vec, pc) - dot(d.vec, nc), d.label} end)
  end

  # L2-normalized mean of the class's (already unit) embedding vectors.
  defp centroid(docs, label) do
    vecs = for d <- docs, d.label == label, do: d.vec

    # A label-empty fold (tiny --limit / extreme imbalance) would make hd/1 raise cryptically.
    if vecs == [],
      do: raise("no samples for label #{label} in this fold — increase --limit or check the data")

    dim = length(hd(vecs))

    sum =
      Enum.reduce(vecs, List.duplicate(0.0, dim), fn v, acc -> Enum.zip_with(v, acc, &+/2) end)

    mean = Enum.map(sum, &(&1 / length(vecs)))
    norm = :math.sqrt(Enum.reduce(mean, 0.0, fn x, s -> s + x * x end))
    if norm == 0.0, do: mean, else: Enum.map(mean, &(&1 / norm))
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, s -> s + x * y end)

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
      auc >= 0.70 ->
        %{
          label: "STRONG",
          recommend: "Build full Lever E (catalog-wide embeddings as a feature group)",
          why:
            "Semantic embeddings clearly separate canon from coverage/era-matched non-canon (AUC #{auc}) — the content channel carries real signal. Proceed to pgvector + matrix A/B."
        }

      auc >= 0.62 ->
        %{
          label: "GREEN",
          recommend: "Build full Lever E",
          why:
            "Embeddings beat the BoW lower bound (AUC #{auc}). Content signal confirmed; proceed to the catalog-wide build + matrix A/B."
        }

      true ->
        %{
          label: "WEAK",
          recommend: "Reconsider — embeddings underperformed the BoW lower bound",
          why:
            "Real embeddings did not clearly exceed the BoW baseline (AUC #{auc}); investigate (pooling/model) before the full build."
        }
    end
  end

  defp print(r) do
    sh = fn m -> Mix.shell().info(m) end
    sh.("\nReal-embedding spike — #{r.scope}  (Lever E)")
    sh.(String.duplicate("=", 64))

    sh.(
      "model: #{r.model}   docs: #{r.n_pos} canon / #{r.n_neg} matched non-canon   #{r.folds}-fold"
    )

    sh.("task: canon vs (decade × coverage)-MATCHED non-canon — only TEXT can separate\n")
    sh.("nearest-centroid cosine AUC on real sentence embeddings:")
    sh.("  per-fold: #{inspect(r.fold_aucs)}")
    sh.("  mean AUC = #{r.embed_auc}   (BoW lower bound was ~0.65 pooled)\n")
    sh.("VERDICT: #{r.verdict.label}")
    sh.("  → #{r.verdict.recommend}")
    sh.("  #{r.verdict.why}\n")
  end
end
