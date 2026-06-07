defmodule Cinegraph.Workers.AlgorithmsCacheWarmerTest do
  @moduledoc """
  #1084 A.1 — the server-side rankings warmer: warms every served list's display-cache
  entries at the canonical limit, skips unserved lists, and the bust path enqueues it.
  """
  use Cinegraph.DataCase, async: false
  use Oban.Testing, repo: Cinegraph.Repo

  alias Cinegraph.Metrics.CatalogSeed
  alias Cinegraph.Movies.{Movie, MovieList, MovieLists}
  alias Cinegraph.Predictions.{DisplayCache, Model, PreRegistration}
  alias Cinegraph.Repo
  alias Cinegraph.Workers.AlgorithmsCacheWarmer

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
      name: "Warm List #{sk}",
      source_type: "imdb",
      source_url: "https://example.com/l",
      slug: "warm-#{sk}",
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
        weights_hash: "warm_h#{System.unique_integer([:positive])}",
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

    %Movie{}
    |> Movie.changeset(%{
      tmdb_id: System.unique_integer([:positive]),
      title: "Warm Member",
      import_status: "full",
      release_date: ~D[2019-01-01],
      canonical_sources: %{sk => 1}
    })
    |> Repo.insert!()

    model
  end

  # Active but no model pointer → not served, so the warmer must skip it.
  defp unserved_list!(sk) do
    %MovieList{}
    |> MovieList.changeset(%{
      source_key: sk,
      name: "Unserved List #{sk}",
      source_type: "imdb",
      source_url: "https://example.com/u",
      slug: "unserved-#{sk}",
      active: true
    })
    |> Repo.insert!()
  end

  test "perform/1 warms served lists' rankings at the canonical limit; unserved lists are skipped" do
    sk = "warm_#{System.unique_integer([:positive])}"
    unserved_sk = "unserved_#{System.unique_integer([:positive])}"
    served_list!(sk)
    unserved_list!(unserved_sk)
    Cachex.clear(:algorithms_cache)

    assert {:ok, %{failed: []}} = perform_job(AlgorithmsCacheWarmer, %{})

    {:ok, keys} = Cachex.keys(:algorithms_cache)
    assert Enum.any?(keys, &match?({:next_additions, ^sk, _, _, 48}, &1))
    assert Enum.any?(keys, &match?({:ranked_members, ^sk, _, _, 48}, &1))

    # the unserved list was never warmed — no cache entries carry its key
    refute Enum.any?(keys, &match?({:next_additions, ^unserved_sk, _, _, _}, &1))
    refute Enum.any?(keys, &match?({:ranked_members, ^unserved_sk, _, _, _}, &1))
  end

  test "DisplayCache.bust/0 enqueues a (deduped) warm run" do
    DisplayCache.bust()
    DisplayCache.bust()

    assert [_only_one] = all_enqueued(worker: AlgorithmsCacheWarmer)
  end
end
