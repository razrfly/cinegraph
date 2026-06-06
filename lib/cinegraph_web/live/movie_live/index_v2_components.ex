defmodule CinegraphWeb.MovieLive.IndexV2Components do
  @moduledoc """
  Render-only facade for the V2 movie discovery page.

  Focused component groups live under `IndexV2Components.*`; this module keeps
  the stable API used by the LiveView and component tests.
  """
  use Phoenix.Component

  alias CinegraphWeb.MovieLive.IndexV2Components.ActiveChips
  alias CinegraphWeb.MovieLive.IndexV2Components.CardHelpers
  alias CinegraphWeb.MovieLive.IndexV2Components.Filters
  alias CinegraphWeb.MovieLive.IndexV2Drawer

  attr :total_count, :integer, default: nil

  def hero(assigns) do
    ~H"""
    <section class="mb-8 lg:mb-12">
      <h1 class="font-display italic text-[44px] sm:text-[56px] lg:text-[72px] tracking-[-.02em] text-balance text-mist-950 dark:text-white leading-[1.02]">
        Movies.
      </h1>
      <p class="text-[15px] text-mist-700 dark:text-mist-300 mt-2 max-w-2xl">
        {format_count(@total_count)} films across canonical lists, festivals, and critical canon.
      </p>
      <div class="flex items-center gap-3 mt-1.5 text-[14px] text-mist-700 dark:text-mist-300">
        <a
          href="/algorithms"
          class="underline decoration-mist-950/15 dark:decoration-white/15 underline-offset-4 hover:text-mist-950 dark:hover:text-white"
        >
          Tunable scoring →
        </a>
        <span class="text-mist-500 dark:text-mist-400" aria-hidden="true">·</span>
        <button
          type="button"
          phx-click="show_scoring_info"
          class="underline decoration-mist-950/15 dark:decoration-white/15 underline-offset-4 hover:text-mist-950 dark:hover:text-white bg-transparent border-0 p-0 cursor-pointer font-[inherit] text-[14px] text-mist-700 dark:text-mist-300"
        >
          How we score?
        </button>
      </div>
    </section>
    """
  end

  attr :search_term, :string, default: ""
  attr :sort_options, :list, required: true
  attr :sort_criteria, :string, default: "release_date"
  attr :sort_direction, :atom, default: :desc
  attr :sort_is_preset, :boolean, default: false
  attr :filter_options, :map, required: true
  attr :params, :map, required: true
  attr :active_filter_count, :integer, default: 0
  attr :scope, :map, default: %{}

  def filters(assigns), do: Filters.filters(assigns)

  attr :params, :map, required: true
  attr :filter_options, :map, required: true
  attr :sort_options, :list, required: true
  attr :scope, :map, default: %{}

  def active_filters(assigns), do: ActiveChips.active_filters(assigns)

  attr :movies, :list, required: true
  attr :active_lens_key, :any, default: nil

  def results(assigns), do: CardHelpers.results(assigns)

  attr :movies, :list, required: true
  attr :meta, :any, required: true
  attr :params, :map, required: true
  attr :filter_options, :map, required: true
  attr :search_term, :string, default: ""
  attr :sort_options, :list, required: true
  attr :sort_criteria, :string, default: "release_date"
  attr :sort_direction, :atom, default: :desc
  attr :sort_is_preset, :boolean, default: false
  attr :active_lens_key, :any, default: nil
  attr :show_drawer, :boolean, default: false
  attr :show_scoring_info, :boolean, default: false
  attr :scope, :map, default: %{}

  def discovery_body(assigns) do
    active_filter_count = active_filter_count(assigns.params, assigns.scope)

    assigns =
      assigns
      |> assign(:active_filter_count, active_filter_count)
      |> assign(:selected_lists, list_param(assigns.params, "lists"))
      |> assign(:selected_festivals, list_param(assigns.params, "festivals"))
      |> assign(:selected_people, selected_people_ids(assigns.params))

    ~H"""
    <.filters
      search_term={@search_term}
      sort_options={@sort_options}
      sort_criteria={@sort_criteria}
      sort_direction={@sort_direction}
      sort_is_preset={@sort_is_preset}
      filter_options={@filter_options}
      params={@params}
      scope={@scope}
      active_filter_count={@active_filter_count}
    />
    <.active_filters
      params={@params}
      filter_options={@filter_options}
      sort_options={@sort_options}
      scope={@scope}
    />
    <.results movies={@movies} active_lens_key={@active_lens_key} />
    <.pagination meta={@meta} />

    <IndexV2Drawer.filters_drawer
      show={@show_drawer}
      filter_options={@filter_options}
      selected_lists={@selected_lists}
      selected_festivals={@selected_festivals}
      selected_people={@selected_people}
      people_match={@params["people_match"]}
      selected_decade={@params["decade"]}
      rating_preset={@params["rating_preset"]}
      max_age={@params["max_age"]}
      show_unreleased={@params["show_unreleased"]}
      active_filter_count={@active_filter_count}
      scope={@scope}
    />
    <IndexV2Drawer.scoring_modal show={@show_scoring_info} />
    """
  end

  attr :meta, :any, required: true

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@meta && @meta.total_pages && @meta.total_pages > 1}
      class="flex items-center justify-between gap-4 pt-6 border-t border-mist-950/10 dark:border-white/10 text-[13px] text-mist-700 dark:text-mist-300"
    >
      <button
        type="button"
        phx-click="page"
        phx-value-page={max(1, (@meta.current_page || 1) - 1)}
        disabled={(@meta.current_page || 1) <= 1}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 dark:border-white/15 bg-mist-50 dark:bg-mist-900 px-4 py-2 font-medium text-mist-950 dark:text-white hover:bg-mist-950/[0.025] dark:hover:bg-white/5 disabled:opacity-40 disabled:cursor-not-allowed"
      >
        ← Previous
      </button>

      <div class="text-[12px] tabular-nums">
        Page <b class="text-mist-950 dark:text-white font-semibold">{@meta.current_page}</b>
        of <b class="text-mist-950 dark:text-white font-semibold">{@meta.total_pages}</b>
        <span class="text-mist-500 dark:text-mist-400">
          · {format_count(@meta.total_count)} films
        </span>
      </div>

      <button
        type="button"
        phx-click="page"
        phx-value-page={min(@meta.total_pages, (@meta.current_page || 1) + 1)}
        disabled={(@meta.current_page || 1) >= @meta.total_pages}
        class="inline-flex items-center gap-2 rounded-full border border-mist-950/15 dark:border-white/15 bg-mist-50 dark:bg-mist-900 px-4 py-2 font-medium text-mist-950 dark:text-white hover:bg-mist-950/[0.025] dark:hover:bg-white/5 disabled:opacity-40 disabled:cursor-not-allowed"
      >
        Next →
      </button>
    </nav>
    """
  end

  defdelegate active_filter_count(params), to: Filters
  defdelegate active_filter_count(params, scope), to: Filters
  defdelegate list_param(params, key), to: Filters
  defdelegate selected_people_ids(params), to: Filters

  defp format_count(nil), do: "—"

  defp format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
