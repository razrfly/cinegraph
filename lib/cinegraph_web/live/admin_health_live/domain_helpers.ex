defmodule CinegraphWeb.AdminHealthLive.DomainHelpers do
  @moduledoc """
  Pure data-shaping helpers for admin health domain cards and drawers.
  """

  import CinegraphWeb.Admin.Components.DashboardComponents, only: [format_int: 1]

  @doc false
  def domain_card_props(verdict, domain) do
    case verdict do
      %{domains: domains} ->
        case Map.get(domains, domain) do
          %{status: status, checks: checks} ->
            %{
              status: status,
              signals: top_signals(checks, 3),
              headline: headline_for(domain, checks),
              unknown_count: Enum.count(checks, fn c -> c.blocked_reason != nil end)
            }

          _ ->
            unknown_domain_props()
        end

      _ ->
        unknown_domain_props()
    end
  end

  @doc false
  def drawer_title(:people), do: "People drift"
  def drawer_title(:movies), do: "Movies drift"
  def drawer_title(:festivals), do: "Festivals drift"
  def drawer_title(:ratings), do: "Ratings drift"
  def drawer_title(:availability), do: "Availability drift"
  def drawer_title(:collaborations), do: "Collaborations drift"
  def drawer_title(_), do: "Drift"

  defp unknown_domain_props do
    %{status: :unknown, signals: [], headline: "no data", unknown_count: 0}
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
  # crashed/uncached checks fall through to an explicit unavailable string.
  defp headline_for(:people, checks) do
    case Enum.find(checks, &(&1.check == :missing_profile_path)) do
      %{blocked_reason: nil, affected_pct: pct} when is_number(pct) ->
        "#{Float.round(100.0 - pct, 1)}% of people have a profile photo"

      _ ->
        "profile-photo coverage unavailable - see drawer"
    end
  end

  defp headline_for(:movies, checks) do
    case Enum.find(checks, &(&1.check == :year_gap)) do
      %{blocked_reason: nil, total_population: total, affected_count: missing}
      when is_integer(total) and is_integer(missing) and total > 0 ->
        "#{format_int(total - missing)} / #{format_int(total)} vs TMDb"

      _ ->
        "TMDb gap data unavailable - see drawer"
    end
  end

  defp headline_for(:festivals, checks) do
    case Enum.find(checks, &(&1.check == :nominations_below_floor)) do
      %{blocked_reason: nil, total_population: total, affected_count: affected}
      when is_integer(total) and is_integer(affected) ->
        healthy = max(total - affected, 0)
        "#{healthy} / #{total} ceremonies fully synced"

      _ ->
        "ceremony floor data unavailable - see drawer"
    end
  end

  defp headline_for(:ratings, checks) do
    case Enum.find(checks, &(&1.check == :omdb_null_backlog)) do
      %{blocked_reason: nil, affected_pct: pct} when is_number(pct) ->
        "#{Float.round(100.0 - pct, 1)}% OMDb coverage"

      _ ->
        "OMDb coverage unavailable - see drawer"
    end
  end

  defp headline_for(:availability, checks) do
    case Enum.find(checks, &(&1.check == :availability_missing)) do
      %{blocked_reason: nil, affected_pct: pct} when is_number(pct) ->
        "#{Float.round(100.0 - pct, 1)}% availability coverage"

      _ ->
        "availability coverage unavailable - see drawer"
    end
  end

  defp headline_for(:collaborations, checks) do
    case Enum.find(checks, &(&1.check == :missing_details)) do
      %{blocked_reason: nil, affected_pct: pct} when is_number(pct) ->
        "#{Float.round(100.0 - pct, 1)}% collaboration coverage"

      _ ->
        "collaboration coverage unavailable - see drawer"
    end
  end

  defp headline_for(_, _), do: ""
end
