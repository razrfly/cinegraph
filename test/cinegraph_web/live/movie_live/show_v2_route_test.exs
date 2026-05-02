defmodule CinegraphWeb.MovieLive.ShowV2RouteTest do
  @moduledoc """
  Smoke tests for the show-page route promotion (issue #792):

  - `/movies/:slug` renders the V2 show page (`MovieLive.ShowV2`).
  - `/movies/:slug/legacy` renders the V1 show page (`MovieLive.Show`).
  - `/movies-v2/:slug` is kept as an alias and also renders V2.

  Doesn't drill into either page's content beyond a couple of distinguishing
  markers — full rendering is covered by the LiveViews' own tests.
  """
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Collaborations.Collaboration
  alias Cinegraph.Movies.Availability
  alias Cinegraph.Movies.Credit
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Movies.Person
  alias Cinegraph.Movies.Search
  alias Cinegraph.Movies.WatchProviderRegion
  alias Cinegraph.Workers.MovieAvailabilityRefreshWorker
  alias Cinegraph.Repo

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Show Promotion Test #{System.unique_integer()}",
      original_title: "Show Promotion Test",
      release_date: ~D[2020-06-01]
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_person!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Route Credit Person #{System.unique_integer([:positive])}"
    }

    %Person{}
    |> Person.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_credit!(movie, person, attrs) do
    defaults = %{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      credit_id: "route-credit-#{movie.id}-#{person.id}-#{System.unique_integer([:positive])}"
    }

    %Credit{}
    |> Credit.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  setup do
    Cachex.clear(:movies_cache)
    Cachex.clear(:filter_options_cache)
    Repo.delete_all(Oban.Job)
    movie = insert_movie!(%{title: "Routing Smoke Title"})
    %{movie: movie}
  end

  describe "/movies/:slug — V2 primary" do
    test "renders the V2 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")
      # V2-specific marker: the bottom-right escape-hatch pill (#792)
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.slug}/legacy"
      assert html =~ movie.title
      assert html =~ ~s(<link rel="canonical" href="https://cinegraph.org/movies/#{movie.slug}")
      assert html =~ ~s(<meta property="og:type" content="video.movie")
      assert html =~ ~s(<meta property="og:title" content="Routing Smoke Title)
      assert html =~ ~s(<meta name="twitter:title" content="Routing Smoke Title)
      assert html =~ ~s("Movie")
      assert html =~ ~s("BreadcrumbList")
    end

    test "falls back to numeric ID routes for movies without slugs", %{conn: conn, movie: movie} do
      movie =
        movie
        |> Ecto.Changeset.change(slug: nil)
        |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.id}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.id}/legacy"
      assert html =~ movie.title
    end

    test "falls back to numeric ID legacy links for movies with empty slugs", %{
      conn: conn,
      movie: movie
    } do
      movie =
        movie
        |> Ecto.Changeset.change(slug: "")
        |> Repo.update!()

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.id}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.id}/legacy"
      assert html =~ movie.title
    end

    test "links cast and crew to canonical people pages", %{conn: conn, movie: movie} do
      cast_member = insert_person!(%{name: "Canonical Cast Person"})
      crew_member = insert_person!(%{name: "Canonical Crew Person"})

      insert_credit!(movie, cast_member, %{
        credit_type: "cast",
        character: "Runway Assistant",
        cast_order: 0
      })

      insert_credit!(movie, crew_member, %{
        credit_type: "crew",
        department: "Directing",
        job: "Director"
      })

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ ~s(href="/people/canonical-cast-person")
      assert html =~ ~s(href="/people/canonical-crew-person")
      refute html =~ "/people-v2/"
    end

    test "notable collaboration count matches the linked all-people movie search", %{conn: conn} do
      movie = insert_movie!(%{title: "Collaboration Count Route Current"})
      other_movie = insert_movie!(%{title: "Collaboration Count Route Other"})
      actor_a = insert_person!(%{name: "Route Count Actor A"})
      actor_b = insert_person!(%{name: "Route Count Actor B"})

      insert_credit!(movie, actor_a, %{credit_type: "cast", cast_order: 0})
      insert_credit!(movie, actor_b, %{credit_type: "cast", cast_order: 1})
      insert_credit!(other_movie, actor_a, %{credit_type: "cast", cast_order: 0})
      insert_credit!(other_movie, actor_b, %{credit_type: "cast", cast_order: 1})

      insert_collaboration!(actor_a, actor_b, %{collaboration_count: 5})

      assert {:ok, linked_count} =
               Search.count_movies(%{
                 "people_ids" => "#{actor_a.id},#{actor_b.id}",
                 "people_match" => "all"
               })

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert linked_count == 2
      assert html =~ ~r/>#{linked_count}<\/b>\s+films together/

      assert html =~
               ~s(href="/movies?people=#{actor_a.slug},#{actor_b.slug}&amp;people_match=all")
    end

    test "renders grouped Where to Watch providers with logo/name sorted by priority", %{
      conn: conn,
      movie: movie
    } do
      payload = %{
        "results" => %{
          "US" => %{
            "link" => "https://example.test/watch",
            "flatrate" => [
              provider(9, "Prime Video", 9),
              provider(8, "Netflix", 1)
            ],
            "ads" => [provider(300, "Tubi", 2)]
          }
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Where to Watch"
      assert html =~ "Streaming"
      assert html =~ "Free with ads"
      assert html =~ "Netflix"
      assert html =~ "Prime Video"
      assert html =~ "Tubi"
      assert html =~ "https://image.tmdb.org/t/p/w92/provider-8.jpg"
      assert html =~ "Updated today."
      assert html =~ "Availability data from TMDb"
      assert html =~ ~r/Netflix.*Prime Video/s
    end

    test "renders multiple regions and switches provider groups", %{conn: conn, movie: movie} do
      payload = %{
        "results" => %{
          "US" => %{
            "flatrate" => [provider(8, "Netflix", 1)]
          },
          "GB" => %{
            "rent" => [provider(2, "Apple TV", 2)]
          }
        }
      }

      %WatchProviderRegion{}
      |> WatchProviderRegion.changeset(%{
        iso_3166_1: "GB",
        english_name: "United Kingdom",
        source: "tmdb",
        active: true
      })
      |> Repo.insert!()

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      {:ok, view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇺🇸 United States."
      assert html =~ "Netflix"
      assert html =~ "United Kingdom"

      html =
        view
        |> form("#availability-region-form", region: "GB")
        |> render_change()

      assert html =~ "Availability for 🇬🇧 United Kingdom."
      assert html =~ "Apple TV"
      refute html =~ "Netflix"
    end

    test "uses browser locale region when normalized for the movie", %{conn: conn, movie: movie} do
      payload = %{
        "results" => %{
          "US" => %{"flatrate" => [provider(8, "Netflix", 1)]},
          "GB" => %{"rent" => [provider(2, "Apple TV", 2)]}
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      conn = put_connect_params(conn, %{"browser_locale" => "en-GB"})
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇬🇧 United Kingdom."
      assert html =~ "Apple TV"
      refute html =~ "Netflix"
    end

    test "uses browser timezone region ahead of US browser language", %{conn: conn, movie: movie} do
      payload = %{
        "results" => %{
          "US" => %{"flatrate" => [provider(8, "Netflix", 1)]},
          "PL" => %{"rent" => [provider(2, "Apple TV", 2)]}
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      conn =
        put_connect_params(conn, %{
          "browser_locale" => "en-US",
          "browser_locales" => ["en-US", "pl"],
          "browser_timezone" => "Europe/Warsaw"
        })

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇵🇱 Poland."
      assert html =~ "Apple TV"
      refute html =~ "Netflix"
    end

    test "uses later browser locale when earlier hints are unavailable", %{
      conn: conn,
      movie: movie
    } do
      payload = %{
        "results" => %{
          "US" => %{"flatrate" => [provider(8, "Netflix", 1)]},
          "GB" => %{"rent" => [provider(2, "Apple TV", 2)]}
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      conn =
        put_connect_params(conn, %{
          "browser_locales" => ["fr-FR", "en-GB"],
          "browser_timezone" => "Europe/Warsaw"
        })

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇬🇧 United Kingdom."
      assert html =~ "Apple TV"
      refute html =~ "Netflix"
    end

    test "falls back to US when browser locale region is not normalized", %{
      conn: conn,
      movie: movie
    } do
      payload = %{
        "results" => %{
          "US" => %{"flatrate" => [provider(8, "Netflix", 1)]},
          "GB" => %{"rent" => [provider(2, "Apple TV", 2)]}
        }
      }

      assert {:ok, _} = Availability.store_tmdb_watch_providers(movie, payload)

      conn = put_connect_params(conn, %{"browser_locale" => "fr-FR"})
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇺🇸 United States."
      assert html =~ "Netflix"
      refute html =~ "Apple TV"
    end

    test "renders stale warning", %{conn: conn, movie: movie} do
      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, watch_payload(),
                 fetched_at: ~U[2026-01-01 00:00:00Z],
                 stale_after: ~U[2026-01-31 00:00:00Z]
               )

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability may have changed."
    end

    test "renders no-results state", %{conn: conn, movie: movie} do
      assert {:ok, _} =
               Availability.store_tmdb_watch_providers(movie, %{
                 "results" => %{"US" => %{"link" => "https://example.test/watch"}}
               })

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "No availability found for 🇺🇸 United States."
    end

    test "renders never-fetched state", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇺🇸 United States has not been checked yet."
    end

    test "renders error state", %{conn: conn, movie: movie} do
      assert {:ok, _} = Availability.record_availability_error(movie, ["US"], :tmdb_down)

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Availability for 🇺🇸 United States could not be refreshed."
    end

    test "renders queued state", %{conn: conn, movie: movie} do
      %{"movie_id" => movie.id, "regions" => ["US"], "force" => true, "source" => "manual"}
      |> MovieAvailabilityRefreshWorker.new()
      |> Oban.insert!()

      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}")

      assert html =~ "Refresh queued."
    end
  end

  describe "/movies-v2/:slug — alias" do
    test "still renders the V2 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies-v2/#{movie.slug}")
      assert html =~ "Old movie page"
      assert html =~ ~p"/movies/#{movie.slug}/legacy"
      assert html =~ movie.title
    end
  end

  describe "/movies/:slug/legacy — V1 escape hatch" do
    test "renders the V1 show page", %{conn: conn, movie: movie} do
      {:ok, _view, html} = live(conn, ~p"/movies/#{movie.slug}/legacy")
      # V1 marker: the "Back to Movies" breadcrumb link uses ~p"/movies"
      assert html =~ "Back to Movies"
      assert html =~ movie.title
      # V2 marker should NOT appear on V1
      refute html =~ "Old movie page"
    end
  end

  defp insert_collaboration!(person_a, person_b, attrs) do
    {person_a_id, person_b_id} = {min(person_a.id, person_b.id), max(person_a.id, person_b.id)}

    %Collaboration{}
    |> Collaboration.changeset(
      Map.merge(
        %{
          person_a_id: person_a_id,
          person_b_id: person_b_id,
          collaboration_count: 2
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp watch_payload(provider_id \\ 8, provider_name \\ "Netflix") do
    %{
      "results" => %{
        "US" => %{
          "link" => "https://example.test/watch",
          "flatrate" => [provider(provider_id, provider_name)]
        }
      }
    }
  end

  defp provider(id, name, priority \\ 1) do
    %{
      "provider_id" => id,
      "provider_name" => name,
      "logo_path" => "/provider-#{id}.jpg",
      "display_priority" => priority
    }
  end
end
