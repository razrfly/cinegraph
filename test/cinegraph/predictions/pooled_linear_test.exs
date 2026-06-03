defmodule Cinegraph.Predictions.PooledLinearTest do
  @moduledoc """
  The pooled-linear proof class (#1061 Session 2): the load-bearing **rank-identity** proof (the
  projected per-target weight map ranks movies identically to the full pooled model with the
  target one-hot fixed), the objective-only honesty guard, weight-map serving through `Bus`, and
  the run_matrix integration recording pooled rows.
  """
  use Cinegraph.DataCase
  import Ecto.Query

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Predictions.{ExperimentLedger, PooledLinear, Trainer}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{Bus, DataPointFeatures}

  @list_a "pooled_list_a"
  @list_b "pooled_list_b"

  setup do
    CatalogSeed.seed!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("movie_lists", [list_row(@list_a, now), list_row(@list_b, now)])

    # Three decades, members for BOTH lists + non-members, so pooled has multi-list positives and
    # the temporal split is valid.
    for {decade, na, nb, others} <- [{1980, 6, 5, 18}, {1990, 6, 5, 18}, {2000, 8, 6, 22}] do
      for i <- 1..na, do: plant(decade, {:a, i}, [@list_a])
      for i <- 1..nb, do: plant(decade, {:b, i}, [@list_b])
      for i <- 1..others, do: plant(decade, {:o, i}, [])
    end

    :ok
  end

  defp list_row(key, now) do
    %{
      name: key,
      source_key: key,
      source_type: "imdb",
      source_url: "https://example.com/#{key}",
      category: "test",
      slug: key,
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end

  defp plant(decade, tag, lists) do
    canonical = Map.new(lists, &{&1, true})
    member? = lists != []

    movie =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "#{decade} #{inspect(tag)}",
        release_date: Date.new!(decade + rem(elem(tag, 1), 9), 6, 1),
        import_status: "full",
        canonical_sources: canonical
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    imdb = if member?, do: 8.5, else: 5.5
    pop = if member?, do: 30.0, else: 50.0

    Repo.insert_all("external_metrics", [
      ext(movie.id, "imdb", "rating_average", imdb, now),
      ext(movie.id, "tmdb", "popularity_score", pop, now),
      ext(movie.id, "tmdb", "rating_votes", 1500.0, now)
    ])

    movie
  end

  defp ext(movie_id, source, metric_type, value, now) do
    %{
      movie_id: movie_id,
      source: source,
      metric_type: metric_type,
      value: value,
      fetched_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  describe "fit_pooled/2" do
    test "projects an objective-only weight map (no one-hot, no canon-overlap codes)" do
      assert {:ok, %{projected: by_list, codes: codes}} =
               PooledLinear.fit_pooled([@list_a, @list_b], seed: 7)

      proj = by_list[@list_a]
      assert is_map(proj) and map_size(proj) > 0
      # objective surface only — no list one-hot leaked, no canon-overlap derived.
      refute Enum.any?(Map.keys(proj), &String.starts_with?(&1, "__list:"))
      refute "canonical_contribution" in Map.keys(proj)
      refute @list_b in Map.keys(proj)
      # the projected map's codes are exactly the shared objective set.
      assert MapSet.new(Map.keys(proj)) == MapSet.new(codes)
    end

    test "RANK-IDENTITY: projected map ranks identically to the full model with target one-hot fixed" do
      assert {:ok, %{projected: by_list, full: full, codes: codes}} =
               PooledLinear.fit_pooled([@list_a, @list_b], seed: 7)

      proj = by_list[@list_a]
      onehot_w = full["__list:" <> @list_a]
      assert is_number(onehot_w)

      movies = Repo.all(from m in Movie, select: %Movie{id: m.id, title: m.title}, limit: 30)
      feats = DataPointFeatures.load_for(movies, codes, @list_a)

      dot = fn w, m ->
        Enum.reduce(codes, 0.0, fn c, a ->
          a + (w[c] || 0.0) * (get_in(feats, [m.id, c]) || 0.0)
        end)
      end

      # full score = projected score + the (constant) per-list one-hot bias → same ranking.
      full_rank =
        movies |> Enum.sort_by(fn m -> dot.(full, m) + onehot_w end) |> Enum.map(& &1.id)

      proj_rank = movies |> Enum.sort_by(fn m -> dot.(proj, m) end) |> Enum.map(& &1.id)

      assert full_rank == proj_rank
    end

    test "the projected map serves through Bus with no new code" do
      assert {:ok, %{projected: by_list}} = PooledLinear.fit_pooled([@list_a], seed: 7)
      movies = Repo.all(from m in Movie, select: %Movie{id: m.id, title: m.title}, limit: 10)

      scores = Bus.score(movies, {:data_point, by_list[@list_a], @list_a})
      assert map_size(scores) == length(movies)
      assert Enum.all?(Map.values(scores), &(&1 >= 0.0 and &1 <= 100.0))
    end
  end

  describe "behaviour contract" do
    test "per-cell fit/4 fails loudly (pooled trains via fit_pooled)" do
      assert {:error, :pooled_requires_fit_pooled} = PooledLinear.fit([[1.0]], [1], ["x"], [])
    end

    test "score/3 returns the Bus data_point spec" do
      assert PooledLinear.score(%{"imdb_rating" => 0.5}, :data_point, @list_a) ==
               {:data_point, %{"imdb_rating" => 0.5}, @list_a}
    end
  end

  describe "run_matrix pooled routing" do
    test "records pooled_linear rows via the fit-once/project-many path" do
      rows =
        Trainer.run_matrix(
          lists: [@list_a, @list_b],
          classes: ["pooled_linear"],
          max_concurrency: 2
        )

      assert rows != []
      assert Enum.all?(rows, &(&1.model_class == "pooled_linear"))
      assert Enum.all?(rows, &(&1.feature_bucket == "objective_only"))

      persisted =
        Repo.all(
          from e in ExperimentLedger,
            where: e.model_class == "pooled_linear",
            select: e.source_key
        )

      assert Enum.sort(Enum.uniq(persisted)) == Enum.sort([@list_a, @list_b])
    end
  end
end
