defmodule CinegraphWeb.Admin.JobsLive do
  @moduledoc """
  Per-worker job execution metrics at `/admin/jobs`.

  Time-range selector (1h/6h/24h/48h/7d) drives counts pulled from
  `Cinegraph.Health.ObanReader.{count_completed_in/3, count_failed_in/3}`.
  Per-worker breakdown lists the registered JobRegistry workers with
  completed / failed counts in the selected window.

  Phase 1 of #880.
  """
  use CinegraphWeb, :admin_live_view

  alias Cinegraph.Admin.JobRegistry
  alias Cinegraph.Health.ObanReader

  @ranges [
    {"1h", 60 * 60},
    {"6h", 6 * 60 * 60},
    {"24h", 24 * 60 * 60},
    {"48h", 48 * 60 * 60},
    {"7d", 7 * 24 * 60 * 60}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Jobs")
     |> assign(:ranges, @ranges)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = parse_range(params["range"])
    {label, seconds} = range
    since = DateTime.add(DateTime.utc_now(), -seconds)

    completed = safe_count_completed(since)
    failed = safe_count_failed(since)

    workers =
      JobRegistry.all()
      |> Enum.uniq_by(& &1.worker)
      |> Enum.map(fn entry ->
        worker_str = inspect(entry.worker)
        summary = safe_summary(worker_str, since)
        avg_dur = safe_avg_duration(worker_str, since)

        %{
          entry: entry,
          worker_str: worker_str,
          totals: aggregate_summary(summary),
          avg_duration_seconds: avg_dur
        }
      end)
      |> Enum.sort_by(&(-(&1.totals.completed + &1.totals.discarded)))

    {:noreply,
     socket
     |> assign(:range_label, label)
     |> assign(:since, since)
     |> assign(:completed, completed)
     |> assign(:failed, failed)
     |> assign(:workers, workers)}
  end

  defp parse_range(nil), do: parse_range("24h")

  defp parse_range(label) do
    case Enum.find(@ranges, fn {l, _} -> l == label end) do
      nil -> {"24h", 24 * 60 * 60}
      r -> r
    end
  end

  defp safe_count_completed(since) do
    ObanReader.count_completed_in(since, nil)
  rescue
    _ -> :error
  end

  defp safe_count_failed(since) do
    ObanReader.count_failed_in(since, nil)
  rescue
    _ -> :error
  end

  defp safe_summary(worker_str, since) do
    ObanReader.jobs_summary_for_worker(worker_str, since)
  rescue
    _ -> %{}
  end

  defp safe_avg_duration(worker_str, since) do
    ObanReader.avg_duration_for_worker(worker_str, since)
  rescue
    _ -> nil
  end

  defp aggregate_summary(summary) when is_map(summary) do
    summary
    |> Map.values()
    |> Enum.reduce(%{completed: 0, discarded: 0, retryable: 0}, fn s, acc ->
      %{
        completed: acc.completed + (s[:completed] || 0),
        discarded: acc.discarded + (s[:discarded] || 0),
        retryable: acc.retryable + (s[:retryable] || 0)
      }
    end)
  end

  defp aggregate_summary(_), do: %{completed: 0, discarded: 0, retryable: 0}

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header
      title="Jobs"
      subtitle="Per-worker execution metrics. Range applies to all rows below."
    >
      <:actions>
        <%= for {label, _} <- @ranges do %>
          <.link
            patch={~p"/admin/jobs?range=#{label}"}
            class={range_pill_class(label == @range_label)}
          >
            {label}
          </.link>
        <% end %>
      </:actions>
    </.page_header>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-6">
      <.kpi_card
        title={"Completed (#{@range_label})"}
        value={kpi_value(@completed)}
        accent={:green}
        subtitle={"Since #{format_dt(@since)} UTC"}
      />
      <.kpi_card
        title={"Failed (#{@range_label})"}
        value={kpi_value(@failed)}
        accent={fail_accent(@failed)}
        subtitle="Discarded + cancelled"
      />
      <.kpi_card
        title="Success rate"
        value={success_rate(@completed, @failed)}
        accent={success_accent(@completed, @failed)}
      />
    </div>

    <.section_card title="Per-worker breakdown">
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Worker</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Queue</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Completed
              </th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Failed</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Retryable
              </th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Avg duration
              </th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase"></th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <%= for row <- @workers do %>
              <tr class="hover:bg-gray-50">
                <td class="px-4 py-2 text-sm">
                  <div class="font-medium text-gray-900">{row.entry.label}</div>
                  <div class="text-xs text-gray-500 font-mono">{row.worker_str}</div>
                </td>
                <td class="px-4 py-2 text-xs font-mono text-gray-700">{row.entry.queue}</td>
                <td class="px-4 py-2 text-sm text-right text-gray-900">
                  {format_int(row.totals.completed)}
                </td>
                <td class={"px-4 py-2 text-sm text-right #{count_color(row.totals.discarded)}"}>
                  {format_int(row.totals.discarded)}
                </td>
                <td class={"px-4 py-2 text-sm text-right #{count_color(row.totals.retryable)}"}>
                  {format_int(row.totals.retryable)}
                </td>
                <td class="px-4 py-2 text-sm text-right text-gray-700 font-mono">
                  {format_duration(row.avg_duration_seconds)}
                </td>
                <td class="px-4 py-2 text-sm text-right">
                  <.link
                    navigate={~p"/admin/scheduled/#{row.entry.id}"}
                    class="text-xs text-blue-700 hover:text-blue-900"
                  >
                    View runs →
                  </.link>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.section_card>
    """
  end

  defp range_pill_class(true) do
    "inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-blue-600 text-white no-underline"
  end

  defp range_pill_class(false) do
    "inline-flex items-center px-3 py-1 rounded-full text-xs font-medium bg-white text-gray-700 border border-gray-300 hover:bg-gray-50 no-underline"
  end

  defp kpi_value(:error), do: "—"
  defp kpi_value(n) when is_integer(n), do: format_int(n)
  defp kpi_value(_), do: "—"

  defp success_rate(:error, _), do: "—"
  defp success_rate(_, :error), do: "—"
  defp success_rate(0, 0), do: "—"

  defp success_rate(completed, failed) when is_integer(completed) and is_integer(failed) do
    total = completed + failed

    if total > 0 do
      pct = completed / total * 100
      "#{:erlang.float_to_binary(pct, decimals: 1)}%"
    else
      "—"
    end
  end

  defp success_rate(_, _), do: "—"

  defp success_accent(:error, _), do: :zinc
  defp success_accent(_, :error), do: :zinc

  defp success_accent(c, f) when is_integer(c) and is_integer(f) do
    total = c + f

    if total > 0 do
      pct = c / total * 100

      cond do
        pct >= 99.0 -> :green
        pct >= 95.0 -> :yellow
        true -> :red
      end
    else
      :zinc
    end
  end

  defp success_accent(_, _), do: :zinc

  defp fail_accent(:error), do: :zinc
  defp fail_accent(0), do: :green
  defp fail_accent(n) when is_integer(n) and n < 10, do: :yellow
  defp fail_accent(_), do: :red

  defp count_color(n) when is_integer(n) and n > 0, do: "text-red-700 font-medium"
  defp count_color(_), do: "text-gray-700"

  defp format_int(nil), do: "0"

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join(&1, ""))
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_int(_), do: "—"

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(_), do: "—"

  defp format_duration(nil), do: "—"

  defp format_duration(seconds) when is_number(seconds) do
    cond do
      seconds < 1.0 -> "#{:erlang.float_to_binary(seconds * 1000, decimals: 0)}ms"
      seconds < 60.0 -> "#{:erlang.float_to_binary(seconds * 1.0, decimals: 1)}s"
      seconds < 3600.0 -> "#{round(seconds / 60)}m #{round(:math.fmod(seconds, 60))}s"
      true -> "#{round(seconds / 3600)}h #{round(:math.fmod(seconds, 3600) / 60)}m"
    end
  end

  defp format_duration(_), do: "—"
end
