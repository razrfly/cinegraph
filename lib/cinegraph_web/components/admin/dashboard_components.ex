defmodule CinegraphWeb.Admin.Components.DashboardComponents do
  @moduledoc """
  Reusable function components for cinegraph's admin dashboard.

  Components:
  - `stat_card/1` — single metric with optional trend indicator
  - `source_row/1` — row with name, count, and health indicator
  - `health_badge/1` — colored badge based on score
  - `loading_skeleton/1` — placeholder during async loading
  - `section_header/1` — section title + optional action link

  Ported from eventasaurus's `EventasaurusWeb.Admin.Components.DashboardComponents`.
  Reuses `CinegraphWeb.CoreComponents.icon/1` (auto-imported via `:html_helpers`)
  for heroicons rendering — no local icon implementation.
  """
  use Phoenix.Component

  @doc """
  Renders a stat card with title, value, and optional metadata.

  ## Examples

      <.stat_card title="Total films" value="12,345" color={:blue} />
      <.stat_card
        title="Coverage"
        value="95.2%"
        color={:green}
        trend={:up}
        trend_value="+2.3%"
      />
  """
  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, default: nil
  attr :icon, :string, default: nil
  attr :color, :atom, default: :blue
  attr :link, :string, default: nil
  attr :trend, :atom, default: nil
  attr :trend_value, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border p-4 shadow-sm transition-all",
      color_classes(@color),
      @link && "hover:shadow-md cursor-pointer"
    ]}>
      <%= if @link do %>
        <.link navigate={@link} class="block">
          <.stat_card_content {assigns} />
        </.link>
      <% else %>
        <.stat_card_content {assigns} />
      <% end %>
    </div>
    """
  end

  defp stat_card_content(assigns) do
    ~H"""
    <div class="flex items-start justify-between">
      <div class="flex-1">
        <p class="text-sm font-medium text-gray-600">{@title}</p>
        <p class="mt-1 text-2xl font-semibold text-gray-900">{@value}</p>
        <%= if @subtitle do %>
          <p class="mt-1 text-xs text-gray-500">{@subtitle}</p>
        <% end %>
      </div>
      <div class="flex flex-col items-end">
        <%= if @icon do %>
          <div class={["rounded-full p-2", icon_bg_class(@color)]}>
            <CinegraphWeb.CoreComponents.icon name={@icon} class="h-5 w-5" />
          </div>
        <% end %>
        <%= if @trend do %>
          <div class={["mt-2 flex items-center text-xs font-medium", trend_color(@trend)]}>
            <.trend_icon trend={@trend} />
            <span class="ml-1">{@trend_value}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :trend, :atom, required: true

  defp trend_icon(%{trend: :up} = assigns) do
    ~H"""
    <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M5 10l7-7m0 0l7 7m-7-7v18"
      />
    </svg>
    """
  end

  defp trend_icon(%{trend: :down} = assigns) do
    ~H"""
    <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 14l-7 7m0 0l-7-7m7 7V3"
      />
    </svg>
    """
  end

  defp trend_icon(%{trend: :flat} = assigns) do
    ~H"""
    <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M5 12h14"
      />
    </svg>
    """
  end

  defp trend_icon(assigns), do: ~H""

  defp trend_color(:up), do: "text-green-600"
  defp trend_color(:down), do: "text-red-600"
  defp trend_color(:flat), do: "text-gray-500"
  defp trend_color(_), do: "text-gray-500"

  defp color_classes(:blue), do: "bg-blue-50 border-blue-200"
  defp color_classes(:green), do: "bg-green-50 border-green-200"
  defp color_classes(:yellow), do: "bg-yellow-50 border-yellow-200"
  defp color_classes(:red), do: "bg-red-50 border-red-200"
  defp color_classes(:purple), do: "bg-purple-50 border-purple-200"
  defp color_classes(:gray), do: "bg-gray-50 border-gray-200"
  defp color_classes(_), do: "bg-white border-gray-200"

  defp icon_bg_class(:blue), do: "bg-blue-100 text-blue-600"
  defp icon_bg_class(:green), do: "bg-green-100 text-green-600"
  defp icon_bg_class(:yellow), do: "bg-yellow-100 text-yellow-600"
  defp icon_bg_class(:red), do: "bg-red-100 text-red-600"
  defp icon_bg_class(:purple), do: "bg-purple-100 text-purple-600"
  defp icon_bg_class(:gray), do: "bg-gray-100 text-gray-600"
  defp icon_bg_class(_), do: "bg-gray-100 text-gray-600"

  @doc """
  Renders a source row with name, event count, and health indicator.

  ## Examples

      <.source_row name="Cannes" event_count={1234} health_score={95.2} />
  """
  attr :name, :string, required: true
  attr :event_count, :integer, default: 0
  attr :health_score, :float, default: nil
  attr :last_sync, :any, default: nil
  attr :link, :string, default: nil

  def source_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-3 px-4 hover:bg-gray-50 rounded-lg transition-colors">
      <div class="flex items-center space-x-3">
        <%= if @health_score do %>
          <.health_badge score={@health_score} />
        <% end %>
        <div>
          <%= if @link do %>
            <.link navigate={@link} class="font-medium text-gray-900 hover:text-blue-600">
              {@name}
            </.link>
          <% else %>
            <span class="font-medium text-gray-900">{@name}</span>
          <% end %>
          <%= if @last_sync do %>
            <p class="text-xs text-gray-500">Last sync: {format_time(@last_sync)}</p>
          <% end %>
        </div>
      </div>
      <div class="text-right">
        <span class="text-lg font-semibold text-gray-700">{format_number(@event_count)}</span>
        <span class="text-xs text-gray-500 ml-1">events</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a colored health badge based on score.

  ## Examples

      <.health_badge score={95.2} />
      <.health_badge score={75.0} size={:lg} />
  """
  attr :score, :float, required: true
  attr :size, :atom, default: :sm

  def health_badge(assigns) do
    ~H"""
    <div class={[
      "rounded-full flex items-center justify-center font-medium",
      health_badge_color(@score),
      health_badge_size(@size)
    ]}>
      {round(@score)}
    </div>
    """
  end

  defp health_badge_color(score) when score >= 95, do: "bg-green-100 text-green-800"
  defp health_badge_color(score) when score >= 85, do: "bg-yellow-100 text-yellow-800"
  defp health_badge_color(score) when score >= 70, do: "bg-orange-100 text-orange-800"
  defp health_badge_color(_score), do: "bg-red-100 text-red-800"

  defp health_badge_size(:sm), do: "h-8 w-8 text-xs"
  defp health_badge_size(:md), do: "h-10 w-10 text-sm"
  defp health_badge_size(:lg), do: "h-12 w-12 text-base"
  defp health_badge_size(_), do: "h-8 w-8 text-xs"

  @doc """
  Renders a loading skeleton placeholder.

  ## Examples

      <.loading_skeleton type={:card} />
      <.loading_skeleton type={:row} />
      <.loading_skeleton type={:text} />
  """
  attr :type, :atom, default: :card

  def loading_skeleton(assigns) do
    ~H"""
    <%= case @type do %>
      <% :card -> %>
        <div class="rounded-lg border border-gray-200 p-4 animate-pulse">
          <div class="h-4 bg-gray-200 rounded w-1/3 mb-2"></div>
          <div class="h-8 bg-gray-200 rounded w-1/2"></div>
        </div>
      <% :row -> %>
        <div class="flex items-center justify-between py-3 px-4 animate-pulse">
          <div class="flex items-center space-x-3">
            <div class="h-8 w-8 bg-gray-200 rounded-full"></div>
            <div class="h-4 bg-gray-200 rounded w-24"></div>
          </div>
          <div class="h-6 bg-gray-200 rounded w-16"></div>
        </div>
      <% :text -> %>
        <div class="animate-pulse">
          <div class="h-4 bg-gray-200 rounded w-full mb-2"></div>
          <div class="h-4 bg-gray-200 rounded w-3/4"></div>
        </div>
      <% _ -> %>
        <div class="h-4 bg-gray-200 rounded w-full animate-pulse"></div>
    <% end %>
    """
  end

  @doc """
  Renders a section header with optional action link.

  ## Examples

      <.section_header title="System Health" subtitle="Last 24 hours" />
      <.section_header
        title="Recent imports"
        action_label="View all"
        action_link="/admin/imports"
      />
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :action_label, :string, default: nil
  attr :action_link, :string, default: nil

  def section_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <div>
        <h2 class="text-lg font-semibold text-gray-900">{@title}</h2>
        <%= if @subtitle do %>
          <p class="text-sm text-gray-500">{@subtitle}</p>
        <% end %>
      </div>
      <%= if @action_label && @action_link do %>
        <.link
          navigate={@action_link}
          class="text-sm text-blue-600 hover:text-blue-800 font-medium"
        >
          {@action_label} &rarr;
        </.link>
      <% end %>
    </div>
    """
  end

  # Helpers

  defp format_number(nil), do: "0"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join(&1, ""))
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num) when is_float(num) do
    num
    |> Float.round(1)
    |> Float.to_string()
  end

  defp format_number(num), do: "#{num}"

  defp format_time(nil), do: "Never"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_time(_), do: "Unknown"

  # ============================================================================
  # Homeostasis-style components (ported from AdminHealthLive.Components)
  #
  # These were originally local to /admin/health (#723) but they're reusable
  # KPI/status primitives for any admin page that needs a status pill, hero
  # banner, KPI tile with sparkline, line-chart sparkline, or queue-state
  # table. Phase 1 of #880 promotes them to the shared admin namespace.
  # ============================================================================

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
  Hero verdict band — large status indicator at the top of a page.

  ## Slots

    * `:controls` — right-side controls (refresh button, timestamp)
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
            {format_pill_dt(@generated_at)}
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
  Inline SVG line-chart sparkline. Takes a list of integers; auto-normalizes.

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
  Queue state table — renders a `Cinegraph.Health.Queues.snapshot/0` shape.
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

  # ===== Public helpers (used by AdminHealthLive's local components too) =====

  @doc "Formats an integer with thousands separators."
  def format_int(n) when is_integer(n) do
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

  def format_int(other), do: to_string(other)

  # ===== Private helpers =====

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

  defp format_check_name(%{domain: d, check: c}),
    do: "#{d}/#{c}" |> String.replace("_", " ")

  defp format_check_name(_), do: ""

  defp format_pill_dt(nil), do: ""
  defp format_pill_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S UTC")

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
      y = height - (v - min) / range * height
      {Float.round(x, 1), Float.round(y, 1)}
    end)
  end
end
