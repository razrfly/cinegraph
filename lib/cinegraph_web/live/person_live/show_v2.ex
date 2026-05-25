defmodule CinegraphWeb.PersonLive.ShowV2 do
  @moduledoc """
  Person show page on the V2 design system. Mounts at `/people/:slug_or_id`.

  See issue #757. KEEP features at parity with `PersonLive.Show`, plus 3 NEW:

  1. Filmography role-chip filter (replaces V1's tab bar)
  2. Score sparkline in Career-at-a-Glance "Avg Score" tile
  3. Awards by year (org-grouped when possible)
  """
  use CinegraphWeb, :live_view

  import CinegraphWeb.SEOHelpers
  import CinegraphWeb.PersonHelpers, only: [person_slug_or_id: 1]

  alias Cinegraph.People
  alias Cinegraph.Collaborations
  alias Cinegraph.Festivals
  alias CinegraphWeb.Helpers.UrlHelpers
  alias CinegraphWeb.NeutralV2Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "People")
     |> assign(:bio_expanded, false)
     |> assign(:six_degrees_path, nil)
     |> assign(:six_degrees_loading, false)}
  end

  @impl true
  def handle_params(%{"slug_or_id" => identifier} = params, _uri, socket) do
    case People.get_person_with_credits_by_id_or_slug(identifier) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Person not found")
         |> push_navigate(to: ~p"/people")}

      person ->
        if numeric?(identifier) && slug_present?(person.slug) do
          {:noreply, push_navigate(socket, to: "/people/#{person_slug_or_id(person)}")}
        else
          {:noreply, load_person_data(socket, person, params)}
        end
    end
  end

  defp load_person_data(socket, person, params) do
    career = People.get_career_stats(person.id)
    award_stats = Festivals.get_person_nomination_stats(person.id)
    collab_trends = Collaborations.get_person_collaboration_trends(person.id)
    frequent_collabs = Collaborations.get_frequent_collaborators(person)

    role_filter = params["role"] || "all"

    socket
    |> assign(:person, person)
    |> assign(:career, career)
    |> assign(:award_stats, award_stats)
    |> assign(:collab_trends, collab_trends)
    |> assign(:frequent_collabs, frequent_collabs)
    |> assign(:role_filter, role_filter)
    |> assign(:params, params)
    |> assign_person_seo(person)
  end

  @impl true
  def handle_event("toggle_bio", _params, socket) do
    {:noreply, assign(socket, :bio_expanded, !socket.assigns.bio_expanded)}
  end

  def handle_event("set_role", %{"role" => role}, socket) do
    new_params =
      Map.put(socket.assigns.params, "role", role)
      |> Map.reject(fn {_k, v} -> v == "all" or v == "" or is_nil(v) end)

    qs = if new_params == %{}, do: "", else: "?" <> URI.encode_query(new_params)
    {:noreply, push_patch(socket, to: "/people/#{person_slug_or_id(socket.assigns.person)}#{qs}")}
  end

  def handle_event("search_six_degrees", %{"target_person_id" => target_id}, socket)
      when target_id != "" do
    case Integer.parse(target_id) do
      {int_id, ""} ->
        send(self(), {:find_path, int_id})
        {:noreply, assign(socket, :six_degrees_loading, true)}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid target person ID")}
    end
  end

  def handle_event("search_six_degrees", _params, socket), do: {:noreply, socket}

  defp slug_present?(slug), do: is_binary(slug) and slug != ""

  defp person_movies_path(person, "actor"),
    do: "/people/#{person_slug_or_id(person)}/movies/acting"

  defp person_movies_path(person, "director"),
    do: "/people/#{person_slug_or_id(person)}/movies/directing"

  defp person_movies_path(person, _role), do: "/people/#{person_slug_or_id(person)}/movies"

  defp person_movies_cta_label("actor"), do: "Open acting credits"
  defp person_movies_cta_label("director"), do: "Open directed films"
  defp person_movies_cta_label(_role), do: "Open all films"

  @impl true
  def handle_info({:find_path, target_id}, socket) do
    from_id = socket.assigns.person.id

    case Collaborations.PathFinder.find_path_with_movies(from_id, target_id) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:six_degrees_path, path)
         |> assign(:six_degrees_loading, false)}

      {:error, :no_path_found} ->
        {:noreply,
         socket
         |> assign(:six_degrees_path, :no_path)
         |> assign(:six_degrees_loading, false)}
    end
  end

  defp numeric?(s) do
    case Integer.parse(s) do
      {_, ""} -> true
      _ -> false
    end
  end

  # ─── Adapters & helpers ────────────────────────────────────────────

  defp tmdb_url(nil, _), do: nil
  defp tmdb_url("", _), do: nil
  defp tmdb_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp year_of(%Date{year: y}), do: y
  defp year_of(_), do: nil

  defp format_date(nil), do: nil

  defp format_date(%Date{} = d) do
    Calendar.strftime(d, "%b %-d, %Y")
  end

  defp filtered_credits(person, "actor"), do: person.cast_credits || []

  defp filtered_credits(person, "director") do
    (person.crew_credits || []) |> Enum.filter(&(&1.job == "Director"))
  end

  defp filtered_credits(person, "writer") do
    (person.crew_credits || []) |> Enum.filter(&(&1.department == "Writing"))
  end

  defp filtered_credits(person, _all) do
    cast = (person.cast_credits || []) |> Enum.map(&Map.put(&1, :role_type, :cast))
    crew = (person.crew_credits || []) |> Enum.map(&Map.put(&1, :role_type, :crew))
    cast ++ crew
  end

  defp grouped_by_year(credits) do
    credits
    |> Enum.filter(& &1.movie)
    |> Enum.sort_by(fn c -> {-((c.movie.release_date && c.movie.release_date.year) || 0)} end)
    |> Enum.group_by(fn c ->
      case c.movie.release_date do
        %Date{year: y} -> y
        _ -> nil
      end
    end)
    |> Enum.sort_by(fn {y, _} -> -(y || 0) end)
  end

  defp credit_to_filmography_shape(credit) do
    movie = credit.movie

    role =
      cond do
        Map.get(credit, :character) not in [nil, ""] -> credit.character
        Map.get(credit, :job) not in [nil, ""] -> credit.job
        true -> nil
      end

    %{
      title: movie.title,
      role: role,
      year: year_of(movie.release_date),
      poster_url: tmdb_url(movie.poster_path, "w92"),
      score: nil,
      href: UrlHelpers.movie_href(movie.slug, movie.id)
    }
  end

  defp collab_shape(c) do
    p = c.person
    first_year = year_of(c.first_date)
    last_year = year_of(c.latest_date)

    %{
      person_a: nil,
      person_b: p.name,
      avatar_a: nil,
      avatar_b: tmdb_url(p.profile_path, "w185"),
      films_together: c.collaboration_count,
      strength: c.strength,
      year_range:
        cond do
          first_year && last_year && first_year != last_year -> "#{first_year}–#{last_year}"
          last_year -> "#{last_year}"
          true -> nil
        end,
      avg_score: c.avg_rating && Decimal.to_float(c.avg_rating),
      total_revenue: c.total_revenue,
      href: "/people/#{person_slug_or_id(p)}"
    }
  end

  defp known_for_films(person) do
    (person.cast_credits || [])
    |> Enum.filter(& &1.movie)
    |> Enum.sort_by(fn c -> c.cast_order || 999 end)
    |> Enum.take(6)
  end

  defp known_for_film_shape(credit) do
    m = credit.movie

    %{
      id: m.id,
      title: m.title,
      year: year_of(m.release_date),
      score: nil,
      poster_url: tmdb_url(m.poster_path, "w500"),
      href: UrlHelpers.movie_href(m.slug, m.id)
    }
  end

  defp role_options do
    [
      {"all", "All"},
      {"actor", "As actor"},
      {"director", "As director"},
      {"writer", "As writer"}
    ]
  end

  # Score sparkline for career-at-a-glance: takes per-year trends
  # and produces an SVG path.
  defp avg_score_trend(trends) when is_list(trends) and length(trends) > 0 do
    points =
      trends
      |> Enum.sort_by(& &1.year)
      |> Enum.map(fn t ->
        # avg_movie_rating from collaborations is 0–10 already
        case t do
          %{avg_movie_rating: r} when is_struct(r, Decimal) -> Decimal.to_float(r)
          %{avg_movie_rating: r} when is_number(r) -> r
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(points) >= 2, do: points, else: []
  end

  defp avg_score_trend(_), do: []

  defp sparkline_path(points) do
    n = length(points)
    w = 100
    h = 28

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {p, i} ->
      x = i / (n - 1) * w
      y = h - p / 10 * h
      cmd = if i == 0, do: "M", else: "L"
      "#{cmd}#{Float.round(x, 2)} #{Float.round(y, 2)}"
    end)
  end

  defp avg_career_score(person) do
    rated =
      (person.cast_credits || [])
      |> Enum.map(fn c ->
        case c.movie do
          %{tmdb_data: %{"vote_average" => v}} when is_number(v) and v > 0 -> v
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case rated do
      [] -> nil
      list -> Enum.sum(list) / length(list)
    end
  end

  defp years_active(person) do
    dates =
      ((person.cast_credits || []) ++ (person.crew_credits || []))
      |> Enum.map(& &1.movie)
      |> Enum.filter(& &1)
      |> Enum.map(& &1.release_date)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.year)

    case dates do
      [] -> nil
      list -> "#{Enum.min(list)}–#{Enum.max(list)}"
    end
  end

  defp total_revenue(person) do
    (person.cast_credits || [])
    |> Enum.map(fn c ->
      case c.movie do
        %{tmdb_data: %{"revenue" => r}} when is_number(r) and r > 0 -> r
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp format_revenue_money(0), do: nil
  defp format_revenue_money(nil), do: nil

  defp format_revenue_money(n) when is_number(n) and n >= 1_000_000_000,
    do: "$#{Float.round(n / 1_000_000_000, 1)}B"

  defp format_revenue_money(n) when is_number(n) and n >= 1_000_000,
    do: "$#{Float.round(n / 1_000_000, 1)}M"

  defp format_revenue_money(n), do: "$#{n}"

  # ─── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    person = assigns.person
    has_long_bio = person.biography && String.length(person.biography) > 300

    {short_bio, _} =
      if has_long_bio do
        words = String.split(person.biography)
        {words |> Enum.take(60) |> Enum.join(" "), true}
      else
        {person.biography || "", false}
      end

    avg_score = avg_career_score(person)
    trend_points = avg_score_trend(assigns.collab_trends)
    revenue = total_revenue(person)
    yrs = years_active(person)

    assigns =
      assigns
      |> assign(:has_long_bio, has_long_bio)
      |> assign(:short_bio, short_bio)
      |> assign(:avg_score, avg_score)
      |> assign(:trend_points, trend_points)
      |> assign(:revenue, revenue)
      |> assign(:years_active_str, yrs)

    filmography = filtered_credits(person, assigns.role_filter)
    grouped = grouped_by_year(filmography)

    assigns =
      assigns
      |> assign(:filmography_total, length(filmography))
      |> assign(:grouped_filmography, grouped)
      |> assign(:known_for, known_for_films(person))

    ~H"""
    <%!-- HERO --%>
    <section class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pt-8 lg:pt-12 pb-8">
      <div class="flex flex-col lg:flex-row gap-8 lg:gap-10">
        <div class="shrink-0 w-40 sm:w-52 lg:w-60">
          <img
            :if={@person.profile_path}
            src={tmdb_url(@person.profile_path, "w500")}
            alt={"#{@person.name} portrait"}
            class="w-full rounded-lg aspect-[4/5] object-cover bg-mist-100 shadow-[0_20px_50px_rgba(0,0,0,.15)]"
          />
          <div
            :if={!@person.profile_path}
            class="w-full aspect-[4/5] rounded-lg bg-mist-200 dark:bg-mist-800 grid place-items-center text-mist-500 dark:text-mist-400 text-[12px]"
          >
            No portrait
          </div>
        </div>

        <div class="flex-1 min-w-0">
          <div class="text-[12px] font-semibold text-mist-700 dark:text-mist-300 tracking-[.06em] uppercase mb-2">
            {@person.known_for_department || "Person"}
            <span :if={@years_active_str}>
              · Active {@years_active_str}
            </span>
          </div>

          <h1 class="font-display italic text-[44px] sm:text-[64px] lg:text-[80px] tracking-[-.02em] text-balance text-mist-950 dark:text-white leading-[0.95]">
            {@person.name}
          </h1>

          <div class="mt-4 flex items-center gap-4 flex-wrap text-[13px] text-mist-700 dark:text-mist-300">
            <span :if={@person.birthday}>
              Born {format_date(@person.birthday)}
              <span :if={@person.deathday}>
                — died {format_date(@person.deathday)}
              </span>
            </span>
            <span :if={@person.place_of_birth} class="text-mist-500 dark:text-mist-400">
              · {@person.place_of_birth}
            </span>
          </div>

          <div :if={@person.biography && @person.biography != ""} class="mt-5 max-w-2xl">
            <p class="text-[15px] leading-[1.65] text-mist-900 dark:text-mist-100 whitespace-pre-line">
              <%= if @bio_expanded || !@has_long_bio do %>
                {@person.biography}
              <% else %>
                {@short_bio}…
              <% end %>
            </p>
            <button
              :if={@has_long_bio}
              type="button"
              phx-click="toggle_bio"
              class="mt-2 text-[12.5px] font-semibold text-mist-900 dark:text-white underline decoration-mist-950/15 dark:decoration-white/20 underline-offset-4"
            >
              {if @bio_expanded, do: "Show less", else: "Read more"}
            </button>
          </div>

          <div class="mt-6 flex items-center gap-3 flex-wrap">
            <a
              :if={@person.imdb_id}
              href={"https://www.imdb.com/name/#{@person.imdb_id}"}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 dark:border-white/15 bg-mist-50 dark:bg-mist-900 px-3 py-1.5 text-[12.5px] font-semibold text-mist-900 dark:text-mist-100 hover:bg-mist-950/[0.025] dark:hover:bg-white/5"
            >
              IMDb ↗
            </a>
            <a
              :if={@person.tmdb_id}
              href={"https://www.themoviedb.org/person/#{@person.tmdb_id}"}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 dark:border-white/15 bg-mist-50 dark:bg-mist-900 px-3 py-1.5 text-[12.5px] font-semibold text-mist-900 dark:text-mist-100 hover:bg-mist-950/[0.025] dark:hover:bg-white/5"
            >
              TMDb ↗
            </a>
            <a
              href={"https://en.wikipedia.org/wiki/Special:Search?search=#{URI.encode(@person.name)}"}
              target="_blank"
              rel="noopener"
              class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 dark:border-white/15 bg-mist-50 dark:bg-mist-900 px-3 py-1.5 text-[12.5px] font-semibold text-mist-900 dark:text-mist-100 hover:bg-mist-950/[0.025] dark:hover:bg-white/5"
            >
              Wikipedia ↗
            </a>
            <a
              :if={@person.known_for_department == "Directing"}
              href={"/directors/#{@person.id}"}
              class="inline-flex items-center gap-2 rounded-full bg-mist-950 dark:bg-white px-3 py-1.5 text-[12.5px] font-semibold text-mist-100 dark:text-mist-950 hover:bg-mist-900 dark:hover:bg-mist-100"
            >
              Director analysis →
            </a>
          </div>
        </div>
      </div>
    </section>

    <main class="mx-auto w-full max-w-2xl px-6 md:max-w-3xl lg:max-w-7xl lg:px-10 pb-16 space-y-12 lg:space-y-16">
      <%!-- CAREER AT A GLANCE --%>
      <section>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-5">
            <div class="text-[11px] font-semibold text-mist-500 dark:text-mist-400 tracking-[.06em] uppercase">
              Films
            </div>
            <div class="mt-2 font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
              {@career[:total_movies] || 0}
            </div>
            <div class="mt-2 text-[12px] text-mist-700 dark:text-mist-300 tabular-nums">
              <span :if={@career[:as_actor]}>{@career.as_actor} acting</span>
              <span :if={@career[:as_actor] && @career[:as_crew]}> · </span>
              <span :if={@career[:as_crew]}>{@career.as_crew} crew</span>
            </div>
          </div>

          <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-5">
            <div class="text-[11px] font-semibold text-mist-500 dark:text-mist-400 tracking-[.06em] uppercase">
              Awards
            </div>
            <div class="mt-2 font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
              {@award_stats[:total_wins] || 0}
            </div>
            <div class="mt-2 text-[12px] text-mist-700 dark:text-mist-300 tabular-nums">
              wins · {@award_stats[:total_nominations] || 0} nominations
            </div>
          </div>

          <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-5">
            <div class="text-[11px] font-semibold text-mist-500 dark:text-mist-400 tracking-[.06em] uppercase">
              Avg score
            </div>
            <div class="mt-2 flex items-end justify-between gap-2">
              <span class="font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
                <%= if @avg_score do %>
                  {Float.round(@avg_score, 1)}
                <% else %>
                  —
                <% end %>
              </span>
              <%!-- Score sparkline (NEW) --%>
              <svg
                :if={@trend_points != []}
                width="100"
                height="28"
                class="text-mist-700 dark:text-mist-400"
              >
                <path
                  d={sparkline_path(@trend_points)}
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.3"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
            </div>
            <div class="mt-2 text-[12px] text-mist-700 dark:text-mist-300">
              from rated films
            </div>
          </div>

          <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-5">
            <div class="text-[11px] font-semibold text-mist-500 dark:text-mist-400 tracking-[.06em] uppercase">
              Collaborators
            </div>
            <div class="mt-2 font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
              {length(@frequent_collabs)}
            </div>
            <div class="mt-2 text-[12px] text-mist-700 dark:text-mist-300">
              frequent partners
              <span :if={format_revenue_money(@revenue)} class="text-emerald-700 dark:text-emerald-400">
                · {format_revenue_money(@revenue)} box office
              </span>
            </div>
          </div>
        </div>
      </section>

      <%!-- KNOWN FOR --%>
      <section :if={@known_for != []}>
        <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white mb-6">
          Known for
        </h2>
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-[18px]">
          <NeutralV2Components.n_film_card
            :for={c <- @known_for}
            film={known_for_film_shape(c)}
          />
        </div>
      </section>

      <%!-- FILMOGRAPHY w/ role-chip filter (NEW) --%>
      <section>
        <div class="flex items-end justify-between gap-4 mb-6 flex-wrap">
          <div>
            <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white">
              Filmography
              <span class="text-mist-500 dark:text-mist-400 text-[14px] font-sans not-italic tabular-nums ml-2">
                {@filmography_total}
              </span>
            </h2>
            <div class="mt-2 flex flex-wrap items-center gap-3">
              <a
                href={person_movies_path(@person, @role_filter)}
                class="inline-flex items-center gap-2 text-[12.5px] font-semibold text-mist-900 dark:text-mist-100 underline decoration-mist-950/15 dark:decoration-white/20 underline-offset-4"
              >
                {person_movies_cta_label(@role_filter)} →
              </a>
              <a
                :if={@role_filter != "all"}
                href={person_movies_path(@person, "all")}
                class="inline-flex items-center gap-2 text-[12.5px] font-medium text-mist-600 dark:text-mist-300 underline decoration-mist-950/10 dark:decoration-white/15 underline-offset-4"
              >
                Open full filmography
              </a>
            </div>
          </div>
          <div class="inline-flex p-[3px] bg-mist-950/[0.025] dark:bg-white/5 border border-mist-950/10 dark:border-white/10 rounded-lg gap-[2px]">
            <button
              :for={{key, label} <- role_options()}
              type="button"
              phx-click="set_role"
              phx-value-role={key}
              aria-pressed={@role_filter == key}
              class={[
                "px-3 py-[6px] text-[12.5px] border-0 rounded-[6px] cursor-pointer tracking-[-.005em]",
                if(@role_filter == key,
                  do:
                    "font-semibold text-mist-950 dark:text-white bg-mist-50 dark:bg-mist-800 shadow-[0_1px_2px_rgba(20,18,15,.06)] dark:shadow-none",
                  else: "font-medium text-mist-700 dark:text-mist-300 bg-transparent hover:text-mist-950 dark:hover:text-white"
                )
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <div :if={@grouped_filmography == []} class="py-12 text-center">
          <p class="font-display italic text-[20px] text-mist-700 dark:text-mist-300">
            No films match this filter.
          </p>
        </div>

        <div :for={{year, credits} <- @grouped_filmography} class="mb-6">
          <div class="sticky top-[64px] z-[1] flex items-baseline gap-3 py-2 bg-mist-100/[0.92] dark:bg-mist-950/[0.92] backdrop-blur-md mb-2">
            <span class="font-display italic text-[18px] text-mist-950 dark:text-white tabular-nums">
              <%= if year do %>
                {year}
              <% else %>
                Year unknown
              <% end %>
            </span>
            <span class="text-[11.5px] text-mist-500 dark:text-mist-400 tabular-nums">
              {length(credits)} {if length(credits) == 1, do: "film", else: "films"}
            </span>
          </div>
          <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-2">
            <NeutralV2Components.n_credit_row
              :for={c <- credits}
              credit={credit_to_filmography_shape(c)}
              variant="filmography"
            />
          </div>
        </div>
      </section>

      <%!-- COLLABORATORS --%>
      <section :if={@frequent_collabs != []}>
        <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white mb-6">
          Frequent collaborators
        </h2>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
          <NeutralV2Components.n_collaboration_card
            :for={c <- @frequent_collabs}
            collaboration={collab_shape(c)}
          />
        </div>
        <a
          href={"/collaborations?person_id=#{@person.id}"}
          class="mt-4 inline-flex items-center gap-2 text-[12.5px] font-semibold text-mist-900 dark:text-mist-100 underline decoration-mist-950/15 dark:decoration-white/20 underline-offset-4"
        >
          See full collaboration network →
        </a>
      </section>

      <%!-- AWARDS SUMMARY --%>
      <section :if={(@award_stats[:total_nominations] || 0) > 0}>
        <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white mb-6">
          Awards & festivals
        </h2>
        <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-6">
          <div class="flex items-baseline gap-4 flex-wrap">
            <div>
              <div class="font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
                {@award_stats[:total_wins] || 0}
              </div>
              <div class="text-[12px] text-mist-700 dark:text-mist-300 mt-1">wins</div>
            </div>
            <div class="text-mist-300 dark:text-mist-700">·</div>
            <div>
              <div class="font-display italic text-[36px] text-mist-950 dark:text-white tabular-nums leading-none">
                {@award_stats[:total_nominations] || 0}
              </div>
              <div class="text-[12px] text-mist-700 dark:text-mist-300 mt-1">nominations</div>
            </div>
          </div>
          <p class="mt-4 text-[13px] text-mist-700 dark:text-mist-300 max-w-prose">
            Career nominations across Academy Awards, BAFTA, Golden Globes, festival juries (Cannes, Venice, Berlin, Sundance, etc.), and other tracked organizations.
          </p>
        </div>
      </section>

      <%!-- SIX DEGREES INLINE --%>
      <section>
        <h2 class="font-display italic text-[28px] sm:text-[32px] tracking-[-.01em] text-mist-950 dark:text-white mb-3">
          Six degrees
        </h2>
        <p class="text-[14px] text-mist-700 dark:text-mist-300 mb-4 max-w-2xl">
          Find the connection path between {@person.name} and any other person in the
          Cinegraph database.
        </p>
        <div class="bg-mist-50 dark:bg-mist-900 border border-mist-950/10 dark:border-white/10 rounded-lg p-5">
          <form phx-submit="search_six_degrees" class="flex items-center gap-3 flex-wrap">
            <input
              type="number"
              name="target_person_id"
              placeholder="Target person ID"
              min="1"
              step="1"
              required
              disabled={@six_degrees_loading}
              class="flex-1 min-w-[200px] h-10 px-3 rounded-lg border border-mist-950/15 dark:border-white/15 bg-white dark:bg-mist-800 text-[14px] text-mist-950 dark:text-white outline-none focus:border-mist-950 dark:focus:border-white placeholder:text-mist-500"
            />
            <button
              type="submit"
              disabled={@six_degrees_loading}
              class="inline-flex items-center gap-2 rounded-full bg-mist-950 dark:bg-white px-4 py-2 text-sm font-medium text-mist-100 dark:text-mist-950 hover:bg-mist-900 dark:hover:bg-mist-100 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {if @six_degrees_loading, do: "Searching…", else: "Find path"}
            </button>
            <a
              href={~p"/six-degrees"}
              class="text-[12.5px] font-semibold text-mist-700 dark:text-mist-300 underline decoration-mist-950/15 dark:decoration-white/15 underline-offset-4"
            >
              Open full explorer →
            </a>
          </form>

          <div
            :if={@six_degrees_path == :no_path}
            class="mt-4 p-4 bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800 rounded text-[13.5px] text-amber-900 dark:text-amber-300"
          >
            No path found within 6 degrees.
          </div>

          <div :if={is_list(@six_degrees_path)} class="mt-4 space-y-2">
            <div class="text-[12.5px] text-mist-700 dark:text-mist-300 font-semibold">
              Path found ({length(@six_degrees_path)} {if length(@six_degrees_path) == 1,
                do: "degree",
                else: "degrees"})
            </div>
            <ol class="list-decimal pl-5 text-[13.5px] text-mist-900 dark:text-mist-100 space-y-1">
              <li :for={hop <- @six_degrees_path}>
                {format_hop(hop)}
              </li>
            </ol>
          </div>
        </div>
      </section>
    </main>

    <%!-- v1 access pill --%>
    <a
      href={"/people/#{person_slug_or_id(@person)}/legacy"}
      class="fixed bottom-4 right-4 z-40 inline-flex items-center gap-2 rounded-full bg-mist-950 px-4 py-2 text-xs font-medium text-mist-100 shadow-lg hover:bg-mist-800"
    >
      ← see classic page
    </a>
    """
  end

  defp format_hop(hop) when is_tuple(hop) do
    case hop do
      {%{name: a}, %{title: title}, %{name: b}} -> "#{a} → #{title} → #{b}"
      _ -> inspect(hop)
    end
  end

  defp format_hop(hop) when is_map(hop) do
    "#{hop[:from] || "—"} → #{hop[:movie] || "—"} → #{hop[:to] || "—"}"
  end

  defp format_hop(hop), do: inspect(hop)
end
