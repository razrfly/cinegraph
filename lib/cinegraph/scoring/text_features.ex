defmodule Cinegraph.Scoring.TextFeatures do
  @moduledoc """
  Plot-overview text features for Lever E (#1070) — the cheap content channel (no embeddings).

  The `predictions.{text,embed}_spike` results showed plot text separates canon from coverage/era-
  matched non-canon (~0.65 AUC) and that MiniLM embeddings do **not** beat TF-IDF — so the content
  channel ships as bag-of-words.

  **Representation: the hashing trick with IDF.** Every content token in an overview is hashed into one
  of `@dim` buckets and accumulated with its IDF weight, then the bucket vector is L2-normalized and
  emitted as data-point codes `txt_000..txt_(@dim-1)`. Hashing (vs a top-K vocabulary) keeps the whole
  content vocabulary — distinctive words like "samurai"/"heist" land in *some* bucket instead of being
  truncated away — at the cost of collisions the per-bucket learned weights absorb.

  IDF is precomputed once over the corpus (`mix predictions.build_text_vocab` →
  `priv/scoring/text_idf.json`, term→idf for terms within a min/max document-frequency band) so the
  feature is **stable across train and serve**. Memoized in `:persistent_term`. Tokens absent from the
  IDF map (too rare / too common) are dropped. A movie with no usable token emits nothing (0.0
  downstream). Codes are gated `is_available: false` until `mix predictions.eval_features` admits them.
  """

  @dim 512
  @priv_path "scoring/text_idf.json"

  @stop ~w(the a an and or of to in is it for on with as at by from this that be are was were
           his her its their he she they we you i but not no all out up so if into about after
           who whom which when while them then than too very can will just one two three
           film movie story life young man woman world new old time first find must back has him
           have what only where between who his hers our your)

  @doc "The fixed feature codes this module emits (`txt_000`..`txt_511`)."
  def codes, do: for(i <- 0..(@dim - 1), do: code(i))

  @doc "Code name for hash bucket `i`."
  def code(i), do: "txt_" <> String.pad_leading(Integer.to_string(i), 3, "0")

  @doc "Feature dimension (number of hash buckets)."
  def dim, do: @dim

  @doc "Whether the IDF artifact has been built."
  def built?, do: idf_map() != nil

  @doc """
  Vectorize one overview → `%{code => value}` (non-zero buckets only; L2-normalized IDF-weighted
  hashed bag-of-words). `%{}` if the IDF map isn't built or the text has no usable tokens.
  """
  def vectorize(text) when is_binary(text) do
    case idf_map() do
      nil ->
        %{}

      idf ->
        buckets =
          text
          |> tokenize()
          |> Enum.reduce(%{}, fn t, acc ->
            case Map.get(idf, t) do
              nil -> acc
              w -> Map.update(acc, :erlang.phash2(t, @dim), w, &(&1 + w))
            end
          end)

        norm =
          buckets |> Map.values() |> Enum.reduce(0.0, fn w, s -> s + w * w end) |> :math.sqrt()

        if norm == +0.0,
          do: %{},
          else: Map.new(buckets, fn {b, w} -> {code(b), w / norm} end)
    end
  end

  def vectorize(_), do: %{}

  # ── IDF map load (memoized) ──────────────────────────────────────────────────────────
  @key {__MODULE__, :idf}

  @doc "Loaded `%{term => idf}` or nil if not built."
  def idf_map do
    case :persistent_term.get(@key, :unloaded) do
      :unloaded ->
        v = load_idf()
        :persistent_term.put(@key, v)
        v

      v ->
        v
    end
  end

  defp candidate_paths do
    [
      Path.join([File.cwd!(), "priv", @priv_path]),
      Path.join(:code.priv_dir(:cinegraph), @priv_path)
    ]
  end

  defp load_idf do
    path = Enum.find(candidate_paths(), &File.exists?/1)

    with p when is_binary(p) <- path,
         {:ok, body} <- File.read(p),
         {:ok, %{"idf" => idf}} <- Jason.decode(body) do
      idf
    else
      _ -> nil
    end
  end

  @doc "Clear the memoized IDF (call after rebuilding)."
  def reload, do: :persistent_term.erase(@key)

  # ── tokenization ─────────────────────────────────────────────────────────────────────
  @doc false
  def tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stop))
  end

  # ── build (one-time precompute) ──────────────────────────────────────────────────────
  @doc """
  Build the IDF map from a corpus of overviews → `priv/scoring/text_idf.json`. Keeps terms with
  document frequency in `[min_df, max_df_frac·N]` (drop ultra-rare noise + ubiquitous words), IDF
  `log((N+1)/(df+1)) + 1`. Returns `{path, n_terms}`.
  """
  def build_vocab(corpus, opts \\ []) do
    min_df = Keyword.get(opts, :min_df, 5)
    max_df_frac = Keyword.get(opts, :max_df_frac, 0.4)
    n = length(corpus)
    max_df = max_df_frac * n

    df =
      Enum.reduce(corpus, %{}, fn text, acc ->
        text
        |> tokenize()
        |> Enum.uniq()
        |> Enum.reduce(acc, fn t, a -> Map.update(a, t, 1, &(&1 + 1)) end)
      end)

    idf =
      df
      |> Enum.filter(fn {_t, d} -> d >= min_df and d <= max_df end)
      |> Map.new(fn {t, d} -> {t, Float.round(:math.log((n + 1) / (d + 1)) + 1.0, 6)} end)

    path = Path.join([File.cwd!(), "priv", @priv_path])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"dim" => @dim, "n_docs" => n, "idf" => idf}))
    reload()
    {path, map_size(idf)}
  end
end
