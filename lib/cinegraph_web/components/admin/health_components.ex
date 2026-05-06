defmodule CinegraphWeb.Admin.Components.HealthComponents do
  @moduledoc """
  Domain-agnostic health/status primitives for cinegraph's admin pages.

  Subset port from eventasaurus's `EventasaurusWeb.Admin.Components.HealthComponents`
  — only the components that don't carry scraping/source-table-domain coupling.
  Skipped: `source_table_*`, `provider_avatar`, `provider_identity`,
  `job_history_timeline`, `health_metric_card`, `health_component_bar`,
  `system_health_chart`, the legacy emoji `stat_card`, and the admin-dashboard
  `admin_stat_card` / `admin_icon` (kpi_card in `AdminComponents` covers that).

  Components included:

  - `health_score_pill/1` — compact status pill (emoji + score)
  - `progress_bar/1` — configurable progress bar
  - `sparkline/1` — 7-day mini bar chart
  - `trend_indicator/1` — arrow + percentage
  - `status_badge/1` — job-state badge (success/failure/cancelled/etc.)

  Plus the public class/glyph helpers used to colorize status indicators.
  """
  use Phoenix.Component

  # ============================================================================
  # Health Score Pill
  # ============================================================================

  @doc """
  Renders a compact health score pill with status color.

  ## Examples

      <.health_score_pill score={85} status={:healthy} />
      <.health_score_pill score={45} status={:critical} show_score={false} />
  """
  attr :score, :integer, default: 0
  attr :status, :atom, required: true
  attr :show_score, :boolean, default: true
  attr :size, :atom, default: :md

  def health_score_pill(assigns) do
    {emoji, label, _color} = status_indicator(assigns.status)

    size_classes =
      case assigns.size do
        :sm -> "px-2 py-0.5 text-xs"
        :md -> "px-2.5 py-0.5 text-xs"
        :lg -> "px-3 py-1 text-sm"
        _ -> "px-2.5 py-0.5 text-xs"
      end

    assigns =
      assigns
      |> assign(:emoji, emoji)
      |> assign(:label, label)
      |> assign(:size_classes, size_classes)
      |> assign(:status_classes, status_classes(assigns.status))

    ~H"""
    <span class={"inline-flex items-center rounded-full font-medium #{@size_classes} #{@status_classes}"}>
      {@emoji}
      <%= if @show_score do %>
        <span class="ml-1">{@score}%</span>
      <% else %>
        <span class="ml-1">{@label}</span>
      <% end %>
    </span>
    """
  end

  # ============================================================================
  # Progress Bar
  # ============================================================================

  @doc """
  Renders a configurable progress bar.

  ## Examples

      <.progress_bar value={75} />
      <.progress_bar value={45} color={:red} show_label />
      <.progress_bar value={120} max={200} color={:green} />
  """
  attr :value, :integer, default: 0
  attr :max, :integer, default: 100
  attr :color, :atom, default: :blue
  attr :size, :atom, default: :md
  attr :show_label, :boolean, default: false
  attr :animate, :boolean, default: true

  def progress_bar(assigns) do
    percentage = min(100, round(assigns.value / max(assigns.max, 1) * 100))

    height_class =
      case assigns.size do
        :xs -> "h-1"
        :sm -> "h-1.5"
        :md -> "h-2"
        :lg -> "h-3"
        _ -> "h-2"
      end

    bar_color = bar_color_class(assigns.color)
    animation = if assigns.animate, do: "transition-all duration-300", else: ""

    assigns =
      assigns
      |> assign(:percentage, percentage)
      |> assign(:height_class, height_class)
      |> assign(:bar_color, bar_color)
      |> assign(:animation, animation)

    ~H"""
    <div class="w-full">
      <%= if @show_label do %>
        <div class="flex justify-between items-center mb-1">
          <span class="text-xs text-gray-500"></span>
          <span class="text-xs font-medium text-gray-700">{@percentage}%</span>
        </div>
      <% end %>
      <div class={"w-full bg-gray-200 rounded-full #{@height_class}"}>
        <div
          class={"#{@bar_color} #{@height_class} rounded-full #{@animation}"}
          style={"width: #{@percentage}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  # NOTE: The bar-chart `sparkline/1` originally ported from eventasaurus
  # was removed in #880 Phase 1 to avoid name collision with the line-chart
  # `sparkline/1` promoted from AdminHealthLive into DashboardComponents.
  # Use `CinegraphWeb.Admin.Components.DashboardComponents.sparkline/1` —
  # `<.sparkline points={...} stroke="..." />`.

  # ============================================================================
  # Trend Indicator
  # ============================================================================

  @doc """
  Renders a trend indicator with arrow and percentage.

  ## Examples

      <.trend_indicator change={15} />
      <.trend_indicator change={-8} />
      <.trend_indicator change={0} show_arrow={false} />
  """
  attr :change, :integer, required: true
  attr :show_arrow, :boolean, default: true
  attr :size, :atom, default: :md

  def trend_indicator(assigns) do
    {arrow, color} =
      cond do
        assigns.change > 0 -> {"↑", "text-green-600"}
        assigns.change < 0 -> {"↓", "text-red-600"}
        true -> {"→", "text-gray-500"}
      end

    size_class =
      case assigns.size do
        :sm -> "text-xs"
        :md -> "text-sm"
        :lg -> "text-base"
        _ -> "text-sm"
      end

    formatted = format_change(assigns.change)

    assigns =
      assigns
      |> assign(:arrow, arrow)
      |> assign(:color, color)
      |> assign(:size_class, size_class)
      |> assign(:formatted, formatted)

    ~H"""
    <span class={"font-medium #{@color} #{@size_class}"}>
      <%= if @show_arrow do %>
        {@arrow}
      <% end %>
      {@formatted}
    </span>
    """
  end

  # ============================================================================
  # Status Badge (for job states)
  # ============================================================================

  @doc """
  Renders a status badge for Oban job states.

  ## Examples

      <.status_badge state="success" />
      <.status_badge state="failure" />
  """
  attr :state, :any, required: true

  def status_badge(assigns) do
    assigns = assign(assigns, :state, normalize_badge_state(assigns.state))

    ~H"""
    <span class={badge_classes(@state)}>
      {badge_icon(@state)} {badge_label(@state)}
    </span>
    """
  end

  # ============================================================================
  # Public class/glyph helpers
  # ============================================================================

  @doc "Returns `{emoji, label, text_color_class}` for a health status atom."
  @spec status_indicator(atom()) :: {String.t(), String.t(), String.t()}
  def status_indicator(:healthy), do: {"🟢", "Healthy", "text-green-600"}
  def status_indicator(:warning), do: {"🟡", "Warning", "text-yellow-600"}
  def status_indicator(:critical), do: {"🔴", "Critical", "text-red-600"}
  def status_indicator(:disabled), do: {"⚪", "Disabled", "text-gray-400"}
  def status_indicator(:unknown), do: {"⚫", "Unknown", "text-gray-500"}
  def status_indicator(_), do: {"⚫", "Unknown", "text-gray-500"}

  @doc "Returns CSS classes for status backgrounds and text."
  @spec status_classes(atom()) :: String.t()
  def status_classes(:healthy), do: "bg-green-100 text-green-800"
  def status_classes(:warning), do: "bg-yellow-100 text-yellow-800"
  def status_classes(:critical), do: "bg-red-100 text-red-800"
  def status_classes(:disabled), do: "bg-gray-100 text-gray-800"
  def status_classes(:unknown), do: "bg-gray-100 text-gray-600"
  def status_classes(_), do: "bg-gray-100 text-gray-600"

  @doc "Calculates sparkline bar heights from data on a 0-100 scale."
  @spec sparkline_heights(list()) :: list(number())
  def sparkline_heights(data) when is_list(data) and length(data) > 0 do
    max_val = Enum.max(data, fn -> 1 end)
    max_val = if max_val == 0, do: 1, else: max_val

    Enum.map(data, fn val ->
      percentage = round(val / max_val * 100)
      if val > 0, do: max(percentage, 10), else: 0
    end)
  end

  def sparkline_heights(_), do: List.duplicate(0, 7)

  @doc "Formats a change value with `+` prefix for positive numbers."
  @spec format_change(number()) :: String.t()
  def format_change(change) when change > 0, do: "+#{change}%"
  def format_change(change), do: "#{change}%"

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp bar_color_class(:blue), do: "bg-blue-500"
  defp bar_color_class(:green), do: "bg-green-500"
  defp bar_color_class(:yellow), do: "bg-yellow-500"
  defp bar_color_class(:red), do: "bg-red-500"
  defp bar_color_class(:purple), do: "bg-purple-500"
  defp bar_color_class(:indigo), do: "bg-indigo-500"
  defp bar_color_class(_), do: "bg-gray-400"

  defp normalize_badge_state(state) when is_atom(state),
    do: state |> Atom.to_string() |> normalize_badge_state()

  defp normalize_badge_state(state) when is_binary(state), do: state
  defp normalize_badge_state(state), do: to_string(state)

  defp badge_base_class,
    do: "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"

  defp badge_classes("success"),
    do: "#{badge_base_class()} bg-green-100 text-green-800"

  defp badge_classes("completed"),
    do: "#{badge_base_class()} bg-green-100 text-green-800"

  defp badge_classes("active"),
    do: "#{badge_base_class()} bg-blue-100 text-blue-800"

  defp badge_classes("executing"),
    do: "#{badge_base_class()} bg-blue-100 text-blue-800"

  defp badge_classes("available"),
    do: "#{badge_base_class()} bg-green-100 text-green-800"

  defp badge_classes("scheduled"),
    do: "#{badge_base_class()} bg-indigo-100 text-indigo-800"

  defp badge_classes("retryable"),
    do: "#{badge_base_class()} bg-yellow-100 text-yellow-800"

  defp badge_classes("suspended"),
    do: "#{badge_base_class()} bg-gray-100 text-gray-800"

  defp badge_classes("failure"),
    do: "#{badge_base_class()} bg-red-100 text-red-800"

  defp badge_classes("cancelled"),
    do: "#{badge_base_class()} bg-orange-100 text-orange-800"

  defp badge_classes("discarded"),
    do: "#{badge_base_class()} bg-red-100 text-red-800"

  defp badge_classes("inactive"),
    do: "#{badge_base_class()} bg-gray-100 text-gray-800"

  defp badge_classes(_),
    do: "#{badge_base_class()} bg-gray-100 text-gray-600"

  defp badge_icon("success"), do: "✓"
  defp badge_icon("completed"), do: "✓"
  defp badge_icon("active"), do: "●"
  defp badge_icon("executing"), do: "●"
  defp badge_icon("available"), do: "✓"
  defp badge_icon("scheduled"), do: "◷"
  defp badge_icon("retryable"), do: "↻"
  defp badge_icon("suspended"), do: "Ⅱ"
  defp badge_icon("failure"), do: "✗"
  defp badge_icon("cancelled"), do: "⊘"
  defp badge_icon("discarded"), do: "⊗"
  defp badge_icon("inactive"), do: "⊗"
  defp badge_icon(_), do: "?"

  defp badge_label("success"), do: "Success"
  defp badge_label("completed"), do: "Completed"
  defp badge_label("active"), do: "Active"
  defp badge_label("executing"), do: "Running"
  defp badge_label("available"), do: "Available"
  defp badge_label("scheduled"), do: "Scheduled"
  defp badge_label("retryable"), do: "Retryable"
  defp badge_label("suspended"), do: "Suspended"
  defp badge_label("failure"), do: "Failed"
  defp badge_label("cancelled"), do: "Cancelled"
  defp badge_label("discarded"), do: "Discarded"
  defp badge_label("inactive"), do: "Inactive"
  defp badge_label(state), do: String.capitalize(state)
end
