defmodule CinegraphWeb.AdminHealthLive.Show do
  @moduledoc """
  `/admin/health` — homeostasis dashboard (#723).

  Reads exclusively from `Cinegraph.Health.*` so CLI (`mix cinegraph.health`)
  and UI never disagree.
  """
  use CinegraphWeb, :admin_live_view

  import CinegraphWeb.AdminHealthLive.Components

  alias Cinegraph.Health.{Activity, Completeness, Facade, FestivalFloorAudit, Queues}

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

  defp do_queue_refresh(:availability, ids, socket) do
    flash_queue_result(
      socket,
      CinegraphWeb.AdminHealth.Actions.queue_availability_refresh(ids),
      "availability"
    )
  end

  defp do_queue_refresh(_, _, socket) do
    {:noreply, put_flash(socket, :error, "Unknown domain for refresh action")}
  end

  defp flash_queue_result(socket, {:ok, n}, label) do
    {:noreply, put_flash(socket, :info, "Queued #{n} #{label} refresh job(s)")}
  end

  defp flash_queue_result(socket, {:partial, %{ok: n, errors: errors}}, label) do
    Logger.warning(
      "AdminHealthLive #{label} refresh enqueue partially failed: #{inspect(errors)}"
    )

    {:noreply,
     put_flash(
       socket,
       :warning,
       "Queued #{n} #{label} refresh job(s); #{length(errors)} batch(es) failed"
     )}
  end

  defp flash_queue_result(socket, {:error, reason}, label) do
    Logger.error("AdminHealthLive #{label} refresh enqueue failed: #{inspect(reason)}")

    {:noreply,
     put_flash(
       socket,
       :error,
       "Failed to queue #{label} refresh — an internal error occurred; see logs for details"
     )}
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
    festival_floor = safe(fn -> FestivalFloorAudit.audit() end)

    socket
    |> assign(:verdict, verdict)
    |> assign(:activity_today, activity_today)
    |> assign(:activity_recent, activity_recent)
    |> assign(:queues, queues)
    |> assign(:history, history)
    |> assign(:festival_floor, festival_floor)
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
  defp parse_domain("availability"), do: :availability
  defp parse_domain("collaborations"), do: :collaborations
  defp parse_domain(_), do: nil

  defp drift_module(:people), do: Cinegraph.Health.Drift.People
  defp drift_module(:movies), do: Cinegraph.Health.Drift.Movies
  defp drift_module(:festivals), do: Cinegraph.Health.Drift.Festivals
  defp drift_module(:ratings), do: Cinegraph.Health.Drift.Ratings
  defp drift_module(:availability), do: Cinegraph.Health.Drift.Availability
  defp drift_module(:collaborations), do: Cinegraph.Health.Drift.Collaborations

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
            unknown_count = Enum.count(checks, fn c -> c.blocked_reason != nil end)

            %{
              status: status,
              signals: top,
              headline: headline_for(domain, checks),
              unknown_count: unknown_count
            }

          _ ->
            %{status: :unknown, signals: [], headline: "no data", unknown_count: 0}
        end

      _ ->
        %{status: :unknown, signals: [], headline: "no data", unknown_count: 0}
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

  # Each clause requires `blocked_reason: nil` on the source check, so
  # crashed/uncached checks fall through to an explicit "unavailable" string
  # instead of degrading to a green-looking literal. Pairs with the
  # `unknown_count` warning line on the card.
  defp headline_for(:people, checks) do
    case Enum.find(checks, &(&1.check == :missing_profile_path)) do
      %{blocked_reason: nil, affected_pct: pct} ->
        "#{Float.round(100.0 - pct, 1)}% of people have a profile photo"

      _ ->
        "profile-photo coverage unavailable — see drawer"
    end
  end

  defp headline_for(:movies, checks) do
    case Enum.find(checks, &(&1.check == :year_gap)) do
      %{blocked_reason: nil, total_population: total, affected_count: missing} when total > 0 ->
        "#{format_int(total - missing)} / #{format_int(total)} vs TMDb"

      _ ->
        "TMDb gap data unavailable — see drawer"
    end
  end

  defp headline_for(:festivals, checks) do
    case Enum.find(checks, &(&1.check == :nominations_below_floor)) do
      %{blocked_reason: nil, total_population: total, affected_count: affected} ->
        healthy = max(total - affected, 0)
        "#{healthy} / #{total} ceremonies fully synced"

      _ ->
        "ceremony floor data unavailable — see drawer"
    end
  end

  defp headline_for(:ratings, checks) do
    case Enum.find(checks, &(&1.check == :omdb_null_backlog)) do
      %{blocked_reason: nil, affected_pct: pct} ->
        "#{Float.round(100.0 - pct, 1)}% OMDb coverage"

      _ ->
        "OMDb coverage unavailable — see drawer"
    end
  end

  defp headline_for(:availability, checks) do
    case Enum.find(checks, &(&1.check == :availability_missing)) do
      %{blocked_reason: nil, affected_pct: pct} ->
        "#{Float.round(100.0 - pct, 1)}% availability coverage"

      _ ->
        "availability coverage unavailable — see drawer"
    end
  end

  defp headline_for(:collaborations, checks) do
    case Enum.find(checks, &(&1.check == :missing_details)) do
      %{blocked_reason: nil, affected_pct: pct} ->
        "#{Float.round(100.0 - pct, 1)}% collaboration coverage"

      _ ->
        "collaboration coverage unavailable — see drawer"
    end
  end

  defp headline_for(_, _), do: ""

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
  def festival_floor_data({:error, _}), do: []
  def festival_floor_data(orgs) when is_list(orgs), do: orgs
  def festival_floor_data(_), do: []

  @doc false
  def festival_floor_total(orgs) when is_list(orgs),
    do: Enum.reduce(orgs, 0, &(&1.below_floor_count + &2))

  def festival_floor_total(_), do: 0

  @doc """
  Severity color for a delta_pct value. Mirrors the dashboard threshold
  bands: green ≥ -25%, amber -25% to -50%, red < -50%.
  """
  def festival_delta_class(nil), do: "text-zinc-500"

  def festival_delta_class(d) when is_number(d) do
    cond do
      d >= -25.0 -> "text-emerald-700"
      d >= -50.0 -> "text-amber-700"
      true -> "text-red-700 font-semibold"
    end
  end

  def festival_delta_class(_), do: "text-zinc-500"

  @doc false
  def format_org_label(%{abbreviation: abbr, name: name})
      when abbr not in [nil, ""] and abbr != name,
      do: "#{abbr} · #{name}"

  def format_org_label(%{name: name}) when is_binary(name), do: name
  def format_org_label(_), do: "Unknown"

  def format_delta_value(nil), do: "?"

  def format_delta_value(d) when is_float(d),
    do: "#{:erlang.float_to_binary(d, decimals: 1)}%"

  def format_delta_value(d), do: "#{d}%"

  def format_median(nil), do: "?"

  def format_median(m) when is_float(m),
    do: :erlang.float_to_binary(m, decimals: 1)

  def format_median(m), do: to_string(m)

  @doc false
  def drawer_title(:people), do: "People drift"
  def drawer_title(:movies), do: "Movies drift"
  def drawer_title(:festivals), do: "Festivals drift"
  def drawer_title(:ratings), do: "Ratings drift"
  def drawer_title(:availability), do: "Availability drift"
  def drawer_title(:collaborations), do: "Collaborations drift"
  def drawer_title(_), do: "Drift"
end
