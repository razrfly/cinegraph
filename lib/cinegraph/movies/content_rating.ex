defmodule Cinegraph.Movies.ContentRating do
  @moduledoc """
  Normalizes content certifications into minimum age values.

  The mappings are intentionally conservative and small. Unknown, unrated, or
  advisory-only labels return nil so filters do not treat missing data as safe.
  """

  @mpaa_ages %{
    "G" => 0,
    "PG" => 7,
    "PG-13" => 13,
    "R" => 17,
    "NC-17" => 18
  }

  @bbfc_ages %{
    "U" => 0,
    "PG" => 7,
    "12A" => 12,
    "12" => 12,
    "15" => 15,
    "18" => 18
  }

  @fsk_ages %{
    "0" => 0,
    "6" => 6,
    "12" => 12,
    "16" => 16,
    "18" => 18
  }

  @doc """
  Returns the minimum recommended age for a certification/country pair.
  """
  def to_min_age(certification, country_code \\ "US")

  def to_min_age(certification, country_code) when is_binary(certification) do
    certification = normalize_certification(certification)

    country_code
    |> normalize_country_code()
    |> age_map()
    |> Map.get(certification)
  end

  def to_min_age(_, _), do: nil

  @doc """
  Returns normalized certifications for a country whose minimum age is at most
  the provided age.
  """
  def certifications_for_max_age(country_code, max_age) when is_integer(max_age) do
    country_code
    |> normalize_country_code()
    |> age_map()
    |> Enum.filter(fn {_certification, min_age} -> min_age <= max_age end)
    |> Enum.map(fn {certification, _min_age} -> certification end)
    |> Enum.sort()
  end

  def certifications_for_max_age(_, _), do: []

  @doc """
  Normalizes raw certification strings into the format stored in mapping keys.
  """
  def normalize_certification(certification) when is_binary(certification) do
    certification
    |> String.trim()
    |> String.upcase()
    |> String.replace_prefix("RATED ", "")
    |> String.replace(~r/\s+/, "-")
  end

  def normalize_certification(_), do: nil

  defp normalize_country_code(country_code) when is_binary(country_code) do
    country_code
    |> String.trim()
    |> String.upcase()
  end

  defp normalize_country_code(_), do: "US"

  defp age_map("GB"), do: @bbfc_ages
  defp age_map("UK"), do: @bbfc_ages
  defp age_map("DE"), do: @fsk_ages
  defp age_map("US"), do: @mpaa_ages
  defp age_map(_), do: @mpaa_ages
end
