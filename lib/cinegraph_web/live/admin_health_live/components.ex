defmodule CinegraphWeb.AdminHealthLive.Components do
  @moduledoc """
  Function components specific to the `/admin/health` dashboard (#723).

  Five generic admin primitives — `verdict_pill`, `hero_band`, `stat_tile`,
  `sparkline`, `queue_strip` — moved to
  `CinegraphWeb.Admin.Components.DashboardComponents` in #880 Phase 1.
  This module imports them and adds the homeostasis-specific ones:
  `drift_card`, `drift_drawer`, and the 30-day completeness `trend_chart`.

  All data flows through `Cinegraph.Health.*` — components take already-shaped
  maps and render. No DB calls here.
  """
  use Phoenix.Component

  import CinegraphWeb.Admin.Components.DashboardComponents,
    only: [verdict_pill: 1, format_int: 1]

  @doc """
  Drift card — title, headline metric, top-N signals, "View details" link.

  Used for each domain on the main page (People, Movies, Festivals, Ratings,
  Availability, Collaborations).
  """
  attr :domain, :atom, required: true
  attr :title, :string, required: true
  attr :status, :atom, required: true, values: [:green, :amber, :red, :unknown]
  attr :headline, :string, required: true
  attr :signals, :list, required: true
  attr :unknown_count, :integer, default: 0
  attr :on_open, :string, default: "open_drawer"

  def drift_card(assigns) do
    ~H"""
    <div class={["rounded-lg border p-5 flex flex-col", card_border(@status)]}>
      <div class="flex items-center justify-between mb-3">
        <h3 class="font-semibold uppercase tracking-wide text-sm flex items-center gap-2">
          <span class={["w-2 h-2 rounded-full", dot_classes(@status)]}></span>
          {@title}
        </h3>
        <.verdict_pill status={@status} />
      </div>
      <p class="text-sm text-zinc-700 mb-3">{@headline}</p>
      <p :if={@unknown_count > 0} class="text-xs text-amber-700 italic mb-2">
        ⚠ {@unknown_count} {ngettext_check(@unknown_count)} unavailable — see drawer
      </p>
      <ul class="text-sm space-y-1 flex-1">
        <li :for={signal <- @signals} class="flex items-center justify-between">
          <span class="text-zinc-600 truncate mr-2">{signal.label}</span>
          <span class="font-mono text-zinc-900 whitespace-nowrap">
            {format_int(signal.affected_count)}
            <span class="text-zinc-500 text-xs ml-1">({signal.affected_pct}%)</span>
          </span>
        </li>
      </ul>
      <button
        type="button"
        phx-click={@on_open}
        phx-value-domain={Atom.to_string(@domain)}
        class="mt-4 text-sm font-medium text-blue-700 hover:text-blue-900 self-end"
      >
        View details →
      </button>
    </div>
    """
  end

  @doc """
  Drill-down drawer — slides in from the right with all checks for one
  domain. Each check shows status pill, count/pct, and example rows.
  """
  attr :domain, :atom, required: true
  attr :title, :string, required: true
  attr :checks, :list, required: true
  attr :on_close, :string, default: "close_drawer"
  slot :actions

  def drift_drawer(assigns) do
    ~H"""
    <div class="fixed inset-0 z-40 flex" role="dialog" aria-modal="true">
      <div class="fixed inset-0 bg-zinc-900/40" phx-click={@on_close} aria-label="Close drawer"></div>
      <aside class="ml-auto h-full w-full max-w-2xl bg-white shadow-xl flex flex-col z-50 relative">
        <header class="px-6 py-4 border-b border-zinc-200 flex items-center justify-between">
          <div>
            <p class="text-xs uppercase tracking-wide text-zinc-500 font-semibold">{@domain}</p>
            <h2 class="text-lg font-semibold text-zinc-900">{@title}</h2>
          </div>
          <button
            type="button"
            phx-click={@on_close}
            class="text-zinc-500 hover:text-zinc-900 text-2xl leading-none"
            aria-label="Close"
          >
            ×
          </button>
        </header>

        <div :if={@actions != []} class="px-6 py-4 border-b border-zinc-100 flex flex-wrap gap-2">
          {render_slot(@actions)}
        </div>

        <div class="flex-1 overflow-y-auto px-6 py-4 space-y-6">
          <article :for={check <- @checks} class="border border-zinc-200 rounded-md p-4">
            <header class="flex items-center justify-between mb-2">
              <h3 class="font-mono text-sm text-zinc-900">{check.check}</h3>
              <.verdict_pill status={check.status} />
            </header>
            <p :if={check.blocked_reason} class="text-xs text-amber-700 italic mb-2">
              ⚠ {check.blocked_reason}
            </p>
            <p class="text-sm text-zinc-700">
              <span class="font-semibold">{format_int(check.affected_count)}</span>
              of {format_int(check.total_population)}
              <span class="text-zinc-500">({check.affected_pct}%)</span>
            </p>
            <details :if={check.examples != []} class="mt-3 text-xs">
              <summary class="cursor-pointer text-zinc-600 hover:text-zinc-900">
                {length(check.examples)} example{if length(check.examples) == 1, do: "", else: "s"}
              </summary>
              <ul class="mt-2 space-y-2 font-mono">
                <li
                  :for={ex <- check.examples}
                  class="text-zinc-700 flex items-center justify-between gap-2"
                >
                  <span class="truncate">{format_example(ex)}</span>
                  <button
                    :if={refresh_action_for(@domain) && Map.get(ex, :id)}
                    type="button"
                    phx-click="queue_refresh"
                    phx-value-domain={Atom.to_string(@domain)}
                    phx-value-ids={Map.get(ex, :id)}
                    class="text-blue-600 hover:text-blue-900 text-[11px] whitespace-nowrap"
                  >
                    {refresh_action_label(@domain)}
                  </button>
                </li>
              </ul>
            </details>
          </article>
        </div>
      </aside>
    </div>
    """
  end

  @doc false
  def refresh_action_for(:people), do: :tmdb
  def refresh_action_for(:ratings), do: :omdb
  def refresh_action_for(:availability), do: :availability
  def refresh_action_for(_), do: nil

  @doc false
  def refresh_action_label(:people), do: "Queue TMDb refresh"
  def refresh_action_label(:ratings), do: "Queue OMDb refresh"
  def refresh_action_label(:availability), do: "Queue availability refresh"
  def refresh_action_label(_), do: ""

  @doc """
  30-day completeness trend chart. Renders an SVG line from a list of
  `%{captured_on, payload}` rows. Falls back to a friendly message when
  history is too sparse to plot.
  """
  attr :history, :any, required: true
  attr :width, :integer, default: 700
  attr :height, :integer, default: 120

  def trend_chart(assigns) do
    rows =
      case assigns.history do
        list when is_list(list) -> list
        _ -> []
      end

    series =
      rows
      |> Enum.map(fn r ->
        pct =
          case r do
            %{payload: %{"overall_completeness_pct" => v}} when is_number(v) -> v
            _ -> nil
          end

        %{captured_on: Map.get(r, :captured_on), pct: pct}
      end)
      |> Enum.reject(&is_nil(&1.pct))

    assigns =
      assigns
      |> assign(:series, series)
      |> assign(:polyline, build_chart_polyline(series, assigns.width, assigns.height))

    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-4">
      <div class="flex items-center justify-between mb-3">
        <h3 class="text-sm uppercase tracking-wide font-semibold text-zinc-500">
          30-day completeness
        </h3>
        <span :if={@series != []} class="text-xs font-mono text-zinc-500">
          {length(@series)} day{if length(@series) == 1, do: "", else: "s"}
        </span>
      </div>

      <%= cond do %>
        <% @series == [] -> %>
          <p class="text-sm text-zinc-500 italic py-6 text-center">
            Capturing — first daily snapshot lands tomorrow at 05:05 UTC.
          </p>
        <% length(@series) == 1 -> %>
          <p class="text-sm text-zinc-700 py-6 text-center">
            One snapshot so far:
            <span class="font-mono">{Float.round(hd(@series).pct * 1.0, 2)}%</span>
            (needs ≥2 days to draw a line — chart starts tomorrow)
          </p>
        <% true -> %>
          <% {min_pct, max_pct} = pct_range(@series) %>
          <svg
            viewBox={"0 0 #{@width} #{@height}"}
            class="w-full h-32"
            preserveAspectRatio="none"
          >
            <polyline points={@polyline} fill="none" stroke="rgb(37 99 235)" stroke-width="2" />
          </svg>
          <div class="flex justify-between text-xs text-zinc-500 mt-1 font-mono">
            <span>{format_date(List.first(@series).captured_on)} · {min_pct}%</span>
            <span>{format_date(List.last(@series).captured_on)} · {max_pct}%</span>
          </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Returns Tailwind classes for a given status atom — useful when you need
  classes outside a component.
  """
  def status_classes(:green), do: "bg-green-50 text-green-800 border-green-200"
  def status_classes(:amber), do: "bg-amber-50 text-amber-800 border-amber-200"
  def status_classes(:red), do: "bg-red-50 text-red-800 border-red-200"
  def status_classes(_), do: "bg-zinc-50 text-zinc-700 border-zinc-200"

  # ===== private =====

  defp card_border(:green), do: "border-green-200"
  defp card_border(:amber), do: "border-amber-300"
  defp card_border(:red), do: "border-red-300"
  defp card_border(_), do: "border-zinc-200"

  defp dot_classes(:green), do: "bg-green-500"
  defp dot_classes(:amber), do: "bg-amber-500"
  defp dot_classes(:red), do: "bg-red-500"
  defp dot_classes(_), do: "bg-zinc-400"

  defp ngettext_check(1), do: "check"
  defp ngettext_check(_), do: "checks"

  defp format_example(%{} = ex) do
    id = Map.get(ex, :id) || Map.get(ex, "id")

    name_or_title =
      Map.get(ex, :name) || Map.get(ex, :title) || Map.get(ex, "name") || Map.get(ex, "title")

    reason = Map.get(ex, :reason) || Map.get(ex, "reason") || ""

    parts =
      [
        if(id, do: "##{id}"),
        name_or_title,
        if(reason != "", do: "— #{reason}")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " ")
  end

  defp format_example(other), do: inspect(other)

  defp build_chart_polyline(series, _w, _h) when length(series) < 2, do: ""

  defp build_chart_polyline(series, width, height) do
    pcts = Enum.map(series, & &1.pct)
    {min, max} = Enum.min_max(pcts)
    range = if max == min, do: 1, else: max - min
    n = length(pcts)
    step = if n > 1, do: width / (n - 1), else: 0
    pad = 4

    pcts
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = i * step
      y = pad + (height - 2 * pad) - (v - min) / range * (height - 2 * pad)
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
  end

  defp pct_range(series) do
    pcts = Enum.map(series, & &1.pct)
    {min, max} = Enum.min_max(pcts)
    {Float.round(min * 1.0, 2), Float.round(max * 1.0, 2)}
  end

  defp format_date(%Date{} = d), do: Date.to_iso8601(d)
  defp format_date(d) when is_binary(d), do: d
  defp format_date(_), do: ""
end
