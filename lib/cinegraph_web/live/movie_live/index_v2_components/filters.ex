defmodule CinegraphWeb.MovieLive.IndexV2Components.Filters do
  @moduledoc """
  Filter shell and URL-param helpers for the V2 movie index.
  """
  use Phoenix.Component

  alias Cinegraph.Movies.Genre
  alias CinegraphWeb.LiveViewHelpers
  alias CinegraphWeb.MovieLive.GenreEmoji
  alias CinegraphWeb.MovieLive.IndexV2Components.ParamHelpers
  alias CinegraphWeb.MovieLive.IndexV2Components.SortLabels
  alias CinegraphWeb.NeutralV2Components

  @primary_sort_keys ~w(release_date score popularity)
  @basic_filter_keys ~w(search genres decade lists festivals companies people rating_preset show_unreleased)

  attr :search_term, :string, default: ""
  attr :sort_options, :list, required: true
  attr :sort_criteria, :string, default: "release_date"
  attr :sort_direction, :atom, default: :desc
  attr :sort_is_preset, :boolean, default: false
  attr :filter_options, :map, required: true
  attr :params, :map, required: true
  attr :active_filter_count, :integer, default: 0
  attr :scope, :map, default: %{}

  def filters(assigns) do
    genres = assigns.filter_options[:genres] || []
    selected_genres = selected_genre_slugs(assigns.params, genres)
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
      |> assign(:overflow_groups, SortLabels.grouped_overflow_options(overflow_sort_options))

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
            title={SortLabels.tooltip(opt)}
          >
            {SortLabels.short(opt)}
          </button>

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
              {SortLabels.overflow_summary(
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
                    title={SortLabels.tooltip(opt)}
                    class={[
                      "flex-1 text-left px-3 py-1.5 text-[12.5px]",
                      if(@sort_criteria == opt.value,
                        do: "font-semibold text-mist-950",
                        else: "font-medium text-mist-800"
                      )
                    ]}
                  >
                    {SortLabels.display(opt)}
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

      <div :if={@genres != []} class="flex items-center gap-[6px] flex-wrap">
        <span class="text-[11px] font-semibold text-mist-500 tracking-[.06em] uppercase shrink-0 mr-1">
          GENRE
        </span>
        <NeutralV2Components.n_chip_toggle
          :for={genre <- Enum.take(@genres, @visible_genre_count)}
          active={Genre.slug(genre) in @selected_genres}
          phx-click="toggle_chip"
          phx-value-key="genres"
          phx-value-id={Genre.slug(genre)}
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
              active={Genre.slug(genre) in @selected_genres}
              phx-click="toggle_chip"
              phx-value-key="genres"
              phx-value-id={Genre.slug(genre)}
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

  def active_filter_count(params) when is_map(params) do
    active_filter_count(params, %{})
  end

  def active_filter_count(_), do: 0

  def active_filter_count(params, scope) when is_map(params) do
    hidden_keys = hidden_filter_keys(scope)
    params = ParamHelpers.normalize_people_filter(params)

    filter_count =
      @basic_filter_keys
      |> Enum.reject(&(&1 == "search"))
      |> Enum.reject(&(&1 in hidden_keys))
      |> Enum.count(fn key -> filter_value_present?(params[key]) end)

    if sort_param_non_default?(params["sort"]), do: filter_count + 1, else: filter_count
  end

  def active_filter_count(_, _), do: 0

  def list_param(params, key) when is_map(params) do
    LiveViewHelpers.parse_array_param(params[key])
  end

  def list_param(_, _), do: []

  def selected_people_ids(params) when is_map(params) do
    case params["people"] || params["people_ids"] do
      nil -> []
      "" -> []
      ids when is_binary(ids) -> ids |> String.split(",", trim: true)
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  def selected_people_ids(_), do: []

  defp selected_genre_slugs(params, genres) when is_map(params) do
    params
    |> list_param("genres")
    |> Enum.map(&genre_slug_for_value(&1, genres))
    |> Enum.reject(&is_nil/1)
  end

  defp selected_genre_slugs(_, _), do: []

  defp genre_slug_for_value(value, genres) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> genre_slug_for_value(id, genres)
      _ -> Genre.slug(value)
    end
  end

  defp genre_slug_for_value(value, genres) when is_integer(value) do
    genres
    |> Enum.find(&(&1.id == value))
    |> Genre.slug()
  end

  defp genre_slug_for_value(_, _), do: nil

  defp filter_value_present?(nil), do: false
  defp filter_value_present?(""), do: false
  defp filter_value_present?([]), do: false
  defp filter_value_present?([""]), do: false
  defp filter_value_present?(_), do: true

  defp sort_param_non_default?(raw), do: raw not in [nil, "", "release_date_desc"]

  defp hidden_filter_keys(%{kind: :list}), do: ["lists"]
  defp hidden_filter_keys(%{kind: "list"}), do: ["lists"]
  defp hidden_filter_keys(%{kind: :festival}), do: ["festivals"]
  defp hidden_filter_keys(%{kind: "festival"}), do: ["festivals"]
  defp hidden_filter_keys(%{kind: :company}), do: ["companies"]
  defp hidden_filter_keys(%{kind: "company"}), do: ["companies"]
  defp hidden_filter_keys(_), do: []
end
