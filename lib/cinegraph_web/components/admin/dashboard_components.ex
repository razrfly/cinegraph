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
end
