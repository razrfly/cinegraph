defmodule CinegraphWeb.Admin.Components.AdminComponents do
  @moduledoc """
  Shared page-chrome components for cinegraph's admin dashboards.

  Provides the outer page scaffolding every admin LiveView needs: page headers,
  section cards, filter bars, pagination, empty states, and the canonical
  `admin_table` primitive.

  Ported from eventasaurus's `EventasaurusWeb.Admin.Components.AdminComponents`.
  Catalyst-styled (zinc palette, ring-1 surfaces) — see issue #880.

  ## Usage

      use CinegraphWeb, :admin_html
      # or, for an admin LiveView:
      use CinegraphWeb, :admin_live_view

      <.page_header title="Festivals">
        <:actions>
          <button phx-click="sync_all" class="text-sm text-gray-500">Sync all</button>
        </:actions>
      </.page_header>

      <.section_card title="Coverage">
        ...
      </.section_card>

      <.pagination page={@list.page} total_pages={@list.total_pages} on_change="page" />
  """
  use Phoenix.Component

  # ============================================================================
  # Page Header
  # ============================================================================

  @doc """
  Renders an admin page header with title, optional subtitle, and an actions slot.

  ## Examples

      <.page_header title="Festivals" subtitle="15 organizations · 480 ceremonies" />

      <.page_header title="Festivals">
        <:actions>
          Last imported: 2026-04-19
        </:actions>
      </.page_header>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex items-start justify-between mb-6">
      <div class="min-w-0">
        <h1 class="text-2xl font-bold text-gray-900">{@title}</h1>
        <p :if={@subtitle} class="text-sm text-gray-500 mt-1">{@subtitle}</p>
      </div>
      <div
        :if={@actions != []}
        class="shrink-0 ml-4 flex items-center gap-2 text-sm text-gray-500"
      >
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # ============================================================================
  # Section Card
  # ============================================================================

  @doc """
  Renders a white card wrapper with an optional section title.

  Use to group related widgets (a histogram, a table, a filter form). The card
  uses the blessed admin surface styling: `bg-white shadow rounded-lg p-6`.

  ## Examples

      <.section_card title="Score distribution">
        <div>...histogram bars...</div>
      </.section_card>

      <.section_card>
        <div>...untitled widget...</div>
      </.section_card>
  """
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def section_card(assigns) do
    ~H"""
    <div class="bg-white shadow rounded-lg p-6 mb-6">
      <h2 :if={@title} class="text-lg font-semibold text-gray-900 mb-4">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Filter Bar
  # ============================================================================

  @doc """
  Renders a filter-row wrapper with the blessed gray-50 background.

  ## Examples

      <.filter_bar>
        <form phx-change="filter" class="contents">
          <input name="search" ... />
          <select name="status" ...><option>...</option></select>
        </form>
      </.filter_bar>
  """
  slot :inner_block, required: true

  def filter_bar(assigns) do
    ~H"""
    <div class="bg-gray-50 border border-gray-200 rounded-lg p-4 mb-6 flex gap-3 flex-wrap items-end">
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Empty State
  # ============================================================================

  @doc """
  Renders a centered empty-state block with title and description.

  ## Examples

      <.empty_state title="No festivals match those filters." />

      <.empty_state
        title="Festival not found"
        description="No festival with slug=cannes exists."
      />
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <div class="text-center py-12 px-4">
      <div class="text-sm font-medium text-gray-900">{@title}</div>
      <div :if={@description} class="text-sm text-gray-500 mt-1">{@description}</div>
    </div>
    """
  end

  # ============================================================================
  # Pagination
  # ============================================================================

  @doc """
  Renders prev/next pagination controls with a "page X of Y" label.

  Emits a `phx-click` event (named by `on_change`) with `page` param set to the
  target page number. Parent LiveView is responsible for handling the event.

  ## Examples

      <.pagination page={@list.page} total_pages={@list.total_pages} on_change="page" />

      <.pagination
        page={@list.page}
        total_pages={@list.total_pages}
        total_count={@list.total_count}
        on_change="page"
      />
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_count, :integer, default: nil
  attr :on_change, :string, default: "page"

  def pagination(assigns) do
    total_pages = max(assigns.total_pages, 1)
    current_page = assigns.page |> max(1) |> min(total_pages)
    prev_page = max(current_page - 1, 1)
    next_page = min(current_page + 1, total_pages)
    prev_disabled = current_page <= 1
    next_disabled = current_page >= total_pages

    assigns =
      assigns
      |> assign(:page, current_page)
      |> assign(:display_total_pages, total_pages)
      |> assign(:prev_page, prev_page)
      |> assign(:next_page, next_page)
      |> assign(:prev_disabled, prev_disabled)
      |> assign(:next_disabled, next_disabled)

    ~H"""
    <div class="flex items-center justify-between px-4 py-3 text-sm text-gray-600">
      <div>
        <span :if={@total_count}>
          {@total_count} match{if @total_count == 1, do: "", else: "es"} ·
        </span>
        Page {@page} of {@display_total_pages}
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          phx-click={@on_change}
          phx-value-page={@prev_page}
          disabled={@prev_disabled}
          class="px-3 py-1 border border-gray-300 rounded text-sm disabled:opacity-40 hover:bg-gray-50"
        >
          ← Prev
        </button>
        <button
          type="button"
          phx-click={@on_change}
          phx-value-page={@next_page}
          disabled={@next_disabled}
          class="px-3 py-1 border border-gray-300 rounded text-sm disabled:opacity-40 hover:bg-gray-50"
        >
          Next →
        </button>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Admin Table
  # ============================================================================

  @doc """
  Renders the blessed admin table: gray-50 header, zebra rows, hover highlight.

  Pass a list of `rows` and a list of `columns`. Each column is a map with
  `:key` (used as `column.key` in the `:cell` slot), `:label`, and optional
  `:align` (`:left` | `:right` | `:center`, defaults to `:left`).

  Renders `empty_state/1` when `rows` is empty.

  ## Examples

      <.admin_table rows={@jobs} columns={[
        %{key: :worker, label: "Worker"},
        %{key: :count, label: "Count", align: :right}
      ]}>
        <:cell :let={ctx}>
          <%= case ctx.column.key do %>
            <% :worker -> %><%= ctx.row.worker %>
            <% :count -> %><%= ctx.row.count %>
          <% end %>
        </:cell>
      </.admin_table>
  """
  attr :rows, :list, required: true
  attr :columns, :list, required: true
  attr :empty_title, :string, default: "No results"
  attr :empty_description, :string, default: nil
  attr :row_click, :any, default: nil
  slot :cell, required: true

  def admin_table(assigns) do
    ~H"""
    <div>
      <%= if Enum.empty?(@rows) do %>
        <.empty_state title={@empty_title} description={@empty_description} />
      <% else %>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th
                  :for={col <- @columns}
                  scope="col"
                  class={[
                    "px-6 py-3 text-xs font-medium text-gray-500 uppercase tracking-wider",
                    align_class(Map.get(col, :align, :left))
                  ]}
                >
                  {col.label}
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr
                :for={row <- @rows}
                class={[
                  "odd:bg-white even:bg-gray-50/50 hover:bg-gray-50 transition-colors",
                  @row_click && "cursor-pointer"
                ]}
              >
                <td
                  :for={col <- @columns}
                  class={[
                    "px-6 py-4 whitespace-nowrap text-sm text-gray-900",
                    align_class(Map.get(col, :align, :left))
                  ]}
                >
                  <button
                    :if={@row_click && col == List.first(@columns)}
                    type="button"
                    phx-click={@row_click.(row)}
                    aria-label="Open row"
                    class={[
                      "block w-full text-sm text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2",
                      align_class(Map.get(col, :align, :left))
                    ]}
                  >
                    {render_slot(@cell, %{row: row, column: col})}
                  </button>
                  <%= if !@row_click || col != List.first(@columns) do %>
                    {render_slot(@cell, %{row: row, column: col})}
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp align_class(:right), do: "text-right"
  defp align_class(:center), do: "text-center"
  defp align_class(_), do: "text-left"

  # ============================================================================
  # KPI Card
  # ============================================================================

  @doc """
  Renders a KPI card with a left-border accent, large value, and optional icon + subtitle.

  ## Examples

      <.kpi_card title="Total films" value="1,234" accent={:blue} icon={:chart} />
      <.kpi_card title="Coverage" value="98.2%" accent={:green} subtitle="OMDb gap fill" />
  """
  attr :title, :string, required: true
  attr :value, :any, required: true

  attr :accent, :atom,
    default: :blue,
    values: [:blue, :green, :yellow, :red, :purple, :amber, :zinc]

  attr :icon, :atom, default: nil
  attr :subtitle, :string, default: nil
  attr :rest, :global

  def kpi_card(assigns) do
    assigns =
      assigns
      |> assign(:border_class, accent_border_class(assigns.accent))
      |> assign(:value_class, accent_text_class(assigns.accent))
      |> assign(:icon_bg_class, accent_bg_class(assigns.accent))
      |> assign(:icon_fg_class, accent_icon_class(assigns.accent))

    ~H"""
    <div class={"bg-white shadow rounded-lg p-5 border-l-4 #{@border_class}"} {@rest}>
      <div class="flex items-center justify-between">
        <div class="min-w-0">
          <div class="text-sm font-medium text-gray-500">{@title}</div>
          <div class={"text-3xl font-bold mt-1 #{@value_class}"}>{format_kpi_value(@value)}</div>
        </div>
        <div
          :if={@icon}
          class={"flex items-center justify-center w-12 h-12 rounded-full shrink-0 ml-3 #{@icon_bg_class}"}
        >
          <.kpi_icon type={@icon} class={@icon_fg_class} />
        </div>
      </div>
      <div :if={@subtitle} class="text-sm mt-2 text-gray-500">{@subtitle}</div>
    </div>
    """
  end

  # ============================================================================
  # Section Heading
  # ============================================================================

  @doc """
  Renders a lightweight section heading. Use instead of `section_card` when the
  heading introduces inline content (no wrapping card).

  ## Examples

      <.section_heading title="Recent runs" />
      <.section_heading title="Targets" description="Schedule CRUD for this source" />
      <.section_heading title="Errors" link={{"/admin/health", "View all"}} />
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :link, :any, default: nil
  attr :rest, :global

  def section_heading(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between mb-3 mt-6" {@rest}>
      <div class="min-w-0">
        <h3 class="text-lg font-semibold text-gray-900">{@title}</h3>
        <p :if={@description} class="text-sm text-gray-500 mt-0.5">{@description}</p>
      </div>
      <%= if @link do %>
        <% {href, label} = @link %>
        <a
          href={href}
          class="text-sm text-blue-600 hover:text-blue-800 underline shrink-0 ml-4"
        >
          {label}
        </a>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Tabs
  # ============================================================================

  @doc """
  Renders a horizontal tab bar with underline active state, optional badges,
  and mobile horizontal scroll.

  Designed for URL-driven tabs: parent LiveView handles the `on_change` event
  (default `"change_tab"`) and issues a `push_patch` with the selected tab id.

  ## Examples

      <.tabs
        tabs={[
          %{id: :overview, label: "Overview"},
          %{id: :imports, label: "Imports", badge: 3},
          %{id: :health, label: "Health", badge: {:dot, :red}},
          %{id: :archive, label: "Archive", disabled: true}
        ]}
        active={@active_tab}
        on_change="change_tab"
      />
  """
  attr :tabs, :list, required: true
  attr :active, :any, required: true
  attr :on_change, :string, default: "change_tab"

  def tabs(assigns) do
    active_id = to_string(assigns.active)
    assigns = assign(assigns, :active_id, active_id)

    ~H"""
    <div class="border-b border-gray-200">
      <nav class="-mb-px flex gap-6 overflow-x-auto" role="tablist">
        <%= for tab <- @tabs do %>
          <% tab_id = to_string(tab.id) %>
          <% active? = tab_id == @active_id %>
          <% disabled? = Map.get(tab, :disabled, false) %>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(active?)}
            phx-click={unless disabled?, do: @on_change}
            phx-value-tab={tab_id}
            disabled={disabled?}
            class={[
              "whitespace-nowrap py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2 transition-colors",
              active? && "border-blue-500 text-blue-600",
              !active? && !disabled? &&
                "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300",
              disabled? && "border-transparent text-gray-300 cursor-not-allowed"
            ]}
          >
            <span>{tab.label}</span>
            <.tab_badge
              badge={Map.get(tab, :badge)}
              accent={Map.get(tab, :badge_accent, :red)}
            />
          </button>
        <% end %>
      </nav>
    </div>
    """
  end

  attr :badge, :any, required: true
  attr :accent, :atom, default: :red

  defp tab_badge(%{badge: nil} = assigns), do: ~H""

  defp tab_badge(%{badge: {:dot, color}} = assigns) do
    dot_class =
      case color do
        :red -> "bg-red-500"
        :amber -> "bg-amber-500"
        _ -> "bg-gray-400"
      end

    assigns = assign(assigns, :dot_class, dot_class)

    ~H"""
    <span class={"inline-block w-2 h-2 rounded-full #{@dot_class}"} aria-hidden="true"></span>
    """
  end

  defp tab_badge(%{badge: count} = assigns) when is_integer(count) and count > 0 do
    assigns =
      assigns
      |> assign(:count, count)
      |> assign(:accent_class, badge_accent_class(assigns.accent))

    ~H"""
    <span class={"inline-flex items-center justify-center px-2 py-0.5 rounded-full text-xs font-medium min-w-[1.25rem] #{@accent_class}"}>
      {@count}
    </span>
    """
  end

  defp tab_badge(assigns), do: ~H""

  defp badge_accent_class(:amber), do: "bg-amber-100 text-amber-800"
  defp badge_accent_class(:neutral), do: "bg-gray-100 text-gray-700"
  defp badge_accent_class(_), do: "bg-red-100 text-red-800"

  # ============================================================================
  # Private — accent helpers for kpi_card
  # ============================================================================

  defp accent_border_class(:blue), do: "border-blue-500"
  defp accent_border_class(:green), do: "border-green-500"
  defp accent_border_class(:yellow), do: "border-yellow-500"
  defp accent_border_class(:purple), do: "border-purple-500"
  defp accent_border_class(:amber), do: "border-amber-500"
  defp accent_border_class(:red), do: "border-red-500"
  defp accent_border_class(:zinc), do: "border-gray-400"
  defp accent_border_class(_), do: "border-gray-400"

  defp accent_text_class(:blue), do: "text-blue-900"
  defp accent_text_class(:green), do: "text-green-900"
  defp accent_text_class(:yellow), do: "text-yellow-900"
  defp accent_text_class(:purple), do: "text-purple-900"
  defp accent_text_class(:amber), do: "text-amber-900"
  defp accent_text_class(:red), do: "text-red-900"
  defp accent_text_class(:zinc), do: "text-gray-900"
  defp accent_text_class(_), do: "text-gray-900"

  defp accent_bg_class(:blue), do: "bg-blue-100"
  defp accent_bg_class(:green), do: "bg-green-100"
  defp accent_bg_class(:yellow), do: "bg-yellow-100"
  defp accent_bg_class(:purple), do: "bg-purple-100"
  defp accent_bg_class(:amber), do: "bg-amber-100"
  defp accent_bg_class(:red), do: "bg-red-100"
  defp accent_bg_class(:zinc), do: "bg-gray-100"
  defp accent_bg_class(_), do: "bg-gray-100"

  defp accent_icon_class(:blue), do: "w-6 h-6 text-blue-600"
  defp accent_icon_class(:green), do: "w-6 h-6 text-green-600"
  defp accent_icon_class(:yellow), do: "w-6 h-6 text-yellow-600"
  defp accent_icon_class(:purple), do: "w-6 h-6 text-purple-600"
  defp accent_icon_class(:amber), do: "w-6 h-6 text-amber-600"
  defp accent_icon_class(:red), do: "w-6 h-6 text-red-600"
  defp accent_icon_class(:zinc), do: "w-6 h-6 text-gray-600"
  defp accent_icon_class(_), do: "w-6 h-6 text-gray-600"

  defp format_kpi_value(nil), do: "0"
  defp format_kpi_value(num) when is_integer(num), do: Integer.to_string(num)
  defp format_kpi_value(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp format_kpi_value(val), do: to_string(val)

  attr :type, :atom, required: true
  attr :class, :string, default: "w-6 h-6"

  defp kpi_icon(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <%= case @type do %>
        <% :chart -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
          />
        <% :plug -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 10V3L4 14h7v7l9-11h-7z"
          />
        <% :location -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"
          />
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"
          />
        <% :tag -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"
          />
        <% :calendar -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
          />
        <% :users -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"
          />
        <% _ -> %>
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          />
      <% end %>
    </svg>
    """
  end
end
