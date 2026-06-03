defmodule Cinegraph.Scoring.DataPointFeatures do
  @moduledoc """
  Per-movie normalized data-point vectors, read from `metric_values_view` (#1036 Session 3).

  This is the data-point (Layer-0 `metric_code`) feature source for the weighting bus and
  for `:data_point`-granularity model training — the fine-grained counterpart to the 6 lens
  features. Each value is the catalog-normalized `normalized_value` (0..1); a code with no
  row for a movie is treated as absent (caller imputes 0).

  Filtering by `movie_id` pushes down to the indexed base tables, so a batched load over a
  decade is cheap (unlike an unfiltered full-view scan).
  """

  alias Cinegraph.Repo
  alias Cinegraph.Scoring.DerivedFeatures

  # A full decade can be tens of thousands of movies; chunk the id list so the view query
  # (filtered by movie_id, pushed down to the base tables) stays well under the pool timeout.
  @chunk 1500
  @timeout :timer.seconds(60)

  @doc """
  Assemble the full feature map for `movies` over `codes` under target list `source_key` (#1040):
  raw codes come from `metric_values_view` (`load/2`), derived codes from `DerivedFeatures` (which
  reuses `FeatureResolver`, leakage-stripped). Returns `%{movie_id => %{code => value}}`.

  This is the **single shared assembly** used by BOTH `Trainer.fit_weights(:data_point)` and
  `Bus.score(:data_point)`, so a movie's feature vector is identical at train time and inference
  time (the train/serve symmetry invariant). Takes movie **structs** (not ids) because the derived
  features need `canonical_sources` / `tmdb_data` / `release_date`.
  """
  def load_for(movies, codes, source_key) do
    {derived_codes, raw_codes} =
      Enum.split_with(codes, &(&1 in DerivedFeatures.supported_codes()))

    raw = load(Enum.map(movies, & &1.id), raw_codes)
    derived = DerivedFeatures.load(movies, derived_codes, source_key)

    Map.new(movies, fn m ->
      {m.id, Map.merge(Map.get(raw, m.id, %{}), Map.get(derived, m.id, %{}))}
    end)
  end

  @doc """
  Load `%{movie_id => %{code => normalized_value}}` for the given movies and codes.
  Only rows with a non-null `normalized_value` are returned. Batched over `movie_ids`.
  """
  def load([], _codes), do: %{}
  def load(_movie_ids, []), do: %{}

  def load(movie_ids, codes) do
    movie_ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn ids, acc ->
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT movie_id, metric_code, normalized_value
          FROM metric_values_view
          WHERE movie_id = ANY($1) AND metric_code = ANY($2)
            AND normalized_value IS NOT NULL
          """,
          [ids, codes],
          timeout: @timeout
        )

      Enum.reduce(rows, acc, fn [movie_id, code, value], a ->
        Map.update(a, movie_id, %{code => value}, &Map.put(&1, code, value))
      end)
    end)
  end

  @doc """
  Build a dense feature matrix for `movie_ids` over `codes` (column order = `codes`).
  Returns `{matrix, present_counts}` where `matrix` is a list of float lists (missing ⇒ 0.0)
  aligned to `movie_ids`, and `present_counts` maps each code to how many movies had it
  (for honest coverage reporting). Pure data — no labels.
  """
  def matrix(movie_ids, codes) do
    feats = load(movie_ids, codes)

    matrix =
      Enum.map(movie_ids, fn id ->
        vec = Map.get(feats, id, %{})
        Enum.map(codes, fn code -> vec[code] || 0.0 end)
      end)

    present =
      Enum.reduce(feats, Map.new(codes, &{&1, 0}), fn {_id, vec}, acc ->
        Enum.reduce(Map.keys(vec), acc, fn code, a -> Map.update(a, code, 1, &(&1 + 1)) end)
      end)

    {matrix, present}
  end
end
