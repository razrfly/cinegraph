defmodule CinegraphWeb.AdminHealthLive.FestivalFloorHelpers do
  @moduledoc """
  Formatting helpers for the admin health festival-floor panel.
  """

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
  bands: green >= -25%, amber -25% to -50%, red < -50%.
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

  @doc false
  def format_delta_value(nil), do: "?"

  def format_delta_value(d) when is_float(d),
    do: "#{:erlang.float_to_binary(d, decimals: 1)}%"

  def format_delta_value(d), do: "#{d}%"

  @doc false
  def format_median(nil), do: "?"

  def format_median(m) when is_float(m),
    do: :erlang.float_to_binary(m, decimals: 1)

  def format_median(m), do: to_string(m)
end
