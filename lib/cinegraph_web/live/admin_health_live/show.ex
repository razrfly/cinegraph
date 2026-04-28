defmodule CinegraphWeb.AdminHealthLive.Show do
  @moduledoc """
  `/admin/health` — homeostasis dashboard (#723).

  Reads exclusively from `Cinegraph.Health.*` so CLI (`mix cinegraph.health`)
  and UI never disagree.
  """
  use CinegraphWeb, :live_view

  import CinegraphWeb.AdminHealthLive.Components

  alias Cinegraph.Health.{Activity, Completeness, Facade, Queues}

  require Logger

  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Health")
      |> assign(:drawer_domain, nil)
      |> assign(:drawer_checks, [])
      |> load(force: false)
      |> maybe_schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, socket |> load(force: false) |> maybe_schedule_refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load(socket, force: true)}
  end

  def handle_event("open_drawer", %{"domain" => domain_str}, socket) do
    domain = parse_domain(domain_str)

    case domain do
      nil ->
        {:noreply, socket}

      d ->
        # Pull colored checks from the already-computed verdict so the drawer
        # matches the domain card's status pills exactly. Falls back to the
        # uncolored Drift module only if the verdict isn't loaded yet.
        checks = colored_checks_for(d, socket.assigns[:verdict])

        {:noreply,
         socket
         |> assign(:drawer_domain, d)
         |> assign(:drawer_checks, checks)}
    end
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, socket |> assign(:drawer_domain, nil) |> assign(:drawer_checks, [])}
  end

  def handle_event("queue_refresh", %{"domain" => domain_str, "ids" => ids_param}, socket) do
    ids = parse_ids(ids_param)
    domain = parse_domain(domain_str)
    do_queue_refresh(domain, ids, socket)
  end

  defp colored_checks_for(domain, %{domains: domains}) when is_map(domains) do
    case Map.get(domains, domain) do
      %{checks: checks} when is_list(checks) and checks != [] -> checks
      _ -> fallback_checks_for(domain)
    end
  end

  defp colored_checks_for(domain, _verdict), do: fallback_checks_for(domain)

  defp fallback_checks_for(domain) do
    safe(fn -> drift_module(domain).all() end) |> normalize_checks()
  end

  defp do_queue_refresh(:people, ids, socket) do
    flash_queue_result(
      socket,
      CinegraphWeb.AdminHealth.Actions.queue_person_tmdb_refresh(ids),
      "TMDb"
    )
  end

  defp do_queue_refresh(:ratings, ids, socket) do
    flash_queue_result(
      socket,
      CinegraphWeb.AdminHealth.Actions.queue_omdb_refresh(ids),
      "OMDb"
    )
  end

  defp do_queue_refresh(_, _, socket) do
    {:noreply, put_flash(socket, :error, "Unknown domain for refresh action")}
  end

  defp flash_queue_result(socket, {:ok, n}, label) do
    {:noreply, put_flash(socket, :info, "Queued #{n} #{label} refresh job(s)")}
  end

  defp flash_queue_result(socket, {:error, reason}, label) do
    Logger.error("AdminHealthLive #{label} refresh enqueue failed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Failed to queue #{label} refresh: #{inspect(reason)}")}
  end

  defp parse_ids(ids) when is_integer(ids), do: [ids]

  defp parse_ids(ids) when is_binary(ids) do
    ids
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn s ->
      case Integer.parse(s) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

  defp parse_ids(_), do: []

  # ===== private =====

  defp load(socket, opts) do
    force? = Keyword.get(opts, :force, false)

    verdict = safe(fn -> Facade.compute_full_verdict(bypass_cache: force?) end)
    activity_today = safe(fn -> Activity.today(bypass_cache: force?) end)
    activity_recent = safe(fn -> Activity.recent(7, bypass_cache: force?) end)
    queues = safe(fn -> Queues.snapshot(bypass_cache: force?) end)
    history = safe(fn -> Completeness.history(30, bypass_cache: force?) end)

    socket
    |> assign(:verdict, verdict)
    |> assign(:activity_today, activity_today)
    |> assign(:activity_recent, activity_recent)
    |> assign(:queues, queues)
    |> assign(:history, history)
    |> assign(:loaded_at, DateTime.utc_now())
    |> assign(
      :loading_error,
      collect_errors([verdict, activity_today, activity_recent, queues, history])
    )
  end

  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp parse_domain("people"), do: :people
  defp parse_domain("movies"), do: :movies
  defp parse_domain("festivals"), do: :festivals
  defp parse_domain("ratings"), do: :ratings
  defp parse_domain(_), do: nil

  defp drift_module(:people), do: Cinegraph.Health.Drift.People
  defp drift_module(:movies), do: Cinegraph.Health.Drift.Movies
  defp drift_module(:festivals), do: Cinegraph.Health.Drift.Festivals
  defp drift_module(:ratings), do: Cinegraph.Health.Drift.Ratings

  defp normalize_checks({:error, _}), do: []
  defp normalize_checks(checks) when is_list(checks), do: checks
  defp normalize_checks(_), do: []

  @doc false
  def domain_card_props(verdict, domain) do
    case verdict do
      %{domains: domains} ->
        case Map.get(domains, domain) do
          %{status: status, checks: checks} ->
            top = top_signals(checks, 3)
            %{status: status, signals: top, headline: headline_for(domain, checks)}

          _ ->
            %{status: :unknown, signals: [], headline: "no data"}
        end

      _ ->
        %{status: :unknown, signals: [], headline: "no data"}
    end
  end

  # Top-N signals: sort by status (red first, amber, green, unknown), then by
  # affected_pct descending, take N.
  defp top_signals(checks, n) do
    rank = %{red: 3, amber: 2, green: 1, unknown: 0}

    checks
    |> Enum.sort_by(fn c -> {-Map.get(rank, c.status, 0), -(c.affected_pct || 0)} end)
    |> Enum.take(n)
    |> Enum.map(fn c ->
      %{
        label: humanize_check(c.check),
        affected_count: c.affected_count,
        affected_pct: c.affected_pct
      }
    end)
  end

  defp humanize_check(check_atom) do
    check_atom |> Atom.to_string() |> String.replace("_", " ")
  end

  defp headline_for(:people, checks) do
    case Enum.find(checks, &(&1.check == :missing_profile_path)) do
      %{affected_pct: pct} -> "#{Float.round(100.0 - pct, 1)}% of people have a profile photo"
      _ -> "TMDb coverage"
    end
  end

  defp headline_for(:movies, checks) do
    case Enum.find(checks, &(&1.check == :year_gap)) do
      %{total_population: total, affected_count: missing} when total > 0 ->
        "#{format_int(total - missing)} / #{format_int(total)} vs TMDb"

      _ ->
        "TMDb gap"
    end
  end

  defp headline_for(:festivals, checks) do
    below = Enum.find(checks, &(&1.check == :nominations_below_floor))
    total = if below, do: below.total_population, else: 0
    affected = if below, do: below.affected_count, else: 0
    healthy = max(total - affected, 0)
    "#{healthy} / #{total} ceremonies fully synced"
  end

  defp headline_for(:ratings, checks) do
    case Enum.find(checks, &(&1.check == :omdb_null_backlog)) do
      %{affected_pct: pct} -> "#{Float.round(100.0 - pct, 1)}% OMDb coverage"
      _ -> "Ratings coverage"
    end
  end

  defp headline_for(_, _), do: ""

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

  defp collect_errors(values) do
    values
    |> Enum.filter(fn
      {:error, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:error, msg} -> msg end)
  end

  defp maybe_schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_interval)
    socket
  end

  # Helpers used by the template — kept as 0-arity defs on the module for clarity.

  @doc false
  def sparkline_for(:movies_added, recent), do: extract(recent, :movies_added)
  def sparkline_for(:omdb_fetches, recent), do: extract(recent, :omdb_fetches)
  def sparkline_for(:ceremonies_updated, recent), do: extract(recent, :ceremonies_updated)
  def sparkline_for(:people_added, recent), do: extract(recent, :people_added)

  defp extract({:error, _}, _key), do: []

  defp extract(rows, key) when is_list(rows),
    do: rows |> Enum.reverse() |> Enum.map(&Map.get(&1, key, 0))

  defp extract(_, _), do: []

  @doc false
  def drawer_title(:people), do: "People drift"
  def drawer_title(:movies), do: "Movies drift"
  def drawer_title(:festivals), do: "Festivals drift"
  def drawer_title(:ratings), do: "Ratings drift"
  def drawer_title(_), do: "Drift"
end
