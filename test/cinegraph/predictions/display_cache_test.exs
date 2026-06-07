defmodule Cinegraph.Predictions.DisplayCacheTest do
  @moduledoc """
  #1084 P0b — the /algorithms display cache: single-flight, byte-identical results,
  model-identity keys, and the bust contract.
  """
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{Movie, MovieList, MovieLists}
  alias Cinegraph.Predictions.{Candidates, DisplayCache, Model, PreRegistration}
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:algorithms_cache)
    CatalogSeed.seed!()
    Cachex.clear(:algorithms_cache)
    :ok
  end

  defp served_list!(sk) do
    %MovieList{}
    |> MovieList.changeset(%{
      source_key: sk,
      name: "DC List #{sk}",
      source_type: "imdb",
      source_url: "https://example.com/l",
      slug: "dc-#{sk}",
      active: true
    })
    |> Repo.insert!()

    {:ok, prereg} =
      PreRegistration.register(%{
        source_key: sk,
        expected_top_features: %{},
        expected_accuracy_range: %{},
        failure_threshold: "0.10"
      })

    model =
      %Model{}
      |> Model.changeset(%{
        source_key: sk,
        feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
        weights: %{"imdb_rating" => 1.0},
        weights_hash: "dc_h#{System.unique_integer([:positive])}",
        model_version: 1,
        backtest_strategy: "static",
        integrity_report: %{
          "recall_at_k" => 0.5,
          "n_positives" => 20,
          "n_evaluated" => 100,
          "baselines" => %{"popularity" => 0.0}
        },
        prereg_id: prereg.id
      })
      |> Repo.insert!()

    {:ok, _} = MovieLists.set_active_prediction_model(sk, model.id, model.weights)

    member =
      %Movie{}
      |> Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "DC Member",
        import_status: "full",
        release_date: ~D[2019-01-01],
        canonical_sources: %{sk => 1}
      })
      |> Repo.insert!()

    {model, member}
  end

  test "single-flight: concurrent misses on one key run the fallback exactly once" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    build = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(150)
      [:cards]
    end

    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> DisplayCache.index_cards(build) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &(&1 == [:cards]))
    assert Agent.get(counter, & &1) == 1
  end

  test "ranked_members: cached result is byte-identical to the uncached read-model" do
    sk = "dc_ident_#{System.unique_integer([:positive])}"
    {_model, _member} = served_list!(sk)

    fresh = Candidates.rank(sk, mode: "members", limit: 10)
    cached = DisplayCache.ranked_members(sk, limit: 10)
    cached_again = DisplayCache.ranked_members(sk, limit: 10)

    assert cached == fresh
    assert cached_again == fresh
  end

  test "canonical-limit slicing: asks ≤ 48 share ONE cache entry, sliced on read" do
    sk = "dc_slice_#{System.unique_integer([:positive])}"
    {_model, _member} = served_list!(sk)

    # a second member so the slice is observable
    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "DC Member 2",
      import_status: "full",
      release_date: ~D[2020-01-01],
      canonical_sources: %{sk => 1}
    })
    |> Repo.insert!()

    {:ok, full} = DisplayCache.ranked_members(sk, limit: 48)
    {:ok, sliced} = DisplayCache.ranked_members(sk, limit: 1)

    assert length(sliced.rows) == 1
    assert sliced.rows == Enum.take(full.rows, 1)

    # both asks share the single canonical-limit entry — no per-limit keys below 48
    {:ok, keys} = Cachex.keys(:algorithms_cache)
    rank_keys = Enum.filter(keys, &match?({:ranked_members, ^sk, _, _, _}, &1))
    assert [{:ranked_members, ^sk, _, _, 48}] = rank_keys
  end

  test "errors are never cached: an unserved list passes through uncached every call" do
    sk = "dc_unserved_#{System.unique_integer([:positive])}"
    assert {:error, :no_active_model} = DisplayCache.next_additions(sk, limit: 5)
    # nothing pinned: still the live answer (and still an error) on the next call
    assert {:error, :no_active_model} = DisplayCache.next_additions(sk, limit: 5)
  end

  test "the pointer write path busts the cache and board_version changes" do
    sk = "dc_bust_#{System.unique_integer([:positive])}"
    {model, _member} = served_list!(sk)

    v1 = DisplayCache.board_version()
    # warm a ranking entry
    {:ok, _} = DisplayCache.ranked_members(sk, limit: 5)
    {:ok, keys} = Cachex.keys(:algorithms_cache)
    # cached at the canonical limit (asks ≤ canonical share one entry, sliced on read)
    assert Enum.any?(keys, &match?({:ranked_members, ^sk, _, _, 48}, &1))

    # demote — the sole write path must clear the cache
    {:ok, _} = MovieLists.set_active_prediction_model(sk, nil, nil)
    {:ok, keys_after} = Cachex.keys(:algorithms_cache)
    refute Enum.any?(keys_after, &match?({:ranked_members, ^sk, _, _, 48}, &1))
    assert DisplayCache.board_version() != v1

    # restore for hygiene
    {:ok, _} = MovieLists.set_active_prediction_model(sk, model.id, model.weights)
  end

  test "CatalogSeed.seed! busts the catalog map (and the whole display cache)" do
    # warm the map
    assert %{} = Cinegraph.Metrics.get_metric_definition("imdb_rating") |> Map.from_struct()
    {:ok, keys} = Cachex.keys(:algorithms_cache)
    assert :metric_definitions_by_code in keys

    CatalogSeed.seed!()
    {:ok, keys_after} = Cachex.keys(:algorithms_cache)
    refute :metric_definitions_by_code in keys_after
  end
end
