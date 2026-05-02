defmodule CinegraphWeb.AdminHealthLive.Components do
  @moduledoc """
  Function components for the `/admin/health` dashboard (#723).

  All data flows through `Cinegraph.Health.*` — components take already-shaped
  maps and render. No DB calls here.
  """
  use Phoenix.Component

  @doc """
  Status pill — small badge showing GREEN / AMBER / RED / UNKNOWN.

  ## Examples

      <.verdict_pill status={:green} />
      <.verdict_pill status={:amber} label="warning" />
  """
  attr :status, :atom, default: :unknown, values: [:green, :amber, :red, :unknown]
  attr :label, :string, default: nil
  attr :class, :string, default: ""

  def verdict_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold uppercase tracking-wide",
      pill_classes(@status),
      @class
    ]}>
      <span class={["w-2 h-2 rounded-full mr-2", dot_classes(@status)]}></span>
      {@label || pill_label(@status)}
    </span>
    """
  end

  @doc """
  Hero verdict band — large status indicator at the top of the page.

  ## Slots

    * Inner block renders the right-side controls (refresh button, timestamp)
  """
  attr :status, :atom, required: true, values: [:green, :amber, :red, :unknown]
  attr :worst_check, :map, default: nil
  attr :generated_at, DateTime, default: nil
  slot :controls

  def hero_band(assigns) do
    ~H"""
    <div class={["rounded-lg p-6 mb-6 border", hero_band_classes(@status)]}>
      <div class="flex items-center justify-between flex-wrap gap-3">
        <div class="flex items-center gap-4">
          <.verdict_pill status={@status} class="text-base px-4 py-2" />
          <div>
            <h1 class="text-xl font-semibold">{hero_headline(@status)}</h1>
            <p :if={@worst_check} class="text-sm opacity-80 mt-1">
              Worst: <span class="font-medium">{format_check_name(@worst_check)}</span>
              <span :if={@worst_check[:affected_pct]} class="ml-1">
                ({@worst_check.affected_pct}%)
              </span>
            </p>
          </div>
        </div>
        <div class="flex items-center gap-3">
          <span :if={@generated_at} class="text-xs opacity-70">
            {format_dt(@generated_at)}
          </span>
          {render_slot(@controls)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Activity stat tile — label, count, and a 7-day SVG sparkline.

  ## Examples

      <.stat_tile label="Movies+" count={142} sparkline={[10, 15, 22, 30, 24, 18, 12]} />
  """
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :sparkline, :list, default: []
  attr :tone, :atom, default: :blue, values: [:blue, :green, :amber, :purple, :zinc]

  def stat_tile(assigns) do
    ~H"""
    <div class={["rounded-lg p-4 border", tile_classes(@tone)]}>
      <div class="text-xs uppercase tracking-wide font-medium opacity-80">{@label}</div>
      <div class="text-3xl font-bold mt-1">{format_int(@count)}</div>
      <div class="mt-2 h-6">
        <.sparkline points={@sparkline} stroke={tile_stroke(@tone)} />
      </div>
    </div>
    """
  end

  @doc """
  Inline SVG sparkline. Takes a list of integers; auto-normalizes.

  Renders a 70x20 viewBox path. Empty / 1-element lists render an empty SVG
  (no error).
  """
  attr :points, :list, default: []
  attr :stroke, :string, default: "currentColor"
  attr :width, :integer, default: 70
  attr :height, :integer, default: 20

  def sparkline(assigns) do
    polyline =
      case build_sparkline_points(assigns.points, assigns.width, assigns.height) do
        nil -> nil
        coords -> Enum.map_join(coords, " ", fn {x, y} -> "#{x},#{y}" end)
      end

    assigns = assign(assigns, :polyline, polyline)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class="w-full h-full"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <polyline
        :if={@polyline}
        points={@polyline}
        fill="none"
        stroke={@stroke}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
      />
    </svg>
    """
  end

  @doc """
  Drift card — title, headline metric, top-N signals, "View details" link.

  Used for each domain on the main page (People, Movies, Festivals, Ratings).
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
  Per-queue Oban state strip. Takes the snapshot map from
  `Cinegraph.Health.Queues.snapshot/0`.
  """
  attr :snapshot, :any, required: true

  def queue_strip(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-4">
      <%= case @snapshot do %>
        <% {:error, msg} -> %>
          <p class="text-sm text-zinc-700">Queue snapshot unavailable: {msg}</p>
        <% %{queues: queues, total_failures_last_hour: total_fail} -> %>
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-sm uppercase tracking-wide font-semibold text-zinc-500">
              <a
                href="/admin/oban"
                class="hover:text-zinc-900 hover:underline inline-flex items-center gap-1"
              >
                Queues <span aria-hidden="true">→</span>
              </a>
            </h3>
            <span :if={total_fail > 0} class="text-xs font-mono text-red-700">
              {total_fail} failures last hour
            </span>
          </div>
          <div class="overflow-x-auto">
            <table class="min-w-full text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="text-left py-1 pr-3 font-medium">queue</th>
                  <th class="text-right py-1 px-2 font-medium">avail</th>
                  <th class="text-right py-1 px-2 font-medium">exec</th>
                  <th class="text-right py-1 px-2 font-medium">retry</th>
                  <th class="text-right py-1 px-2 font-medium">disc</th>
                  <th class="text-right py-1 px-2 font-medium">fail/hr</th>
                  <th class="text-right py-1 px-2 font-medium">longest(s)</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={q <- queues} class="border-t border-zinc-100">
                  <td class="py-1 pr-3 font-mono text-zinc-800">{q.name}</td>
                  <td class="py-1 px-2 text-right font-mono">{q.available}</td>
                  <td class="py-1 px-2 text-right font-mono">{q.executing}</td>
                  <td class="py-1 px-2 text-right font-mono">{q.retryable}</td>
                  <td class="py-1 px-2 text-right font-mono">{q.discarded}</td>
                  <td class={[
                    "py-1 px-2 text-right font-mono",
                    q.failures_last_hour > 0 && "text-red-700 font-semibold"
                  ]}>
                    {q.failures_last_hour}
                  </td>
                  <td class="py-1 px-2 text-right font-mono">{q.longest_running_seconds}</td>
                </tr>
              </tbody>
            </table>
          </div>
        <% _ -> %>
          <p class="text-sm text-zinc-500">No queue data.</p>
      <% end %>
    </div>
    """
  end

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
          <svg viewBox={"0 0 #{@width} #{@height}"} class="w-full h-32" preserveAspectRatio="none">
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

  # ===== private =====

  defp pill_classes(:green), do: "bg-green-100 text-green-800"
  defp pill_classes(:amber), do: "bg-amber-100 text-amber-800"
  defp pill_classes(:red), do: "bg-red-100 text-red-800"
  defp pill_classes(_), do: "bg-zinc-100 text-zinc-700"

  defp dot_classes(:green), do: "bg-green-500"
  defp dot_classes(:amber), do: "bg-amber-500"
  defp dot_classes(:red), do: "bg-red-500"
  defp dot_classes(_), do: "bg-zinc-400"

  defp pill_label(:green), do: "Healthy"
  defp pill_label(:amber), do: "Warning"
  defp pill_label(:red), do: "Critical"
  defp pill_label(_), do: "Unknown"

  defp hero_band_classes(:green), do: "bg-green-50 border-green-200 text-green-900"
  defp hero_band_classes(:amber), do: "bg-amber-50 border-amber-200 text-amber-900"
  defp hero_band_classes(:red), do: "bg-red-50 border-red-200 text-red-900"
  defp hero_band_classes(_), do: "bg-zinc-50 border-zinc-200 text-zinc-900"

  defp hero_headline(:green), do: "All systems in sync"
  defp hero_headline(:amber), do: "Some drift detected"
  defp hero_headline(:red), do: "Critical drift — investigate"
  defp hero_headline(_), do: "Status unknown"

  defp tile_classes(:blue), do: "bg-blue-50 text-blue-900 border-blue-200"
  defp tile_classes(:green), do: "bg-green-50 text-green-900 border-green-200"
  defp tile_classes(:amber), do: "bg-amber-50 text-amber-900 border-amber-200"
  defp tile_classes(:purple), do: "bg-purple-50 text-purple-900 border-purple-200"
  defp tile_classes(:zinc), do: "bg-zinc-50 text-zinc-900 border-zinc-200"

  defp tile_stroke(:blue), do: "rgb(37 99 235)"
  defp tile_stroke(:green), do: "rgb(22 163 74)"
  defp tile_stroke(:amber), do: "rgb(217 119 6)"
  defp tile_stroke(:purple), do: "rgb(147 51 234)"
  defp tile_stroke(:zinc), do: "rgb(82 82 91)"

  defp card_border(:green), do: "border-green-200"
  defp card_border(:amber), do: "border-amber-300"
  defp card_border(:red), do: "border-red-300"
  defp card_border(_), do: "border-zinc-200"

  defp ngettext_check(1), do: "check"
  defp ngettext_check(_), do: "checks"

  defp format_check_name(%{domain: d, check: c}),
    do: "#{d}/#{c}" |> String.replace("_", " ")

  defp format_check_name(_), do: ""

  defp format_dt(nil), do: ""
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S UTC")

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(",")
    |> List.flatten()
    |> Enum.reverse()
    |> Enum.join()
  end

  defp format_int(other), do: to_string(other)

  # Build SVG polyline coordinates for the given values.
  # Returns nil for ≤1 points (nothing to draw).
  defp build_sparkline_points(points, _w, _h) when length(points) < 2, do: nil

  defp build_sparkline_points(points, width, height) do
    {min, max} = Enum.min_max(points)
    range = if max == min, do: 1, else: max - min
    n = length(points)
    step = if n > 1, do: width / (n - 1), else: 0

    points
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      x = i * step
      # SVG y grows downward — invert
      y = height - (v - min) / range * height
      {Float.round(x, 1), Float.round(y, 1)}
    end)
  end
end
