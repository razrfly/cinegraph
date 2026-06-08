defmodule CinegraphWeb.AlgorithmsLiveTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  setup do
    # The /algorithms pages read through :algorithms_cache (#1084) — clear it so cards/rankings
    # never leak across tests (the index key is global; sandbox rows differ per test).
    Cachex.clear(:algorithms_cache)
    :ok
  end

  defp displayable_list!(attrs) do
    %MovieList{}
    |> MovieList.changeset(
      Map.merge(
        %{
          source_key: "tlist_#{System.unique_integer([:positive])}",
          name: "Test List #{System.unique_integer([:positive])}",
          source_type: "imdb",
          source_url: "https://example.com/l",
          slug: "test-list-#{System.unique_integer([:positive])}",
          active: true,
          display_order: 1
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  describe "/algorithms" do
    test "renders the honest index chrome + methodology", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/algorithms")

      assert html =~ "Algorithms."
      assert html =~ "Prediction Reliability"
      assert html =~ "How we measure"
      # honesty furniture
      assert html =~ "Wilson-95 lower bound"
      assert html =~ "not metadata-predictable"
    end

    test "a list with no active model renders as an honest 'not predictable' card", %{conn: conn} do
      list = displayable_list!(name: "Lonely Cult List")

      {:ok, _view, html} = live(conn, ~p"/algorithms")

      assert html =~ "Lonely Cult List"
      assert html =~ "serve a prediction for this list"

      refute is_nil(Repo.get(MovieList, list.id))
    end

    test "a rail list renders in the Recommendation rails section, not as unpredictable",
         %{conn: conn} do
      displayable_list!(name: "Index Rail List", metadata: %{"rail" => true})

      {:ok, _view, html} = live(conn, ~p"/algorithms")

      assert html =~ "Index Rail List"
      assert html =~ "Recommendation rails"
      assert html =~ "no single right answer"
      # a rail is an engine, not a failed prediction — it carries the rail descriptor
      assert html =~ "Seed-conditioned picks from the clerk"
    end
  end

  describe "/algorithms/:slug (show)" do
    test "an unserved list renders the honest 'not metadata-predictable' detail", %{conn: conn} do
      list =
        displayable_list!(
          name: "Frozen Taste List",
          slug: "frozen-taste-#{System.unique_integer([:positive])}"
        )

      {:ok, _view, html} = live(conn, ~p"/algorithms/#{list.slug}")

      assert html =~ "Frozen Taste List"
      assert html =~ "Not metadata-predictable"

      assert html =~ "We don't serve a prediction for this list" or
               html =~ "We don&#39;t serve a prediction for this list"

      assert html =~ "Back to all algorithms"
      # the weight breakdown is served-only
      refute html =~ "What drives the prediction"
    end

    test "an unserved list still shows its members as a poster grid", %{conn: conn} do
      list = displayable_list!(name: "Members Grid List")

      %Cinegraph.Movies.Movie{}
      |> Cinegraph.Movies.Movie.changeset(%{
        tmdb_id: System.unique_integer([:positive]),
        title: "Grid Member Film",
        import_status: "full",
        release_date: ~D[2010-05-05],
        canonical_sources: %{list.source_key => 1}
      })
      |> Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/algorithms/#{list.slug}")

      assert html =~ "Grid Member Film"
      assert html =~ "On the list"
    end

    test "an unknown slug redirects back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/algorithms"}}} =
               live(conn, ~p"/algorithms/no-such-list-#{System.unique_integer([:positive])}")
    end

    # ── #1077: the unified ranked list view (needs a served model) ─────────────────────
    defp plant_served_model!(list) do
      Cinegraph.Metrics.CatalogSeed.seed!()

      {:ok, prereg} =
        Cinegraph.Predictions.PreRegistration.register(%{
          source_key: list.source_key,
          expected_top_features: %{},
          expected_accuracy_range: %{},
          failure_threshold: "0.10"
        })

      model =
        %Cinegraph.Predictions.Model{}
        |> Cinegraph.Predictions.Model.changeset(%{
          source_key: list.source_key,
          feature_set: %{"granularity" => "data_point", "features" => ["imdb_rating"]},
          weights: %{"imdb_rating" => 0.6, "metacritic_metascore" => 0.4},
          weights_hash: "lv_h#{System.unique_integer([:positive])}",
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

      list |> Ecto.Changeset.change(active_prediction_model_id: model.id) |> Repo.update!()
    end

    defp film!(title, date, attrs) do
      movie =
        %Cinegraph.Movies.Movie{}
        |> Cinegraph.Movies.Movie.changeset(
          Map.merge(
            %{
              tmdb_id: System.unique_integer([:positive]),
              title: title,
              import_status: "full",
              release_date: date
            },
            Map.new(attrs)
          )
        )
        |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        "external_metrics",
        [
          %{
            movie_id: movie.id,
            source: "imdb",
            metric_type: "rating_average",
            value: 8.0,
            fetched_at: now,
            inserted_at: now,
            updated_at: now
          },
          %{
            movie_id: movie.id,
            source: "metacritic",
            metric_type: "metascore",
            value: 70.0,
            fetched_at: now,
            inserted_at: now,
            updated_at: now
          }
        ]
      )

      movie
    end

    test "the unified ranked view: sections, member ✓, why, search filter + probe fallback",
         %{conn: conn} do
      list = displayable_list!(name: "Unified View List")
      plant_served_model!(list)
      sk = list.source_key

      _member = film!("Unified Member Film", ~D[2018-05-05], canonical_sources: %{sk => 1})
      _candidate = film!("Unified Candidate Film", ~D[2024-06-06], canonical_sources: %{})

      {:ok, view, html} = live(conn, ~p"/algorithms/#{list.slug}")

      # tab=all is the default; both section headers render
      assert html =~ "Predicted next additions"
      assert html =~ "Already on the list"
      assert html =~ "the truth the model learns from"

      html = render_async(view)
      # member row with the ✓ pill and the prediction row, one score scale
      assert html =~ "Unified Member Film"
      assert html =~ "✓ on the list"
      assert html =~ "Unified Candidate Film"
      assert html =~ "why ▾"
      assert html =~ "signals moving this score"

      # search filters the loaded rows
      html = render_change(view, "list_search", %{"q" => "Unified Member"})
      assert html =~ "Unified Member Film"
      assert html =~ "No predictions match the filter."

      # the chips patch to the classic grid tabs
      view
      |> element("a", "Predicted next")
      |> render_click()

      assert_patch(view, ~p"/algorithms/#{list.slug}?tab=predictions")
    end

    # Regression: shelf_picks pipes universe_query (which has a select) into apply_scoring (which
    # sets its own) — without exclude(:select) the rail page 500s with Ecto.Query.CompileError.
    test "a rail list mounts in rail mode and ranks its shelf", %{conn: conn} do
      list = displayable_list!(name: "Show Rail List", metadata: %{"rail" => true})

      {:ok, _view, html} = live(conn, ~p"/algorithms/#{list.slug}")

      assert html =~ "How this rail thinks"
      assert html =~ "Start from a film you love"
      # no accuracy claims in rail mode, ever (the generic methodology footer is fine)
      refute html =~ "recall@K (95% lower bound)"
    end
  end

  describe "/algorithms/compare" do
    test "renders the chrome (and isn't captured by the /:slug route)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/algorithms/compare")

      assert html =~ "Compare algorithms."
      assert html =~ "Seed film"
      # the honesty footer
      assert html =~ "Rails carry no percentages"
    end

    test "unknown rails are ignored; an unserved list renders an honest column", %{conn: conn} do
      list = displayable_list!(name: "Unserved Column List")

      {:ok, _view, html} =
        live(conn, ~p"/algorithms/compare?#{[rails: "#{list.slug},no-such-rail-999"]}")

      assert html =~ "Unserved Column List"
      assert html =~ "Not metadata-predictable"
      assert html =~ "nothing truthful to put in this column"
      refute html =~ "no-such-rail-999"
    end

    test "a rail column without a seed asks for one instead of faking picks", %{conn: conn} do
      list = displayable_list!(name: "Clerk Rail List", metadata: %{"rail" => true})

      {:ok, _view, html} = live(conn, ~p"/algorithms/compare?#{[rails: list.slug]}")

      assert html =~ "Clerk Rail List"
      assert html =~ "Recommendation rail"
      assert html =~ "Waiting for a seed film"
    end

    test "a seed renders its chip and the rail column answers (no scores)", %{conn: conn} do
      list = displayable_list!(name: "Seeded Rail List", metadata: %{"rail" => true})

      movie =
        %Cinegraph.Movies.Movie{}
        |> Cinegraph.Movies.Movie.changeset(%{
          tmdb_id: System.unique_integer([:positive]),
          title: "Compare Seed Film",
          import_status: "full",
          release_date: ~D[1994-10-14]
        })
        |> Repo.insert!()

      {:ok, view, html} =
        live(conn, ~p"/algorithms/compare?#{[seed: movie.slug, rails: list.slug]}")

      assert html =~ "Compare Seed Film"
      assert html =~ "clerk&#39;s picks" or html =~ "clerk's picks"

      # the clerk has nothing on its shelves in the test DB — the column says so honestly
      html = render_async(view)
      assert html =~ "Nothing to show for this column"
    end

    test "toggling a rail patches the URL (the URL is the state)", %{conn: conn} do
      list = displayable_list!(name: "Toggle Rail List")

      {:ok, view, _html} = live(conn, ~p"/algorithms/compare")

      view
      |> element("button[phx-value-slug='#{list.slug}'][phx-click='rail_toggle']")
      |> render_click()

      assert_patch(view, ~p"/algorithms/compare?#{[rails: list.slug]}")
    end
  end
end
