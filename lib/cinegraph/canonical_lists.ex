defmodule Cinegraph.CanonicalLists do
  @moduledoc """
  Single source of truth for all canonical list configurations.
  This module defines all available canonical lists in one place.
  """

  @lists %{
    "1001_movies" => %{
      list_id: "ls024863935",
      source_key: "1001_movies", 
      name: "1001 Movies You Must See Before You Die",
      metadata: %{"edition" => "2024"}
    },
    "criterion" => %{
      list_id: "ls087831830",
      source_key: "criterion",
      name: "The Criterion Collection",
      metadata: %{"source" => "criterion.com"}
    },
    "sight_sound_critics_2022" => %{
      list_id: "ls566134733",
      source_key: "sight_sound_critics_2022",
      name: "BFI's Sight & Sound | Critics' Top 100 Movies (2022 Edition)",
      metadata: %{
        "edition" => "2022",
        "poll_type" => "critics",
        "source" => "BFI Sight & Sound"
      }
    },
    "national_film_registry" => %{
      list_id: "ls595303232",
      source_key: "national_film_registry",
      name: "National Film Registry - The Full List of Films",
      metadata: %{
        "source" => "Library of Congress",
        "reliability" => "95%",
        "note" => "Updated annually after official announcements"
      }
    },
    "cannes_winners" => %{
      list_id: "ls527026601",
      source_key: "cannes_winners",
      name: "Cannes Film Festival Award Winners: 2023-1939",
      metadata: %{
        "festival" => "Cannes Film Festival",
        "source" => "IMDB User List",
        "reliability" => "85%",
        "note" => "Winners only - no nominees. Award details mixed in descriptions."
      }
    },
    "venice_golden_lion" => %{
      list_id: "ls020806626",
      source_key: "venice_golden_lion",
      name: "Venice Film Festival Golden Lion Winners",
      metadata: %{
        "festival" => "Venice Film Festival",
        "source" => "IMDB User List",
        "reliability" => "90%",
        "note" => "World's oldest film festival, prestigious European cinema"
      }
    },
    "berlin_golden_bear" => %{
      list_id: "ls073833905",
      source_key: "berlin_golden_bear",
      name: "Berlin International Film Festival Golden Bear Winners",
      metadata: %{
        "festival" => "Berlin International Film Festival",
        "source" => "IMDB User List",
        "reliability" => "90%",
        "note" => "One of 'Big Three' European festivals, established 1951"
      }
    }
  }

  @doc """
  Get all available canonical lists.
  """
  def all, do: @lists

  @doc """
  Get a specific list configuration by key.
  """
  def get(list_key) when is_binary(list_key) do
    case Map.get(@lists, list_key) do
      nil -> {:error, "Unknown list: #{list_key}"}
      config -> {:ok, config}
    end
  end

  @doc """
  Get just the list IDs for all lists.
  """
  def list_ids do
    @lists
    |> Enum.map(fn {_key, config} -> config.list_id end)
  end

  @doc """
  Build the IMDb URL for a list.
  """
  def list_url(list_key) when is_binary(list_key) do
    case get(list_key) do
      {:ok, config} -> {:ok, "https://www.imdb.com/list/#{config.list_id}/"}
      error -> error
    end
  end
end