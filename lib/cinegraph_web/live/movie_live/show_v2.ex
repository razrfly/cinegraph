defmodule CinegraphWeb.MovieLive.ShowV2 do
  @moduledoc """
  Movie show page on the V2 design system. Mounts at `/movies/:slug`.

  Models its hero on `MovieLive.Show` (V1) — full-bleed backdrop with a simple
  bottom-up dark gradient and white text — then applies V2 styling
  (Instrument Serif italic display, Inter body, mist palette) to the body
  sections below.

  V1 (`MovieLive.Show`) is untouched.
  """
  use CinegraphWeb, :live_view

  import CinegraphWeb.SEOHelpers

  alias Cinegraph.Movies
  alias Cinegraph.Movies.MovieScoring
  alias Cinegraph.Movies.MovieCollaborations
  alias Cinegraph.Cultural
  alias Cinegraph.ExternalSources
  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.DisparityCalculator
  alias Cinegraph.Repo
  alias Cinegraph.Workers.MovieScoreCacheWorker
  alias CinegraphWeb.Helpers.UrlHelpers
  alias CinegraphWeb.NeutralV2Components

  require Logger

  @dept_priority ~w(Directing Writing Camera Editing Sound Production Art)
  @country_priority ~w(US GB FR DE JP KR IT ES CA AU IN BR MX)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "Movies")
     |> assign(:show_score_modal, false)
     |> assign(:overview_expanded, false)
     |> assign(:show_full_cast, false)
     |> assign(:show_full_crew, false)
     |> assign(:show_all_releases, false)}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    case load_movie(slug) do
      {:ok, data} ->
        {:noreply,
         socket
         |> assign(data)
         |> assign_movie_seo(data.movie)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Movie not found")
         |> push_navigate(to: ~p"/movies")}
    end
  end

  @impl true
  def handle_event("toggle_overview", _, socket),
    do: {:noreply, assign(socket, :overview_expanded, !socket.assigns.overview_expanded)}

  def handle_event("show_score_modal", _, socket),
    do: {:noreply, assign(socket, :show_score_modal, true)}

  def handle_event("hide_score_modal", _, socket),
    do: {:noreply, assign(socket, :show_score_modal, false)}

  def handle_event("toggle_full_cast", _, socket),
    do: {:noreply, assign(socket, :show_full_cast, !socket.assigns.show_full_cast)}

  def handle_event("toggle_full_crew", _, socket),
    do: {:noreply, assign(socket, :show_full_crew, !socket.assigns.show_full_crew)}

  def handle_event("toggle_all_releases", _, socket),
    do: {:noreply, assign(socket, :show_all_releases, !socket.assigns.show_all_releases)}

  def handle_event("stop_propagation", _, socket), do: {:noreply, socket}

  # ─── Data loading (mirrors V1 patterns) ────────────────────────────

  defp load_movie(id_or_slug) do
    case fetch_movie_by_slug_or_id(id_or_slug) do
      {:ok, movie} -> load_movie_data(movie)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp load_movie_data(movie) do
    movie = Repo.replica().preload(movie, :score_cache)
    movie = Map.merge(movie, Metrics.get_movie_aggregates(movie.id))

    current_version = MovieScoreCacheWorker.current_version()

    {scores, disparity} =
      if movie.score_cache && movie.score_cache.calculation_version == current_version do
        {build_display_scores(movie.score_cache),
         %{
           disparity_score: movie.score_cache.disparity_score,
           disparity_category: movie.score_cache.disparity_category
         }}
      else
        MovieScoreCacheWorker.new(%{"movie_id" => movie.id}, unique: [period: 60])
        |> Oban.insert()

        sd = MovieScoring.calculate_movie_scores(movie)
        {build_display_scores_from_data(sd), DisparityCalculator.calculate_all(sd)}
      end

    credits = Movies.get_movie_credits(movie.id)

    cast =
      credits |> Enum.filter(&(&1.credit_type == "cast")) |> Enum.sort_by(&(&1.cast_order || 999))

    crew = Enum.filter(credits, &(&1.credit_type == "crew"))
    directors = Enum.filter(crew, &(&1.job == "Director"))

    ratings = ExternalSources.get_movie_ratings(movie.id)
    festival_noms = Cultural.get_movie_all_festival_nominations(movie.id) || []
    canon_lists = Cultural.get_list_movies_for_movie(movie.id) || []
    keywords = Movies.get_movie_keywords(movie.id) || []
    videos = Movies.get_movie_videos(movie.id) || []
    production_companies = Movies.get_movie_production_companies(movie.id) || []
    release_dates = Movies.get_movie_release_dates(movie.id) || []

    key_collabs = MovieCollaborations.get_key_collaborations(cast, crew)

    collab_timelines =
      MovieCollaborations.get_collaboration_timelines(movie, key_collabs) || []

    timeline_index =
      collab_timelines
      |> Enum.map(fn t -> {{t.person_a.id, t.person_b.id}, t.movies} end)
      |> Map.new()

    related = MovieCollaborations.get_related_movies_by_collaboration(movie, cast, crew) || []

    director_other_films =
      case directors do
        [%{person: %{id: pid}} | _] -> fetch_director_filmography(pid, movie.id)
        _ -> []
      end

    {:ok,
     %{
       movie: movie,
       scores: scores,
       disparity_data: disparity,
       cast: cast,
       crew: crew,
       directors: directors,
       ratings: ratings,
       festival_noms: festival_noms,
       canon_lists: canon_lists,
       keywords: keywords,
       videos: videos,
       production_companies: production_companies,
       release_dates: release_dates,
       key_collabs: key_collabs,
       timeline_index: timeline_index,
       related_movies: related,
       director_other_films: director_other_films
     }}
  end

  defp fetch_movie_by_slug_or_id(id_or_slug) do
    case Integer.parse(id_or_slug) do
      {id, ""} -> {:ok, Movies.get_movie!(id)}
      _ -> {:ok, Movies.get_movie_by_slug!(id_or_slug)}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp build_display_scores(cache) do
    %{
      mob: cache.mob_score || 0.0,
      critics: cache.critics_score || 0.0,
      festival_recognition: cache.festival_recognition_score || 0.0,
      time_machine: cache.time_machine_score || 0.0,
      auteurs: cache.auteurs_score || 0.0,
      box_office: cache.box_office_score || 0.0,
      overall: cache.overall_score || 0.0
    }
  end

  defp build_display_scores_from_data(sd) do
    c = sd.components

    %{
      mob: c.mob,
      critics: c.critics,
      festival_recognition: c.festival_recognition,
      time_machine: c.time_machine,
      auteurs: c.auteurs,
      box_office: c.box_office,
      overall: sd.overall_score
    }
  end

  defp fetch_director_filmography(person_id, exclude_movie_id) do
    import Ecto.Query

    from(c in Cinegraph.Movies.Credit,
      where:
        c.person_id == ^person_id and c.credit_type == "crew" and c.job == "Director" and
          c.movie_id != ^exclude_movie_id,
      join: m in assoc(c, :movie),
      preload: [movie: m],
      order_by: [desc: m.release_date],
      limit: 4
    )
    |> Repo.replica().all()
    |> Enum.map(& &1.movie)
  end

  # ─── Helpers ───────────────────────────────────────────────────────

  defp tmdb_url(nil, _), do: nil
  defp tmdb_url("", _), do: nil
  defp tmdb_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp year_of(%Date{year: y}), do: y
  defp year_of(_), do: nil

  defp format_runtime(nil), do: nil

  defp format_runtime(min) when is_integer(min) do
    h = div(min, 60)
    m = rem(min, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{m}m"
    end
  end

  defp content_rating(%{omdb_data: %{"Rated" => r}}) when is_binary(r) and r != "" and r != "N/A",
    do: r

  defp content_rating(_), do: nil

  defp disparity_label("critics_darling"), do: "Critics' Darling"
  defp disparity_label("peoples_champion"), do: "People's Champion"
  defp disparity_label("polarizer"), do: "Polarizer"
  defp disparity_label(_), do: nil

  defp disparity_summary(disparity_data, scores) do
    case disparity_data[:disparity_category] do
      "critics_darling" ->
        gap = ((scores[:critics] || 0) - (scores[:mob] || 0)) |> Float.round(1)
        "critics +#{gap} over audience"

      "peoples_champion" ->
        gap = ((scores[:mob] || 0) - (scores[:critics] || 0)) |> Float.round(1)
        "audience +#{gap} over critics"

      "polarizer" ->
        "audience and critics divided"

      _ ->
        nil
    end
  end

  defp truncate_words(text, n) when is_binary(text) do
    words = String.split(text)

    if length(words) <= n,
      do: {text, false},
      else: {words |> Enum.take(n) |> Enum.join(" "), true}
  end

  defp truncate_words(_, _), do: {"", false}

  defp format_money(nil), do: nil
  defp format_money(0), do: nil

  defp format_money(n) when is_number(n) and n >= 1_000_000_000,
    do: "$#{Float.round(n / 1_000_000_000, 1)}B"

  defp format_money(n) when is_number(n) and n >= 1_000_000,
    do: "$#{Float.round(n / 1_000_000, 1)}M"

  defp format_money(n) when is_number(n), do: "$#{n}"

  defp rating_value(ratings, source_key, type \\ "rating_average") do
    Enum.find(ratings, fn r ->
      key =
        case r[:source] do
          %{source_key: sk} -> sk
          %{name: n} -> n
          _ -> nil
        end

      key == source_key and r[:metric_type] == type
    end)
  end

  defp pluralize_str(1, w), do: w
  defp pluralize_str(_, w), do: w <> "s"

  defp production_company_name(%{name: n}), do: n
  defp production_company_name(%{production_company: %{name: n}}), do: n
  defp production_company_name(_), do: "—"

  defp count_award_wins(noms) when is_list(noms) do
    Enum.reduce(noms, 0, fn org, acc ->
      acc + Enum.count(Map.get(org, :nominations) || [], fn n -> Map.get(n, :won) == true end)
    end)
  end

  defp count_award_wins(_), do: 0

  defp count_award_nominations(noms) when is_list(noms) do
    Enum.reduce(noms, 0, fn org, acc ->
      acc + (Map.get(org, :total_nominations) || length(Map.get(org, :nominations) || []))
    end)
  end

  defp count_award_nominations(_), do: 0

  defp render_nominations(noms) when is_list(noms) do
    Enum.map(noms, fn n ->
      person_name =
        case n[:person] do
          %{name: name} -> name
          _ -> n[:details]["nominee_names"]
        end

      %{
        category: Map.get(n, :category_name) || Map.get(n, :category) || "—",
        year: Map.get(n, :ceremony_year),
        won: !!Map.get(n, :won),
        person_name: person_name,
        film_title: nil,
        film_href: nil
      }
    end)
  end

  defp render_nominations(_), do: []

  defp film_card_shape(movie) do
    href = UrlHelpers.movie_href(movie.slug, movie.id)

    %{
      id: movie.id,
      title: movie.title,
      year: year_of(movie.release_date),
      score: nil,
      poster_url: tmdb_url(movie.poster_path, "w500"),
      href: href
    }
  end

  defp related_card_shape(rel) do
    href = UrlHelpers.movie_href(rel[:slug], rel.id)

    %{
      id: rel.id,
      title: rel.title,
      year: year_of(rel[:release_date]),
      score: nil,
      poster_url: tmdb_url(rel[:poster_path], "w500"),
      href: href,
      reason: rel[:connection_reason]
    }
  end

  defp cast_credit_shape(credit) do
    %{
      name: credit.person.name,
      character: credit.character,
      avatar_url: tmdb_url(credit.person.profile_path, "w185"),
      href: "/people-v2/#{credit.person.slug || credit.person.id}"
    }
  end

  defp crew_credit_shape(c) do
    %{
      name: c.person.name,
      job: c.job,
      avatar_url: tmdb_url(c.person.profile_path, "w185"),
      href: "/people-v2/#{c.person.slug || c.person.id}"
    }
  end

  defp prioritize_releases(releases) do
    releases
    |> Enum.group_by(& &1.country_code)
    |> Enum.map(fn {country, recs} ->
      earliest =
        recs
        |> Enum.reject(&is_nil(&1.release_date))
        |> Enum.min_by(& &1.release_date, NaiveDateTime, fn -> nil end)

      cert = Enum.find_value(recs, &(&1.certification not in [nil, ""] && &1.certification))

      %{
        country_code: country,
        release_date: earliest && earliest.release_date,
        certification: cert
      }
    end)
    |> Enum.sort_by(fn r ->
      case Enum.find_index(@country_priority, &(&1 == r.country_code)) do
        nil -> {1, r.country_code}
        i -> {0, i}
      end
    end)
  end

  defp crew_by_department(crew) do
    crew
    |> Enum.reject(&(&1.department in [nil, ""]))
    |> Enum.group_by(& &1.department)
    |> Enum.sort_by(fn {d, _} ->
      case Enum.find_index(@dept_priority, &(&1 == d)) do
        nil -> {1, d}
        i -> {0, i}
      end
    end)
  end

  defp collab_shape(c, timeline_index) do
    movies = Map.get(timeline_index, {c[:person_a].id, c[:person_b].id})

    %{
      person_a: c[:person_a].name,
      person_b: c[:person_b].name,
      avatar_a: tmdb_url(c[:person_a].profile_path, "w185"),
      avatar_b: tmdb_url(c[:person_b].profile_path, "w185"),
      films_together: c[:collaboration_count] || c[:total_collaborations] || 0,
      strength:
        cond do
          (c[:collaboration_count] || 0) >= 10 -> :very_strong
          (c[:collaboration_count] || 0) >= 5 -> :strong
          true -> :moderate
        end,
      year_range: c[:year_range],
      avg_score: c[:avg_movie_rating],
      total_revenue: c[:total_revenue],
      movies: movies,
      href: nil
    }
  end

  defp director_names(directors) do
    directors |> Enum.map(& &1.person.name) |> Enum.join(" & ")
  end

  defp omdb_awards(%{omdb_data: %{"Awards" => a}}) when is_binary(a) and a != "" and a != "N/A",
    do: a

  defp omdb_awards(_), do: nil

  defp top_org_names(noms) when is_list(noms) do
    noms
    |> Enum.map(& &1[:organization_name])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(3)
    |> Enum.join(" · ")
  end

  defp top_org_names(_), do: nil

  defp top_canon_authorities(lists) when is_list(lists) do
    lists
    |> Enum.map(& &1.list_authority)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(2)
    |> Enum.join(" · ")
  end

  defp top_canon_authorities(_), do: nil

  defp top_festival_win(noms) when is_list(noms) do
    Enum.find_value(noms, fn org ->
      win =
        Enum.find(org[:nominations] || [], fn n ->
          n[:won] == true
        end)

      if win do
        %{
          org: org[:organization_name],
          year: win[:ceremony_year],
          category: win[:category_name] || win[:category]
        }
      end
    end)
  end

  defp top_festival_win(_), do: nil

  defp top_collab_pairing(key_collabs) do
    pair =
      List.first(key_collabs[:director_actor_reunions] || []) ||
        List.first(key_collabs[:actor_partnerships] || [])

    if pair, do: "#{pair.person_a.name} + #{pair.person_b.name}", else: nil
  end

  defp section_nav_items(assigns) do
    has_collabs =
      (assigns[:key_collabs][:director_actor_reunions] || []) != [] ||
        (assigns[:key_collabs][:actor_partnerships] || []) != []

    [
      %{id: "score", label: "Score", present?: true},
      %{id: "cast", label: "Cast", present?: assigns[:cast] != []},
      %{id: "crew", label: "Crew", present?: assigns[:crew] != []},
      %{id: "awards", label: "Awards", present?: assigns[:festival_noms] != []},
      %{id: "lists", label: "Lists", present?: assigns[:canon_lists] != []},
      %{id: "collaborations", label: "Collabs", present?: has_collabs},
      %{
        id: "director",
        label: "Director",
        present?: assigns[:director_other_films] != [] && assigns[:directors] != []
      },
      %{id: "similar", label: "Similar", present?: assigns[:related_movies] != []},
      %{id: "media", label: "Media", present?: assigns[:videos] != []},
      %{id: "releases", label: "Releases", present?: assigns[:release_dates] != []},
      %{id: "details", label: "Details", present?: true}
    ]
  end

  defp legacy_escape_pill(assigns) do
    ~H"""
    <%!-- Legacy v1 escape hatch — temporary during the V2 soak period (#792).
         Same placement and styling as the index pill in IndexV2. --%>
    <.link
      navigate={~p"/movies/#{movie_slug_or_id(@movie)}/legacy"}
      class="fixed bottom-4 right-4 z-30 inline-flex items-center gap-2 rounded-full bg-mist-950 px-4 py-2 text-xs font-medium text-mist-100 shadow-lg hover:bg-mist-800"
    >
      ← Old movie page
    </.link>
    """
  end

  defp movie_slug_or_id(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp movie_slug_or_id(%{id: id}), do: id

  # ─── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- HERO — modeled on V1: full-bleed backdrop with bottom-dark gradient,
         white text overlay. No mask-image, no fade-to-light tricks. The hero
         ends at a clean horizontal edge; mist-100 page bg starts immediately
         below. Breadcrumb floats over the backdrop (top-left) so it doesn't
         add a row between the sticky top nav and the hero. --%>
    <section class="relative bg-mist-950">
      <div :if={@movie.backdrop_path} class="absolute inset-0 overflow-hidden">
        <img
          src={tmdb_url(@movie.backdrop_path, "w1280")}
          alt=""
          class="w-full h-full object-cover"
        />
        <%!-- V1's exact gradient: darkest at the bottom (where text sits),
             lightening toward the top so the image breathes. --%>
        <div class="absolute inset-0 bg-gradient-to-t from-black via-black/70 to-black/30"></div>
      </div>
      <div
        :if={!@movie.backdrop_path}
        class="absolute inset-0 bg-gradient-to-br from-mist-900 to-mist-800"
      >
      </div>

      <%!-- BREADCRUMB — floats over the hero backdrop, top-left --%>
      <div class="absolute top-3 left-0 right-0 z-10 mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10">
        <a
          href={~p"/movies"}
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-black/30 backdrop-blur-sm text-[11.5px] text-white/85 hover:text-white hover:bg-black/40 no-underline"
        >
          ← All movies
        </a>
      </div>

      <div class="relative mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-12 lg:pt-16 pb-12 lg:pb-16">
        <div class="flex flex-col lg:flex-row gap-8 lg:gap-10">
          <%!-- Poster --%>
          <div class="shrink-0 w-40 sm:w-48 lg:w-60 mx-auto lg:mx-0">
            <img
              :if={@movie.poster_path}
              src={tmdb_url(@movie.poster_path, "w500")}
              alt={"#{@movie.title} poster"}
              class="w-full rounded-lg shadow-2xl aspect-[2/3] object-cover"
            />
            <div
              :if={!@movie.poster_path}
              class="w-full aspect-[2/3] rounded-lg bg-mist-800 grid place-items-center text-mist-300 text-[12px]"
            >
              No poster
            </div>
          </div>

          <%!-- Title block --%>
          <div class="flex-1 min-w-0 text-white">
            <div class="text-[12px] font-semibold text-white/70 tracking-[.06em] uppercase mb-3">
              {year_of(@movie.release_date)}
              <span :if={@movie.runtime}> ·           {format_runtime(@movie.runtime)}</span>
              <span :if={content_rating(@movie)}> ·           {content_rating(@movie)}</span>
              <span
                :if={disparity_label(@disparity_data[:disparity_category])}
                class="ml-3 text-amber-300 font-display italic normal-case tracking-normal"
              >
                {disparity_label(@disparity_data[:disparity_category])}
              </span>
            </div>

            <h1 class="font-display italic text-[44px] sm:text-[64px] lg:text-[80px] tracking-[-.02em] text-balance text-white leading-[0.95]">
              {@movie.title}
            </h1>

            <p
              :if={@movie.tagline}
              class="mt-3 font-display italic text-[18px] lg:text-[22px] text-white/80 max-w-2xl"
            >
              "{@movie.tagline}"
            </p>

            <%!-- Ratings strip — V1 hero_ratings_row inspired --%>
            <div class="mt-5 flex items-center gap-x-6 gap-y-2 flex-wrap text-white">
              <span :if={r = rating_value(@ratings, "imdb")} class="flex items-baseline gap-1.5">
                <span class="text-[10.5px] font-semibold tracking-[.06em] uppercase text-white/60">
                  IMDb
                </span>
                <span class="text-[15px] font-semibold tabular-nums">{Float.round(r.value, 1)}</span>
              </span>
              <span :if={r = rating_value(@ratings, "tmdb")} class="flex items-baseline gap-1.5">
                <span class="text-[10.5px] font-semibold tracking-[.06em] uppercase text-white/60">
                  TMDb
                </span>
                <span class="text-[15px] font-semibold tabular-nums">{Float.round(r.value, 1)}</span>
              </span>
              <span
                :if={r = rating_value(@ratings, "rotten_tomatoes", "tomatometer")}
                class="flex items-baseline gap-1.5"
              >
                <span class="text-[10.5px] font-semibold tracking-[.06em] uppercase text-white/60">
                  RT
                </span>
                <span class="text-[15px] font-semibold tabular-nums">{round(r.value)}%</span>
              </span>
              <span
                :if={r = rating_value(@ratings, "metacritic", "metascore")}
                class="flex items-baseline gap-1.5"
              >
                <span class="text-[10.5px] font-semibold tracking-[.06em] uppercase text-white/60">
                  Meta
                </span>
                <span class="text-[15px] font-semibold tabular-nums">{round(r.value)}</span>
              </span>
            </div>

            <%!-- Synopsis (in hero, white text) --%>
            <%= if @movie.overview && @movie.overview != "" do %>
              <% {short, has_more} = truncate_words(@movie.overview, 60) %>
              <p class="mt-5 text-[15px] leading-[1.65] text-white/85 max-w-3xl">
                <%= if @overview_expanded || !has_more do %>
                  {@movie.overview}
                <% else %>
                  {short}…
                <% end %>
                <button
                  :if={has_more}
                  type="button"
                  phx-click="toggle_overview"
                  class="ml-1 text-blue-300 hover:text-blue-200 text-[13px]"
                >
                  {if @overview_expanded, do: "Show less", else: "Show more"}
                </button>
              </p>
            <% end %>

            <%!-- Directed by + Starring — avatar pile + inline names --%>
            <div :if={@directors != [] || @cast != []} class="mt-5 space-y-2.5">
              <div :if={@directors != []} class="flex items-center gap-2.5 flex-wrap">
                <span class="text-[10px] font-semibold text-white/55 tracking-[.06em] uppercase shrink-0">
                  Directed by
                </span>
                <div class="flex -space-x-2 shrink-0">
                  <a
                    :for={d <- @directors}
                    href={"/people-v2/#{d.person.slug || d.person.id}"}
                    title={d.person.name}
                    class="block no-underline"
                  >
                    <img
                      :if={d.person.profile_path}
                      src={tmdb_url(d.person.profile_path, "w185")}
                      alt={d.person.name}
                      class="w-7 h-7 rounded-full border-2 border-mist-950 object-cover bg-mist-800"
                    />
                    <div
                      :if={!d.person.profile_path}
                      class="w-7 h-7 rounded-full border-2 border-mist-950 bg-white/15 grid place-items-center text-[10px] text-white/70"
                    >
                      {String.first(d.person.name)}
                    </div>
                  </a>
                </div>
                <div class="text-[13.5px] text-white/85 min-w-0">
                  <%= for {d, idx} <- Enum.with_index(@directors) do %>
                    {if idx > 0, do: ", "}<a
                      href={"/people-v2/#{d.person.slug || d.person.id}"}
                      class="text-white/85 hover:text-white no-underline"
                    >{d.person.name}</a>
                  <% end %>
                </div>
              </div>

              <% top_cast = Enum.take(@cast, 5) %>
              <div :if={top_cast != []} class="flex items-center gap-2.5 flex-wrap">
                <span class="text-[10px] font-semibold text-white/55 tracking-[.06em] uppercase shrink-0">
                  Starring
                </span>
                <div class="flex -space-x-2 shrink-0">
                  <a
                    :for={c <- top_cast}
                    href={"/people-v2/#{c.person.slug || c.person.id}"}
                    title={c.person.name}
                    class="block no-underline"
                  >
                    <img
                      :if={c.person.profile_path}
                      src={tmdb_url(c.person.profile_path, "w185")}
                      alt={c.person.name}
                      class="w-7 h-7 rounded-full border-2 border-mist-950 object-cover bg-mist-800"
                    />
                    <div
                      :if={!c.person.profile_path}
                      class="w-7 h-7 rounded-full border-2 border-mist-950 bg-white/15 grid place-items-center text-[10px] text-white/70"
                    >
                      {String.first(c.person.name)}
                    </div>
                  </a>
                </div>
                <div class="text-[13.5px] text-white/85 min-w-0">
                  <%= for {c, idx} <- Enum.with_index(top_cast) do %>
                    {if idx > 0, do: ", "}<a
                      href={"/people-v2/#{c.person.slug || c.person.id}"}
                      class="text-white/85 hover:text-white no-underline"
                    >{c.person.name}</a>
                  <% end %>
                  <a
                    :if={length(@cast) > 5}
                    href="#cast"
                    class="ml-1 text-blue-300 hover:text-blue-200 no-underline"
                  >
                    +{length(@cast) - 5} more
                  </a>
                </div>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="mt-6 flex items-center gap-3 flex-wrap">
              <a
                :for={video <- Enum.take(@videos, 1)}
                href={"https://www.youtube.com/watch?v=#{video.key}"}
                target="_blank"
                rel="noopener"
                class="inline-flex items-center gap-2 rounded-full bg-white px-4 py-2 text-sm font-semibold text-mist-950 hover:bg-mist-100"
              >
                ▶ Watch trailer
              </a>
            </div>
          </div>
        </div>
      </div>
    </section>

    <main class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 py-12 lg:py-16">
      <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_180px] lg:gap-12 lg:items-start">
        <div class="space-y-12 lg:space-y-16 min-w-0">
          <%!-- CRI SCORE PANEL --%>
          <section id="score">
            <NeutralV2Components.n_score_panel
              scores={@scores}
              disparity_label={disparity_label(@disparity_data[:disparity_category])}
              disparity_summary={disparity_summary(@disparity_data, @scores)}
            />
            <div class="mt-3 flex items-center gap-3 flex-wrap">
              <button
                type="button"
                phx-click="show_score_modal"
                class="text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
              >
                How is this score calculated?
              </button>
              <a
                href={~p"/movies/discover"}
                class="text-[12.5px] font-semibold text-mist-700 underline decoration-mist-950/10 underline-offset-4"
              >
                Tune weights →
              </a>
            </div>
          </section>

          <%!-- WHERE IT LIVES — 4-up summary card --%>
          <% wins = count_award_wins(@festival_noms) %>
          <% noms = count_award_nominations(@festival_noms) %>
          <% canon_count = length(@canon_lists || []) %>
          <% reunions = (@key_collabs || %{})[:total_reunions] || 0 %>
          <% top_win = top_festival_win(@festival_noms) %>
          <% top_pair = top_collab_pairing(@key_collabs || %{}) %>
          <section
            :if={wins + noms > 0 || canon_count > 0 || reunions > 0 || top_win}
            class="-mt-4"
          >
            <h2 class="font-display italic text-[24px] tracking-[-.01em] text-mist-950 mb-4">
              Where it lives
            </h2>
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
              <a
                :if={wins + noms > 0}
                href="#awards"
                class="block bg-mist-50 border border-mist-950/10 rounded-lg p-5 no-underline text-inherit hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] transition-shadow"
              >
                <div class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
                  Awards
                </div>
                <div class="font-display italic text-[28px] text-mist-950 leading-none mb-1 tabular-nums">
                  {wins} {pluralize_str(wins, "win")}
                </div>
                <div class="text-[12px] text-mist-700 tabular-nums mb-3">
                  {noms} {pluralize_str(noms, "nomination")}
                </div>
                <div
                  :if={t = top_org_names(@festival_noms)}
                  class="text-[11.5px] text-mist-500 truncate"
                >
                  {t}
                </div>
                <div class="mt-3 text-[11.5px] font-semibold text-mist-900">See all →</div>
              </a>

              <a
                :if={canon_count > 0}
                href="#lists"
                class="block bg-mist-50 border border-mist-950/10 rounded-lg p-5 no-underline text-inherit hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] transition-shadow"
              >
                <div class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
                  Lists
                </div>
                <div class="font-display italic text-[28px] text-mist-950 leading-none mb-1 tabular-nums">
                  on {canon_count}
                </div>
                <div class="text-[12px] text-mist-700 mb-3">
                  canonical {pluralize_str(canon_count, "list")}
                </div>
                <div
                  :if={t = top_canon_authorities(@canon_lists)}
                  class="text-[11.5px] text-mist-500 truncate"
                >
                  {t}
                </div>
                <div class="mt-3 text-[11.5px] font-semibold text-mist-900">See all →</div>
              </a>

              <a
                :if={top_win}
                href="#awards"
                class="block bg-mist-50 border border-mist-950/10 rounded-lg p-5 no-underline text-inherit hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] transition-shadow"
              >
                <div class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
                  Festivals
                </div>
                <div class="font-display italic text-[20px] text-mist-950 leading-tight mb-1">
                  {top_win.org}
                  <span :if={top_win.year} class="text-mist-500 tabular-nums">{top_win.year}</span>
                </div>
                <div :if={top_win.category} class="text-[12px] text-mist-700 mb-3 truncate">
                  {top_win.category}
                </div>
                <div class="mt-3 text-[11.5px] font-semibold text-mist-900">See all →</div>
              </a>

              <a
                :if={reunions > 0}
                href="#collaborations"
                class="block bg-mist-50 border border-mist-950/10 rounded-lg p-5 no-underline text-inherit hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] transition-shadow"
              >
                <div class="text-[10.5px] font-semibold text-mist-500 tracking-[.06em] uppercase mb-3">
                  Collaborations
                </div>
                <div class="font-display italic text-[28px] text-mist-950 leading-none mb-1 tabular-nums">
                  {reunions} {pluralize_str(reunions, "reunion")}
                </div>
                <div class="text-[12px] text-mist-700 mb-3">in this film</div>
                <div :if={top_pair} class="text-[11.5px] text-mist-500 truncate">{top_pair}</div>
                <div class="mt-3 text-[11.5px] font-semibold text-mist-900">See all →</div>
              </a>
            </div>
          </section>

          <%!-- KEYWORDS --%>
          <section :if={@keywords != []}>
            <h2 class="font-display italic text-[24px] tracking-[-.01em] text-mist-950 mb-4">
              Themes & keywords
            </h2>
            <div class="flex flex-wrap gap-2">
              <span
                :for={kw <- @keywords}
                class="inline-flex items-center px-3 py-1 rounded-full bg-mist-950/[0.025] border border-mist-950/10 text-[13px] text-mist-700"
              >
                {kw.name}
              </span>
            </div>
          </section>

          <%!-- CAST --%>
          <section :if={@cast != []} id="cast">
            <div class="flex items-end justify-between mb-6 flex-wrap gap-3">
              <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950">
                Cast
                <span class="text-mist-500 text-[14px] font-sans not-italic tabular-nums ml-2">
                  {length(@cast)}
                </span>
              </h2>
              <button
                :if={length(@cast) > 12}
                type="button"
                phx-click="toggle_full_cast"
                class="text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
              >
                {if @show_full_cast, do: "Show top 12 only", else: "Show all #{length(@cast)}"}
              </button>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1">
              <NeutralV2Components.n_credit_row
                :for={c <- if @show_full_cast, do: @cast, else: Enum.take(@cast, 12)}
                credit={cast_credit_shape(c)}
              />
            </div>
          </section>

          <%!-- CREW (grouped by department) --%>
          <% crew_groups = crew_by_department(@crew) %>
          <% visible_crew_groups =
            if @show_full_crew, do: crew_groups, else: Enum.take(crew_groups, 3) %>
          <section :if={crew_groups != []} id="crew">
            <div class="flex items-end justify-between mb-6 flex-wrap gap-3">
              <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950">
                Crew
                <span class="text-mist-500 text-[14px] font-sans not-italic tabular-nums ml-2">
                  {length(@crew)}
                </span>
              </h2>
              <button
                :if={length(crew_groups) > 3}
                type="button"
                phx-click="toggle_full_crew"
                class="text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
              >
                {if @show_full_crew,
                  do: "Show top 3 departments",
                  else: "Show all #{length(crew_groups)} departments"}
              </button>
            </div>
            <div class="space-y-7">
              <div :for={{dept, members} <- visible_crew_groups}>
                <div class="font-display italic text-[15px] text-mist-500 tracking-[-.005em] mb-3">
                  {dept}
                  <span class="text-mist-500/60 text-[12px] font-sans not-italic tabular-nums ml-1">
                    {length(members)}
                  </span>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1">
                  <NeutralV2Components.n_credit_row
                    :for={m <- members}
                    credit={crew_credit_shape(m)}
                    variant="crew"
                  />
                </div>
              </div>
            </div>
          </section>

          <%!-- AWARDS BY ORG --%>
          <section :if={@festival_noms != [] && is_list(@festival_noms)} id="awards">
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              Awards & recognition
              <span class="text-mist-500 text-[14px] font-sans not-italic tabular-nums ml-2">
                {count_award_wins(@festival_noms)} {pluralize_str(
                  count_award_wins(@festival_noms),
                  "win"
                )} · {count_award_nominations(@festival_noms)} {pluralize_str(
                  count_award_nominations(@festival_noms),
                  "nomination"
                )}
              </span>
            </h2>
            <div :if={a = omdb_awards(@movie)} class="mb-6 text-[13.5px] text-mist-700 italic">
              {a}
            </div>
            <div class="space-y-4">
              <NeutralV2Components.n_award_org_block
                :for={
                  org <-
                    Enum.sort_by(
                      @festival_noms,
                      &(-Enum.count(&1[:nominations] || [], fn n -> n[:won] end))
                    )
                }
                org_name={org[:organization_name] || "Awards"}
                total_wins={Enum.count(org[:nominations] || [], & &1[:won])}
                total_nominations={org[:total_nominations] || length(org[:nominations] || [])}
                nominations={render_nominations(org[:nominations] || [])}
              />
            </div>
          </section>

          <%!-- CANONICAL LISTS --%>
          <section :if={@canon_lists != []} id="lists">
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              On canonical lists
            </h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              <div
                :for={l <- @canon_lists}
                class="bg-mist-50 border border-mist-950/10 rounded-lg p-5"
              >
                <div class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase">
                  {l.list_authority || "List"}
                  <span :if={l.list_year}> ·           {l.list_year}</span>
                </div>
                <div class="mt-1 font-display italic text-[18px] text-mist-950 leading-tight">
                  {l.list_name}
                </div>
                <div class="mt-3 flex items-baseline gap-3 text-[12px] text-mist-700 tabular-nums">
                  <span :if={l.rank}>
                    <b class="text-mist-950 font-semibold">#{l.rank}</b>
                  </span>
                  <span :if={l.prestige_score}>
                    prestige <b class="text-mist-950 font-semibold">{l.prestige_score}</b>
                  </span>
                  <span :if={l[:award_category]} class="text-mist-500">
                    {l.award_category}
                  </span>
                </div>
              </div>
            </div>
          </section>

          <%!-- NOTABLE COLLABORATIONS --%>
          <section
            :if={
              (@key_collabs[:director_actor_reunions] || []) != [] ||
                (@key_collabs[:actor_partnerships] || []) != []
            }
            id="collaborations"
          >
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              Notable collaborations
            </h2>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
              <NeutralV2Components.n_collaboration_card
                :for={c <- @key_collabs[:director_actor_reunions] || []}
                collaboration={collab_shape(c, @timeline_index)}
              />
              <NeutralV2Components.n_collaboration_card
                :for={c <- @key_collabs[:actor_partnerships] || []}
                collaboration={collab_shape(c, @timeline_index)}
              />
            </div>
            <a
              href={~p"/six-degrees"}
              class="mt-4 inline-flex items-center gap-2 text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
            >
              Explore the full collaboration network →
            </a>
          </section>

          <%!-- MORE FROM DIRECTOR --%>
          <section :if={@director_other_films != [] && @directors != []} id="director">
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              More from {director_names(@directors)}
            </h2>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-[18px]">
              <NeutralV2Components.n_film_card
                :for={m <- @director_other_films}
                film={film_card_shape(m)}
              />
            </div>
          </section>

          <%!-- SIMILAR FILMS --%>
          <section :if={@related_movies != []} id="similar">
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              Similar films
            </h2>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-[18px]">
              <NeutralV2Components.n_film_card
                :for={r <- Enum.take(@related_movies, 12)}
                film={related_card_shape(r)}
              />
            </div>
          </section>

          <%!-- MEDIA --%>
          <section :if={@videos != []} id="media">
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              Media
            </h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-[18px]">
              <a
                :for={v <- Enum.take(@videos, 9)}
                href={"https://www.youtube.com/watch?v=#{v.key}"}
                target="_blank"
                rel="noopener"
                class="block bg-mist-50 border border-mist-950/10 rounded-lg overflow-hidden hover:shadow-[0_4px_14px_rgba(20,18,15,.06)] transition-shadow no-underline text-inherit"
              >
                <div class="relative aspect-video bg-mist-200">
                  <img
                    src={"https://img.youtube.com/vi/#{v.key}/hqdefault.jpg"}
                    alt={v.name}
                    class="absolute inset-0 w-full h-full object-cover"
                  />
                  <div class="absolute inset-0 grid place-items-center">
                    <div class="w-12 h-12 rounded-full bg-black/60 grid place-items-center text-white text-[20px]">
                      ▶
                    </div>
                  </div>
                </div>
                <div class="px-4 py-3">
                  <div class="text-[13px] font-semibold text-mist-950 truncate">{v.name}</div>
                  <div class="text-[11.5px] text-mist-500">{v.type}</div>
                </div>
              </a>
            </div>
          </section>

          <%!-- RELEASE DATES BY COUNTRY --%>
          <% all_releases = prioritize_releases(@release_dates || []) %>
          <% visible_releases =
            if @show_all_releases, do: all_releases, else: Enum.take(all_releases, 8) %>
          <section :if={all_releases != []} id="releases">
            <div class="flex items-end justify-between mb-6 flex-wrap gap-3">
              <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950">
                Release information
                <span class="text-mist-500 text-[14px] font-sans not-italic tabular-nums ml-2">
                  {length(all_releases)}
                </span>
              </h2>
              <button
                :if={length(all_releases) > 8}
                type="button"
                phx-click="toggle_all_releases"
                class="text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
              >
                {if @show_all_releases, do: "Show top 8", else: "Show all #{length(all_releases)}"}
              </button>
            </div>
            <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
              <div
                :for={r <- visible_releases}
                class="bg-mist-50 border border-mist-950/10 rounded-lg p-4"
              >
                <div class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase">
                  {r.country_code}
                </div>
                <div class="mt-1 text-[13px] text-mist-950 tabular-nums">
                  <%= if r.release_date do %>
                    {Calendar.strftime(r.release_date, "%Y-%m-%d")}
                  <% else %>
                    —
                  <% end %>
                </div>
                <span
                  :if={r.certification}
                  class="inline-block mt-2 px-2 py-[2px] rounded text-[10.5px] font-semibold bg-mist-100 text-mist-700 border border-mist-950/10"
                >
                  {r.certification}
                </span>
              </div>
            </div>
          </section>

          <%!-- TECHNICAL DETAILS --%>
          <section id="details">
            <h2 class="font-display italic text-[24px] tracking-[-.01em] text-mist-950 mb-6">
              Technical details
            </h2>
            <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-3 text-[13px]">
              <div
                :if={format_money(Map.get(@movie, :budget))}
                class="flex justify-between border-b border-mist-950/10 pb-2"
              >
                <dt class="text-mist-500">Budget</dt>
                <dd class="text-mist-950 tabular-nums">{format_money(Map.get(@movie, :budget))}</dd>
              </div>
              <div
                :if={format_money(Map.get(@movie, :revenue))}
                class="flex justify-between border-b border-mist-950/10 pb-2"
              >
                <dt class="text-mist-500">Revenue</dt>
                <dd class="text-mist-950 tabular-nums">{format_money(Map.get(@movie, :revenue))}</dd>
              </div>
              <div
                :if={@movie.original_language}
                class="flex justify-between border-b border-mist-950/10 pb-2"
              >
                <dt class="text-mist-500">Language</dt>
                <dd class="text-mist-950">{@movie.original_language}</dd>
              </div>
              <div
                :if={@production_companies != []}
                class="flex justify-between border-b border-mist-950/10 pb-2"
              >
                <dt class="text-mist-500">Production</dt>
                <dd class="text-mist-950 text-right">
                  {@production_companies
                  |> Enum.take(2)
                  |> Enum.map(&production_company_name/1)
                  |> Enum.join(" · ")}
                </dd>
              </div>
              <div class="flex justify-between border-b border-mist-950/10 pb-2">
                <dt class="text-mist-500">TMDb / IMDb</dt>
                <dd class="text-mist-950 tabular-nums">
                  {@movie.tmdb_id}<span :if={@movie.imdb_id}> · {@movie.imdb_id}</span>
                </dd>
              </div>
            </dl>
          </section>
        </div>
        <aside class="hidden lg:block">
          <NeutralV2Components.n_section_nav sections={section_nav_items(assigns)} />
        </aside>
      </div>
    </main>

    <%!-- Score modal --%>
    <div
      :if={@show_score_modal}
      phx-click="hide_score_modal"
      phx-window-keydown="hide_score_modal"
      phx-key="escape"
      class="fixed inset-0 z-50 grid place-items-center bg-black/40 px-6"
    >
      <div
        phx-click="stop_propagation"
        class="bg-mist-50 rounded-[10px] border border-mist-950/10 max-w-2xl w-full p-8 max-h-[90vh] overflow-y-auto"
      >
        <div class="flex items-center justify-between mb-4">
          <h3 class="font-display italic text-[28px] tracking-[-.01em] text-mist-950">
            How the score works
          </h3>
          <button
            type="button"
            phx-click="hide_score_modal"
            class="text-mist-500 hover:text-mist-950 text-[20px]"
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <div class="space-y-4 text-[13.5px] text-mist-900 leading-[1.65]">
          <p>
            Cinegraph's score blends six independent lenses, each measuring a different
            dimension of how a film lives in the world.
          </p>
          <ul class="space-y-2 list-disc pl-5">
            <li><b>The Mob</b> (10%) — audience consensus from IMDb &amp; TMDb user ratings.</li>
            <li><b>The Critics</b> (10%) — Rotten Tomatoes Tomatometer + Metacritic Metascore.</li>
            <li>
              <b>The Insiders</b>
              (20%) — festival wins &amp; nominations across Academy, Cannes, Venice, BAFTA, Sundance, etc.
            </li>
            <li>
              <b>Time Machine</b>
              (20%) — appearance on canonical lists (Criterion, AFI, BFI Sight &amp; Sound, etc.).
            </li>
            <li><b>The Auteurs</b> (20%) — quality scores of the director, cast, and crew.</li>
            <li><b>Box Office</b> (20%) — revenue (60%) + ROI ratio (40%).</li>
          </ul>
          <p>
            The overall score is the weighted sum. Custom weights can be tuned in the <a
              href={~p"/movies/discover"}
              class="underline decoration-mist-950/15 underline-offset-4"
            >discovery tuner</a>.
          </p>
        </div>
      </div>
    </div>

    <.legacy_escape_pill movie={@movie} />
    """
  end
end
