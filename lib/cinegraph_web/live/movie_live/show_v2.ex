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

  import CinegraphWeb.MovieLive.ShowV2.Presentation
  import CinegraphWeb.SEOHelpers

  alias Cinegraph.VideoClerk
  alias CinegraphWeb.Components.ListAppearanceCard
  alias CinegraphWeb.MovieLive.ShowV2.Data
  alias CinegraphWeb.MovieLive.ShowV2.ProductionDetails
  alias CinegraphWeb.NeutralV2Components
  alias CinegraphWeb.MovieLive.ShowV2Availability

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    browser_region =
      if connected?(socket) do
        socket |> get_connect_params() |> Data.browser_region()
      end

    {:ok,
     socket
     |> assign(:active_nav, "Movies")
     |> assign(:availability_browser_region, browser_region)
     |> assign(:show_score_modal, false)
     |> assign(:overview_expanded, false)
     |> assign(:show_full_cast, false)
     |> assign(:show_full_crew, false)
     |> assign(:show_all_releases, false)
     |> assign(:video_clerk_recommendation, empty_video_clerk_recommendation())}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    case Data.load_movie(slug) do
      {:ok, data} ->
        in_theaters = Cinegraph.Movies.currently_in_theaters?(data.movie)

        {:noreply,
         socket
         |> assign(data)
         |> assign(:in_theaters, in_theaters)
         |> assign(
           :wombie_url,
           if(in_theaters,
             do: CinegraphWeb.Helpers.WombieLinks.showtimes_url(data.movie, "movie_show"),
             else: nil
           )
         )
         |> assign(:video_clerk_recommendation, empty_video_clerk_recommendation())
         |> maybe_start_video_clerk_recommendation(data.movie.id)
         |> assign_availability(data.movie, socket.assigns[:availability_browser_region])
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

  def handle_event("change_availability_region", %{"region" => region}, socket) do
    {:noreply, assign_availability(socket, socket.assigns.movie, region)}
  end

  def handle_event("stop_propagation", _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:video_clerk_recommendation, {:ok, recommendation}, socket) do
    {:noreply, assign(socket, :video_clerk_recommendation, recommendation)}
  end

  def handle_async(:video_clerk_recommendation, {:exit, reason}, socket) do
    Logger.warning("Video Clerk recommendation failed: #{inspect(reason)}")
    {:noreply, assign(socket, :video_clerk_recommendation, empty_video_clerk_recommendation())}
  end

  defp assign_availability(socket, movie, region),
    do: ShowV2Availability.assign_availability(socket, movie, region)

  defp maybe_start_video_clerk_recommendation(socket, movie_id) do
    if connected?(socket) do
      start_async(socket, :video_clerk_recommendation, fn ->
        VideoClerk.recommend([movie_id], limit: 3)
      end)
    else
      socket
    end
  end

  defp empty_video_clerk_recommendation do
    %{primary: nil, alternates: [], seed_movies: [], route_labels: [], evidence_summary: []}
  end

  defp section_nav_items(assigns) do
    has_collabs = (assigns[:key_collabs][:notable_collaborations] || []) != []

    [
      %{id: "score", label: "Score", present?: true},
      %{id: "watch", label: "Watch", present?: true},
      %{id: "cast", label: "Cast", present?: assigns[:cast] != []},
      %{id: "crew", label: "Crew", present?: assigns[:crew] != []},
      %{id: "studios", label: "Studios", present?: assigns[:production_companies] != []},
      %{id: "awards", label: "Awards", present?: assigns[:festival_noms] != []},
      %{id: "lists", label: "Lists", present?: assigns[:canon_lists] != []},
      %{id: "collaborations", label: "Collabs", present?: has_collabs},
      %{
        id: "video-clerk",
        label: "Clerk",
        present?: not is_nil(assigns[:video_clerk_recommendation][:primary])
      },
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
              <span :if={@movie.runtime}>{" · #{format_runtime(@movie.runtime)}"}</span>
              <span :if={content_rating(@metrics)}>{" · #{content_rating(@metrics)}"}</span>
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

            <%!-- Directed by + Starring + Studios — compact hero metadata rows --%>
            <div
              :if={@directors != [] || @cast != [] || @production_companies != []}
              class="mt-5 space-y-2.5"
            >
              <ProductionDetails.hero_people directors={@directors} cast={@cast} />
              <ProductionDetails.hero_production_companies production_companies={
                @production_companies
              } />
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

    <%!-- In Theaters Now — absent entirely when not currently playing --%>
    <div :if={@in_theaters} class="border-b border-mist-950/8 bg-white">
      <div class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 py-4 flex items-center gap-4">
        <div class="w-[3px] self-stretch rounded-full bg-indigo-500 shrink-0"></div>
        <div class="flex-1 min-w-0">
          <p class="text-[12px] font-semibold tracking-[.06em] uppercase text-indigo-600 mb-0.5">
            Currently in theaters
          </p>
          <p class="text-[13px] text-mist-600">
            Confirmed playing now across TMDB regions
          </p>
        </div>
        <a
          href={@wombie_url}
          target="_blank"
          rel="noopener noreferrer"
          class="shrink-0 inline-flex items-center gap-1.5 rounded-[6px] border border-indigo-200 bg-indigo-50 px-3 py-1.5 text-[13px] font-semibold text-indigo-700 hover:bg-indigo-100 transition-colors"
        >
          🎬 Find Showtimes on Wombie
        </a>
      </div>
    </div>

    <main class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 py-12 lg:py-16">
      <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_180px] lg:gap-12 lg:items-start">
        <div class="space-y-12 lg:space-y-16 min-w-0">
          <%!-- CRI SCORE PANEL --%>
          <section id="score">
            <NeutralV2Components.n_score_panel
              scores={@scores}
              scoreability={@scoreability}
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

          <%!-- WHERE TO WATCH --%>
          <ShowV2Availability.where_to_watch
            availability_freshness={@availability_freshness}
            availability_region_label={@availability_region_label}
            availability_refresh_queued={@availability_refresh_queued}
            availability_regions={@availability_regions}
            availability_region_options={@availability_region_options}
            availability_region={@availability_region}
            availability_groups={@availability_groups}
          />

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
          <section :if={@cast != []} id="cast" class="scroll-mt-24">
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

          <%!-- STUDIOS --%>
          <section :if={@production_companies != []} id="studios" class="scroll-mt-24">
            <ProductionDetails.studios_section production_companies={@production_companies} />
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
            <div :if={a = omdb_awards(@metrics)} class="mb-6 text-[13.5px] text-mist-700 italic">
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
              <span class="text-mist-500 text-[14px] font-sans not-italic tabular-nums ml-2">
                {length(@canon_lists)} {pluralize_str(length(@canon_lists), "appearance")}
              </span>
            </h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5">
              <ListAppearanceCard.card :for={l <- @canon_lists} list={l} />
            </div>
          </section>

          <%!-- NOTABLE COLLABORATIONS --%>
          <section
            :if={(@key_collabs[:notable_collaborations] || []) != []}
            id="collaborations"
          >
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 mb-6">
              Notable collaborations
            </h2>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
              <NeutralV2Components.n_collaboration_card
                :for={c <- @key_collabs[:notable_collaborations] || []}
                collaboration={collab_shape(c)}
              />
            </div>
            <a
              href={~p"/six-degrees"}
              class="mt-4 inline-flex items-center gap-2 text-[12.5px] font-semibold text-mist-900 underline decoration-mist-950/15 underline-offset-4"
            >
              Explore the full collaboration network →
            </a>
          </section>

          <%!-- VIDEO CLERK --%>
          <section :if={@video_clerk_recommendation[:primary]} id="video-clerk">
            <div class="mb-6 flex flex-wrap items-end justify-between gap-3">
              <div>
                <div class="text-[11px] font-semibold uppercase tracking-[.08em] text-mist-500">
                  Video Clerk
                </div>
                <h2 class="mt-1 font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950">
                  Ask for the next strange right thing
                </h2>
              </div>
              <.link
                navigate={~p"/video-clerk?#{%{seed: movie_slug_or_id(@movie)}}"}
                class="inline-flex rounded-md bg-mist-950 px-3 py-2 text-[12px] font-semibold text-mist-50 hover:bg-mist-800"
              >
                Ask the Video Clerk
              </.link>
            </div>
            <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
              <a
                :for={
                  rec <-
                    [@video_clerk_recommendation.primary | @video_clerk_recommendation.alternates]
                    |> Enum.reject(&is_nil/1)
                    |> Enum.take(3)
                }
                href={rec.href}
                class="rounded-lg border border-mist-950/10 bg-mist-50 p-4 no-underline hover:bg-white"
              >
                <div class="text-[11px] font-semibold uppercase tracking-[.08em] text-mist-500">
                  {Enum.join(Enum.take(rec.route_labels, 2), " / ")}
                </div>
                <div class="mt-2 flex gap-3">
                  <img
                    :if={rec.poster_url}
                    src={rec.poster_url}
                    alt=""
                    class="h-24 w-16 rounded-[4px] object-cover"
                  />
                  <div class="min-w-0">
                    <div class="text-[14px] font-semibold leading-snug text-mist-950">
                      {rec.title}
                    </div>
                    <div class="mt-1 text-[12px] text-mist-500">{rec.year}</div>
                    <p class="mt-2 line-clamp-3 text-[12px] leading-relaxed text-mist-700">
                      {rec.reason}
                    </p>
                  </div>
                </div>
              </a>
            </div>
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
                <ProductionDetails.production_details production_companies={@production_companies} />
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
