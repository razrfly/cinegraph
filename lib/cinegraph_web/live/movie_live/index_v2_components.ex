defmodule CinegraphWeb.MovieLive.IndexV2Components do
  @moduledoc """
  Render-only components for the V2 movie discovery page.

  Filter shell follows Option C from issue #785:
  - `hero/1` — Movies. + total count
  - `filters/1` — sort segmented control + decade chips + genre chips + drawer button
  - `active_filters/1` — chip strip with individual ✕
  - `results/1` — film card grid (cards switch to lens-badge mode when @active_lens_key is set)
  - `pagination/1` — prev / next + page count
  """
  use Phoenix.Component

  alias CinegraphWeb.Helpers.UrlHelpers
  alias CinegraphWeb.LiveViewHelpers
  alias CinegraphWeb.MovieLive.GenreEmoji
  alias CinegraphWeb.MovieLive.SortOptions
  alias CinegraphWeb.NeutralV2Components

  @lens_keys ~w(mob critics festival_recognition time_machine auteurs)
  # Phase 2 (issue #787): only the three table-stakes sorts stay on the
  # segmented control. Lens sorts and presets move into the "More sorts ▾" menu.
  @primary_sort_keys ~w(release_date score popularity)
  @basic_filter_keys ~w(search genres decade lists festivals people_ids rating_preset show_unreleased)

  # ──────────────────────────────────────────────────────────────────
  # Hero
  # ──────────────────────────────────────────────────────────────────

  attr :total_count, :integer, default: nil

  def hero(assigns) do
    ~H"""
    <section class="mb-8 lg:mb-12">
      <h1 class="font-display italic text-[44px] sm:text-[56px] lg:text-[72px] tracking-[-.02em] text-balance text-mist-950 leading-[1.02]">
        Movies.
      </h1>
      <p class="text-[15px] text-mist-700 mt-2 max-w-2xl">
        {format_count(@total_count)} films across canonical lists, festivals, and critical canon.
      </p>
      <div class="flex items-center gap-3 mt-1.5 text-[14px] text-mist-700">
        <a
          href="/movies/discover"
          class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950"
        >
          Tunable scoring →
        </a>
        <span class="text-mist-500" aria-hidden="true">·</span>
        <button
          type="button"
          phx-click="show_scoring_info"
          class="underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950 bg-transparent border-0 p-0 cursor-pointer font-[inherit] text-[14px] text-mist-700"
        >
          How we score?
        </button>
      </div>
    </section>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # Filters
  # ──────────────────────────────────────────────────────────────────

  attr :search_term, :string, default: ""
  attr :sort_options, :list, required: true
  attr :sort_criteria, :string, default: "release_date"
  attr :sort_direction, :atom, default: :desc
  attr :sort_is_preset, :boolean, default: false
  attr :filter_options, :map, required: true
  attr :params, :map, required: true
  attr :active_filter_count, :integer, default: 0

  def filters(assigns) do
    selected_genres = list_param(assigns.params, "genres")
    genres = assigns.filter_options[:genres] || []
    visible_genre_count = 10

    primary_sort_options =
      Enum.filter(assigns.sort_options, &(&1.value in @primary_sort_keys))

    overflow_sort_options =
      Enum.reject(assigns.sort_options, &(&1.value in @primary_sort_keys))

    assigns =
      assigns
      |> assign(:selected_genres, selected_genres)
      |> assign(:genres, genres)
      |> assign(:visible_genre_count, visible_genre_count)
      |> assign(:primary_sort_options, primary_sort_options)
      |> assign(:overflow_sort_options, overflow_sort_options)
      |> assign(:overflow_groups, grouped_overflow_options(overflow_sort_options))

    ~H"""
    <section class="mb-6 space-y-4">
      <%!-- Search --%>
      <form phx-change="search" phx-submit="search">
        <div class="relative flex items-center bg-mist-50 rounded-lg border border-mist-950/15 h-11 px-[14px]">
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none" class="shrink-0 text-mist-500">
            <circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.4" />
            <path
              d="M11 11 L14 14"
              stroke="currentColor"
              stroke-width="1.4"
              stroke-linecap="round"
            />
          </svg>
          <input
            name="search"
            value={@search_term}
            placeholder="Search films, people, lists, companies…"
            phx-debounce="350"
            autocomplete="off"
            class="flex-1 ml-[9px] text-mist-950 bg-transparent border-0 outline-none min-w-0 font-[inherit] text-[14.5px]"
          />
          <kbd class="font-mono text-[10.5px] font-semibold px-[6px] py-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-[4px] text-mist-700">
            ⌘K
          </kbd>
        </div>
      </form>

      <%!-- Sort row --%>
      <div class="flex items-center gap-3 flex-wrap">
        <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0">
          SORT
        </span>
        <div class="inline-flex p-[3px] bg-mist-950/[0.025] border border-mist-950/10 rounded-lg gap-[2px]">
          <button
            :for={opt <- @primary_sort_options}
            type="button"
            phx-click="sort_criteria_changed"
            phx-value-criteria={opt.value}
            class={[
              "px-3 py-[6px] text-[12.5px] border-0 rounded-[6px] cursor-pointer tracking-[-.005em]",
              if(@sort_criteria == opt.value,
                do: "font-semibold text-mist-950 bg-mist-50 shadow-[0_1px_2px_rgba(20,18,15,.06)]",
                else: "font-medium text-mist-700 bg-transparent hover:text-mist-950"
              )
            ]}
            title={sort_tooltip(opt)}
          >
            {sort_label_short(opt)}
          </button>

          <%!-- More sorts ▾ overflow menu (structured, grouped) --%>
          <details
            :if={@overflow_sort_options != []}
            class="relative"
            id="sort-overflow"
          >
            <summary class={[
              "list-none px-3 py-[6px] text-[12.5px] rounded-[6px] cursor-pointer tracking-[-.005em] select-none",
              if(@sort_criteria not in Enum.map(@primary_sort_options, & &1.value),
                do: "font-semibold text-mist-950 bg-mist-50 shadow-[0_1px_2px_rgba(20,18,15,.06)]",
                else: "font-medium text-mist-700 hover:text-mist-950"
              )
            ]}>
              {overflow_summary_label(
                @sort_criteria,
                @sort_direction,
                @primary_sort_options,
                @overflow_sort_options
              )}
            </summary>
            <div class="absolute right-0 mt-2 z-30 bg-mist-50 border border-mist-950/10 rounded-lg shadow-[0_8px_24px_rgba(20,18,15,.10)] min-w-[280px] py-2">
              <div :for={{header, opts} <- @overflow_groups} class="px-1 pb-1">
                <h4 class="px-3 pt-2 pb-1 text-[10.5px] font-semibold tracking-[.08em] uppercase text-mist-500">
                  {header}
                </h4>
                <div
                  :for={opt <- opts}
                  class={[
                    "flex items-center justify-between gap-2 mx-1 rounded-[6px]",
                    if(@sort_criteria == opt.value,
                      do: "bg-mist-950/[0.05]",
                      else: "hover:bg-mist-950/[0.03]"
                    )
                  ]}
                >
                  <button
                    type="button"
                    phx-click="sort_criteria_changed"
                    phx-value-criteria={opt.value}
                    title={sort_tooltip(opt)}
                    class={[
                      "flex-1 text-left px-3 py-1.5 text-[12.5px]",
                      if(@sort_criteria == opt.value,
                        do: "font-semibold text-mist-950",
                        else: "font-medium text-mist-800"
                      )
                    ]}
                  >
                    {display_label(opt)}
                  </button>
                  <button
                    :if={@sort_criteria == opt.value}
                    type="button"
                    phx-click="toggle_sort_direction"
                    title={
                      if @sort_direction == :desc,
                        do: "Switch to ascending",
                        else: "Switch to descending"
                    }
                    class="px-2 py-1 mr-1 text-[12px] text-mist-700 hover:text-mist-950 tabular-nums"
                  >
                    {if @sort_direction == :desc, do: "↓", else: "↑"}
                  </button>
                </div>
              </div>
              <div class="border-t border-mist-950/10 mt-1 pt-1 px-3">
                <button
                  type="button"
                  phx-click="show_scoring_info"
                  class="w-full text-left text-[12px] text-mist-700 hover:text-mist-950 underline decoration-mist-950/15 underline-offset-4 py-1.5"
                >
                  How does Cinegraph score? →
                </button>
              </div>
            </div>
          </details>
        </div>

        <%!-- Filters drawer button --%>
        <button
          type="button"
          phx-click="toggle_drawer"
          class="ml-auto inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 text-[12.5px] font-medium text-mist-950 hover:bg-mist-950/[0.025]"
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M3 4a1 1 0 011-1h16a1 1 0 011 1v2.586a1 1 0 01-.293.707l-6.414 6.414a1 1 0 00-.293.707V17l-4 4v-6.586a1 1 0 00-.293-.707L3.293 7.293A1 1 0 013 6.586V4z"
            />
          </svg>
          Filters
          <span
            :if={@active_filter_count > 0}
            class="inline-flex items-center justify-center min-w-[18px] h-[18px] px-[5px] rounded-full bg-mist-950 text-mist-50 text-[10.5px] font-semibold tabular-nums"
          >
            {@active_filter_count}
          </span>
        </button>
      </div>

      <%!-- Genre chips (multi-select, with emoji prefix) --%>
      <div :if={@genres != []} class="flex items-center gap-[6px] flex-wrap">
        <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0 mr-1">
          GENRE
        </span>
        <NeutralV2Components.n_chip_toggle
          :for={genre <- Enum.take(@genres, @visible_genre_count)}
          active={to_string(genre.id) in @selected_genres}
          phx-click="toggle_chip"
          phx-value-key="genres"
          phx-value-value={to_string(genre.id)}
          phx-value-mode="multi"
        >
          <span class="mr-[5px]">{GenreEmoji.for_id(genre.tmdb_id)}</span>{genre.name}
        </NeutralV2Components.n_chip_toggle>
        <details
          :if={length(@genres) > @visible_genre_count}
          class="relative"
        >
          <summary class="list-none px-[11px] py-[5px] text-[12px] rounded-full cursor-pointer text-mist-700 hover:text-mist-950 select-none">
            + {length(@genres) - @visible_genre_count} more
          </summary>
          <div class="absolute left-0 mt-2 z-30 bg-mist-50 border border-mist-950/10 rounded-lg shadow-lg p-2 flex flex-wrap gap-[6px] max-w-[420px]">
            <NeutralV2Components.n_chip_toggle
              :for={genre <- Enum.drop(@genres, @visible_genre_count)}
              active={to_string(genre.id) in @selected_genres}
              phx-click="toggle_chip"
              phx-value-key="genres"
              phx-value-value={to_string(genre.id)}
              phx-value-mode="multi"
            >
              <span class="mr-[5px]">{GenreEmoji.for_id(genre.tmdb_id)}</span>{genre.name}
            </NeutralV2Components.n_chip_toggle>
          </div>
        </details>
      </div>
    </section>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # Active-filter chip strip
  # ──────────────────────────────────────────────────────────────────

  attr :params, :map, required: true
  attr :filter_options, :map, required: true

  def active_filters(assigns) do
    chips = build_active_chips(assigns.params, assigns.filter_options)
    assigns = assign(assigns, :chips, chips)

    ~H"""
    <section :if={@chips != []} class="mb-6 flex items-center gap-2 flex-wrap">
      <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase">
        ACTIVE
      </span>
      <span
        :for={{key, label, value_label} <- @chips}
        class="inline-flex items-center gap-1.5 rounded-full bg-mist-950/[0.04] border border-mist-950/10 px-[10px] py-[3px] text-[11.5px] text-mist-900"
      >
        <span class="text-mist-500">{label}:</span>
        <span class="font-medium">{value_label}</span>
        <button
          type="button"
          phx-click="remove_filter"
          phx-value-filter={key}
          class="ml-1 inline-flex items-center justify-center w-3.5 h-3.5 text-mist-500 hover:text-mist-950"
          title="Remove"
        >
          ×
        </button>
      </span>
      <button
        type="button"
        phx-click="clear_filters"
        class="ml-2 text-[11.5px] font-medium text-mist-700 underline decoration-mist-950/15 underline-offset-4 hover:text-mist-950"
      >
        Clear all
      </button>
    </section>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # Results grid
  # ──────────────────────────────────────────────────────────────────

  attr :movies, :list, required: true
  attr :active_lens_key, :any, default: nil

  def results(assigns) do
    ~H"""
    <section class="mb-8">
      <div :if={@movies == []} class="py-20 text-center">
        <p class="font-display italic text-[28px] text-mist-700">
          No films match these filters.
        </p>
        <button
          phx-click="clear_filters"
          class="mt-4 inline-flex items-center justify-center gap-1 rounded-full bg-mist-950 px-4 py-2 text-sm/7 font-medium text-mist-100 hover:bg-mist-800"
        >
          Clear filters
        </button>
      </div>

      <div
        :if={@movies != []}
        class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-[18px]"
      >
        <NeutralV2Components.n_film_card
          :for={movie <- @movies}
          film={to_card_shape(movie, @active_lens_key)}
        />
      </div>
    </section>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # Pagination
  # ──────────────────────────────────────────────────────────────────

  attr :meta, :any, required: true

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@meta && @meta.total_pages && @meta.total_pages > 1}
      class="flex items-center justify-between gap-4 pt-6 border-t border-mist-950/10 text-[13px] text-mist-700"
    >
      <button
        type="button"
        phx-click="page"
        phx-value-page={max(1, (@meta.current_page || 1) - 1)}
        disabled={(@meta.current_page || 1) <= 1}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>

      <div class="text-[12px] tabular-nums">
        Page <b class="text-mist-950 font-semibold">{@meta.current_page}</b>
        of <b class="text-mist-950 font-semibold">{@meta.total_pages}</b>
        <span class="text-mist-500">
          · {format_count(@meta.total_count)} films
        </span>
      </div>

      <button
        type="button"
        phx-click="page"
        phx-value-page={min(@meta.total_pages, (@meta.current_page || 1) + 1)}
        disabled={(@meta.current_page || 1) >= @meta.total_pages}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 bg-mist-50 px-4 py-2 font-medium text-mist-950 hover:bg-mist-950/[0.025] disabled:opacity-40 disabled:cursor-not-allowed"
      >
        Next →
      </button>
    </nav>
    """
  end

  # ──────────────────────────────────────────────────────────────────
  # Public helpers (called from the LiveView render)
  # ──────────────────────────────────────────────────────────────────

  @doc "Returns the count of currently active filter URL params (excludes search/sort/page)."
  def active_filter_count(params) when is_map(params) do
    @basic_filter_keys
    |> Enum.reject(&(&1 == "search"))
    |> Enum.count(fn key -> filter_value_present?(params[key]) end)
  end

  def active_filter_count(_), do: 0

  @doc "Reads a list-typed URL param as a list of strings (handles list, CSV, nil)."
  def list_param(params, key) when is_map(params) do
    LiveViewHelpers.parse_array_param(params[key])
  end

  def list_param(_, _), do: []

  @doc """
  Returns the list of currently selected person IDs from the URL params, ready
  to feed `PersonAutocomplete`'s `selected_people` attr (which accepts integer IDs).
  """
  def selected_people_ids(params) when is_map(params) do
    case params["people_ids"] do
      nil -> []
      "" -> []
      ids when is_binary(ids) -> ids |> String.split(",", trim: true)
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  def selected_people_ids(_), do: []

  # ──────────────────────────────────────────────────────────────────
  # Card shape
  # ──────────────────────────────────────────────────────────────────

  defp to_card_shape(movie, active_lens_key) do
    genres = genres_of(movie)
    {score_str, lens_components} = score_for_card(movie, active_lens_key)

    %{
      id: movie.id,
      title: movie.title,
      year: year_of(movie.release_date),
      dir: director_of(movie),
      genre: List.first(genres),
      genres: genres,
      score: score_str,
      score_tooltip: score_tooltip_for(active_lens_key),
      lens_key: active_lens_key,
      lens_components: lens_components,
      poster_url: tmdb_poster_url(movie.poster_path, "w500"),
      href: movie_href(movie)
    }
  end

  # Tooltip rendered on the card's corner score badge. The active sort
  # determines what the badge represents.
  defp score_tooltip_for(lens_key) when lens_key in @lens_keys, do: lens_tooltip(lens_key)
  defp score_tooltip_for(:preset), do: "Cinegraph composite score (Scored Preset)"

  defp score_tooltip_for(_),
    do: "Cinegraph composite score — audience + critics + awards + canon + talent"

  # Score for the card badge + the lens-component chips below the title.
  #
  # Lens sort: read score_cache.<lens>_score and emit a "%" badge plus
  # one chip per lens (mob/critics/festival_recognition/time_machine/auteurs).
  # Cached worker scores are 0-10, while some query-time score components are
  # 0-1; normalize both scales before rendering percentages.
  # The score_cache is preloaded by IndexV2 only when a lens sort is active
  # (single batched query — see preload_card_assocs/2).
  #
  # Scored preset: overall_score is set as a virtual field by CustomSorting;
  # rendered as e.g. "9.0".
  #
  # No-lens sort: don't surface a score.
  defp score_for_card(movie, lens_key) when lens_key in @lens_keys do
    cache = loaded_score_cache(movie)
    primary = lens_value(cache, lens_key)
    primary_percent = lens_percent(primary)
    score_str = if primary_percent, do: "#{primary_percent}%", else: nil

    chips =
      @lens_keys
      |> Enum.map(fn k ->
        val = lens_value(cache, k)
        percent = lens_percent(val)
        # Threshold ≥5% on the displayed percent scale (issue #787 phase 1).
        # Raises the floor from the previous >1% to silence near-zero noise.
        if percent && percent >= 5, do: {k, percent, lens_tooltip(k)}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    {score_str, chips}
  end

  defp score_for_card(movie, :preset) do
    case Map.get(movie, :overall_score) do
      v when is_number(v) -> {Float.round(v * 1.0, 1) |> :erlang.float_to_binary(decimals: 1), []}
      _ -> default_score(movie)
    end
  end

  defp score_for_card(movie, _), do: default_score(movie)

  defp default_score(movie) do
    case Map.get(movie, :overall_score) do
      v when is_number(v) -> {Float.round(v * 1.0, 1) |> :erlang.float_to_binary(decimals: 1), []}
      _ -> {nil, []}
    end
  end

  defp loaded_score_cache(%{score_cache: %Ecto.Association.NotLoaded{}}), do: nil
  defp loaded_score_cache(%{score_cache: nil}), do: nil
  defp loaded_score_cache(%{score_cache: cache}), do: cache
  defp loaded_score_cache(_), do: nil

  defp lens_value(nil, _), do: nil

  defp lens_value(cache, "mob"), do: Map.get(cache, :mob_score)
  defp lens_value(cache, "critics"), do: Map.get(cache, :critics_score)

  defp lens_value(cache, "festival_recognition"),
    do: Map.get(cache, :festival_recognition_score)

  defp lens_value(cache, "time_machine"), do: Map.get(cache, :time_machine_score)
  defp lens_value(cache, "auteurs"), do: Map.get(cache, :auteurs_score)
  defp lens_value(_, _), do: nil

  # Per-lens tooltip copy (mirrors the sort_tooltip strings).
  defp lens_tooltip("mob"), do: "Audience — IMDb + TMDb + Rotten Tomatoes"
  defp lens_tooltip("critics"), do: "Critics — Metacritic + Rotten Tomatoes"
  defp lens_tooltip("festival_recognition"), do: "Awards — festival wins and major-award presence"
  defp lens_tooltip("time_machine"), do: "All-time canon — Criterion, 1001 Movies, Sight & Sound"
  defp lens_tooltip("auteurs"), do: "Director picks — director and cast quality"
  defp lens_tooltip(_), do: nil

  defp lens_percent(nil), do: nil

  defp lens_percent(value) when is_number(value) do
    value
    |> then(fn
      v when v <= 1.0 -> v * 100
      v -> v * 10
    end)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp lens_percent(_), do: nil

  defp filter_value_present?(nil), do: false
  defp filter_value_present?(""), do: false
  defp filter_value_present?([]), do: false
  defp filter_value_present?([""]), do: false
  defp filter_value_present?(_), do: true

  # ──────────────────────────────────────────────────────────────────
  # Active-filter chip building
  # ──────────────────────────────────────────────────────────────────

  defp build_active_chips(params, filter_options) do
    filter_chips =
      @basic_filter_keys
      |> Enum.reject(&(&1 == "search"))
      |> Enum.flat_map(fn key ->
        value = params[key]

        if filter_value_present?(value) do
          [{key, label_for(key), value_label_for(key, value, filter_options)}]
        else
          []
        end
      end)

    sort_chip(params) ++ filter_chips
  end

  # Surface the active sort as a chip when it differs from the default
  # (`release_date_desc`). Uses the display_label/1 to match the More-sorts
  # menu vocabulary; the trailing arrow communicates direction.
  defp sort_chip(params) do
    raw = params["sort"] || ""
    default? = raw in ["", "release_date_desc"]

    if default? do
      []
    else
      criteria = String.replace(raw, ~r/_(asc|desc)$/, "")
      direction = if String.ends_with?(raw, "_asc"), do: :asc, else: :desc

      label =
        case Enum.find(SortOptions.all(), &(&1.value == criteria)) do
          nil -> criteria
          opt -> display_label(opt)
        end

      [{"sort", "Sort", "#{label} #{direction_arrow(direction)}"}]
    end
  end

  defp label_for("genres"), do: "Genres"
  defp label_for("decade"), do: "Decade"
  defp label_for("lists"), do: "Lists"
  defp label_for("festivals"), do: "Festivals"
  defp label_for("people_ids"), do: "Cast & Crew"
  defp label_for("rating_preset"), do: "Rating"
  defp label_for("show_unreleased"), do: "Unreleased"
  defp label_for(other), do: other |> String.replace("_", " ") |> String.capitalize()

  defp value_label_for("genres", value, opts) do
    ids = LiveViewHelpers.parse_array_param(value)
    available = opts[:genres] || []

    ids
    |> Enum.map(fn id ->
      id_int = parse_id(id)
      Enum.find(available, &(&1.id == id_int)) || %{name: to_string(id)}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("lists", value, opts) do
    keys = LiveViewHelpers.parse_array_param(value)
    available = opts[:lists] || []

    keys
    |> Enum.map(fn k ->
      Enum.find(available, &(&1.key == k)) || %{name: k}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("festivals", value, opts) do
    ids = LiveViewHelpers.parse_array_param(value)
    available = opts[:festivals] || []

    ids
    |> Enum.map(fn id ->
      id_int = parse_id(id)
      Enum.find(available, &(&1.id == id_int)) || %{name: to_string(id)}
    end)
    |> Enum.map(& &1.name)
    |> truncate_join()
  end

  defp value_label_for("decade", value, _opts), do: "#{value}s"

  defp value_label_for("rating_preset", value, _opts) do
    case to_string(value) do
      "highly_rated" -> "Highly rated (7.5+)"
      "well_reviewed" -> "Well reviewed (6.0+)"
      "critically_acclaimed" -> "Critically acclaimed"
      other -> other
    end
  end

  defp value_label_for("show_unreleased", "true", _opts), do: "Yes"
  defp value_label_for("show_unreleased", _, _opts), do: "No"

  defp value_label_for("people_ids", value, _opts) do
    ids =
      value
      |> to_string()
      |> String.split(",", trim: true)

    case length(ids) do
      0 -> "—"
      1 -> "1 person"
      n -> "#{n} people"
    end
  end

  defp value_label_for(_, value, _opts) when is_list(value), do: Enum.join(value, ", ")
  defp value_label_for(_, value, _opts), do: to_string(value)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp truncate_join(names) do
    joined = Enum.join(names, ", ")
    if String.length(joined) > 30, do: String.slice(joined, 0..27) <> "…", else: joined
  end

  # ──────────────────────────────────────────────────────────────────
  # Sort label helpers
  # ──────────────────────────────────────────────────────────────────

  # Short label used in the primary segmented control (Phase 2: only 3 entries).
  # Emoji prefix matches the genre-chip pattern for visual scanability.
  defp sort_label_short(%{value: "release_date"}), do: "📅 Most recent"
  defp sort_label_short(%{value: "score"}), do: "⭐ Highest rated"
  defp sort_label_short(%{value: "popularity"}), do: "🔥 Trending"
  defp sort_label_short(%{label: label}), do: label

  # Longer label used in the overflow ▼ More menu. Strips the canonical emojis
  # and prefixes from `SortOptions.all/0` (which serve v1 / Tuner) and replaces
  # the lens jargon with the V2 vocabulary. Falls through to the canonical
  # label for everything else (Title / Runtime / Rating / Scored Presets).
  defp display_label(%{value: "release_date"}), do: "📅 Most recent"
  defp display_label(%{value: "score"}), do: "⭐ Highest rated"
  defp display_label(%{value: "popularity"}), do: "🔥 Trending"
  defp display_label(%{value: "mob"}), do: "👥 Audience"
  defp display_label(%{value: "critics"}), do: "🎭 Critics"
  defp display_label(%{value: "festival_recognition"}), do: "🏆 Awards"
  defp display_label(%{value: "time_machine"}), do: "⏳ All-time canon"
  defp display_label(%{value: "auteurs"}), do: "🎬 Director picks"
  defp display_label(%{label: label}), do: label

  # One-line explanation rendered as the `title=` attribute on each sort button.
  # Mirrors the lens-tooltip copy used on card chips.
  defp sort_tooltip(%{value: "release_date"}), do: "Newest releases first"
  defp sort_tooltip(%{value: "score"}), do: "Top of the Cinegraph composite score"
  defp sort_tooltip(%{value: "popularity"}), do: "What's hot right now (TMDb popularity)"
  defp sort_tooltip(%{value: "rating"}), do: "Sorted by raw user rating"

  defp sort_tooltip(%{value: "mob"}),
    do: "What audiences love (IMDb + TMDb + Rotten Tomatoes)"

  defp sort_tooltip(%{value: "critics"}),
    do: "What critics rate highly (Metacritic + Rotten Tomatoes)"

  defp sort_tooltip(%{value: "festival_recognition"}),
    do: "Festival wins and major-award presence"

  defp sort_tooltip(%{value: "time_machine"}),
    do: "Films that survive — Criterion, 1001 Movies, Sight & Sound"

  defp sort_tooltip(%{value: "auteurs"}), do: "Great directors, great casts"
  defp sort_tooltip(%{value: "title"}), do: "Alphabetical by title"
  defp sort_tooltip(%{value: "runtime"}), do: "By length (longest first)"
  defp sort_tooltip(%{label: label}), do: label

  # When an overflow sort is active, replace the generic "More sorts ▾" trigger
  # with the active label + direction arrow so the user can see the current sort
  # without opening the menu. Falls back to "More sorts ▾" otherwise.
  defp overflow_summary_label(criteria, direction, primary_opts, overflow_opts) do
    primary_values = Enum.map(primary_opts, & &1.value)

    if criteria in primary_values do
      "More sorts ▾"
    else
      case Enum.find(overflow_opts, &(&1.value == criteria)) do
        nil -> "More sorts ▾"
        opt -> "#{display_label(opt)} #{direction_arrow(direction)} ▾"
      end
    end
  end

  defp direction_arrow(:asc), do: "↑"
  defp direction_arrow(_), do: "↓"

  # Issue #787 Phase 2: structured "More sorts ▾" menu groups, in display order.
  # Each group is `{header, [opt, ...]}`. Empty groups are filtered out.
  defp grouped_overflow_options(overflow_opts) do
    timeline_keys = ~w(title runtime)
    quality_keys = ~w(rating critics mob festival_recognition)
    lens_keys = ~w(time_machine auteurs)

    by_value = Map.new(overflow_opts, fn opt -> {opt.value, opt} end)

    presets =
      Enum.filter(overflow_opts, fn opt -> Map.get(opt, :group) == "Scored Presets" end)

    [
      {"Timeline", Enum.map(timeline_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Quality", Enum.map(quality_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Cinegraph lenses", Enum.map(lens_keys, &Map.get(by_value, &1)) |> Enum.reject(&is_nil/1)},
      {"Scored presets", presets}
    ]
    |> Enum.reject(fn {_, opts} -> opts == [] end)
  end

  # ──────────────────────────────────────────────────────────────────
  # Movie / data helpers
  # ──────────────────────────────────────────────────────────────────

  defp year_of(%Date{year: y}), do: y
  defp year_of(_), do: nil

  defp tmdb_poster_url(nil, _), do: nil
  defp tmdb_poster_url("", _), do: nil
  defp tmdb_poster_url("/" <> _ = path, size), do: "https://image.tmdb.org/t/p/#{size}#{path}"
  defp tmdb_poster_url(path, size), do: "https://image.tmdb.org/t/p/#{size}/#{path}"

  defp movie_href(%{slug: slug, id: id}), do: UrlHelpers.movie_href(slug, id)
  defp movie_href(%{id: id}), do: UrlHelpers.movie_href(nil, id)

  defp director_of(movie) do
    case movie |> Map.get(:director) |> present_string() do
      nil -> director_from_movie_credits(movie)
      director -> director
    end
  end

  defp genres_of(movie) do
    movie
    |> loaded_assoc(:genres)
    |> Enum.map(&genre_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp loaded_assoc(movie, assoc) do
    case Map.get(movie, assoc) do
      %Ecto.Association.NotLoaded{} -> []
      nil -> []
      values when is_list(values) -> values
      value -> [value]
    end
  end

  defp director_from_movie_credits(movie) do
    movie
    |> loaded_assoc(:movie_credits)
    |> Enum.find_value(fn
      %{job: "Director", person: %{name: name}} -> present_string(name)
      _ -> nil
    end)
  end

  defp present_string(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp present_string(_), do: nil

  defp genre_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp genre_name(name) when is_binary(name) and name != "", do: name
  defp genre_name(_), do: nil

  defp format_count(nil), do: "—"

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
