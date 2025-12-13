defmodule CinegraphWeb.FilterHelpers do
  @moduledoc """
  Shared filter helper functions for LiveView modules.

  This module provides common functionality for handling filters across
  different LiveViews including ListLive.Show, AwardsLive.Show, and MovieLive.Index.

  ## Usage

  Import this module in your LiveView:

      import CinegraphWeb.FilterHelpers

  Or import specific functions:

      import CinegraphWeb.FilterHelpers, only: [
        has_active_filters?: 2,
        build_active_filters_list: 3
      ]
  """

  import CinegraphWeb.LiveViewHelpers, only: [safe_to_integer: 1]

  # ============================================================================
  # Filter State Checking
  # ============================================================================

  @doc """
  Checks if any filters in the given fields are active.

  Takes a filters map and a list of field specs to check. Each field spec
  can be either an atom (for simple value check) or a tuple {field, :array}
  for array fields.

  ## Examples

      iex> has_active_filters?(%{genres: [1, 2], decade: nil}, [:genres, :decade])
      true

      iex> has_active_filters?(%{genres: [], decade: nil}, [:genres, :decade])
      false

      iex> has_active_filters?(%{decade: "1990"}, [:decade])
      true
  """
  @spec has_active_filters?(map(), list()) :: boolean()
  def has_active_filters?(filters, fields) when is_map(filters) and is_list(fields) do
    Enum.any?(fields, fn field ->
      value = Map.get(filters, field)
      filter_value_present?(value)
    end)
  end

  @doc """
  Checks if a filter value is considered "present" (not empty).

  ## Examples

      iex> filter_value_present?(nil)
      false

      iex> filter_value_present?("")
      false

      iex> filter_value_present?([])
      false

      iex> filter_value_present?([1, 2])
      true

      iex> filter_value_present?("1990")
      true
  """
  @spec filter_value_present?(any()) :: boolean()
  def filter_value_present?(nil), do: false
  def filter_value_present?(""), do: false
  def filter_value_present?([]), do: false
  def filter_value_present?(list) when is_list(list), do: length(list) > 0
  def filter_value_present?(_), do: true

  # ============================================================================
  # Active Filter Display Building
  # ============================================================================

  @doc """
  Builds a list of active filter display objects for rendering filter pills/chips.

  Takes filters map, assigns (for looking up display names), and a list of
  filter configurations.

  ## Filter Configuration Format

  Each filter config is a map with:
    - `:field` - The filter field name (atom)
    - `:key` - The URL parameter key (string)
    - `:label` - Display label for the filter
    - `:type` - One of :array_lookup, :single_value, :people_count
    - `:lookup_key` - (optional) Key in assigns for lookup data
    - `:id_field` - (optional) Field to match on for lookups (default: :id)
    - `:name_field` - (optional) Field to get name from (default: :name)
    - `:suffix` - (optional) Suffix to add to display value (e.g., "s" for decades)

  ## Example

      filter_configs = [
        %{field: :genres, key: "genres", label: "Genres", type: :array_lookup,
          lookup_key: :available_genres},
        %{field: :decade, key: "decade", label: "Decade", type: :single_value,
          suffix: "s"}
      ]

      build_active_filters_list(filters, assigns, filter_configs)
  """
  @spec build_active_filters_list(map(), map(), list(map())) :: list(map())
  def build_active_filters_list(filters, assigns, filter_configs) do
    Enum.reduce(filter_configs, [], fn config, acc ->
      value = Map.get(filters, config.field)

      if filter_value_present?(value) do
        display_value = format_filter_display_value(value, config, assigns)
        acc ++ [%{key: config.key, label: config.label, display_value: display_value}]
      else
        acc
      end
    end)
  end

  @doc """
  Formats a filter value for display based on the filter configuration.

  Handles different filter types:
  - `:array_lookup` - Looks up IDs in a list from assigns and joins names
  - `:single_value` - Simple value with optional suffix
  - `:people_count` - Shows count of people selected

  ## Examples

      iex> format_filter_display_value([1, 2], %{type: :array_lookup, ...}, assigns)
      "Action, Comedy"

      iex> format_filter_display_value("1990", %{type: :single_value, suffix: "s"}, assigns)
      "1990s"
  """
  @spec format_filter_display_value(any(), map(), map()) :: String.t()
  def format_filter_display_value(value, config, assigns) do
    case config.type do
      :array_lookup ->
        format_array_lookup(value, config, assigns)

      :single_value ->
        format_single_value(value, config)

      :people_count ->
        format_people_count(value)

      _ ->
        to_string(value)
    end
  end

  # Formats an array of IDs by looking up their names in assigns
  defp format_array_lookup(values, config, assigns) do
    lookup_list = Map.get(assigns, config.lookup_key, [])
    id_field = Map.get(config, :id_field, :id)
    name_field = Map.get(config, :name_field, :name)
    max_length = Map.get(config, :max_display_length, 25)

    names =
      values
      |> Enum.map(fn id ->
        id_int = safe_to_integer(id)
        item = if id_int, do: Enum.find(lookup_list, &(Map.get(&1, id_field) == id_int))
        if item, do: Map.get(item, name_field), else: to_string(id)
      end)
      |> Enum.join(", ")

    truncate_display(names, max_length)
  end

  # Formats a single value with optional suffix
  defp format_single_value(value, config) do
    suffix = Map.get(config, :suffix, "")
    "#{value}#{suffix}"
  end

  # Formats people filter as count
  defp format_people_count(people_ids) when is_list(people_ids) do
    count = length(people_ids)
    if count == 1, do: "1 person", else: "#{count} people"
  end

  defp format_people_count(_), do: "Selected"

  # Truncates a string for display if it exceeds max length
  defp truncate_display(text, max_length) when byte_size(text) > max_length do
    String.slice(text, 0..(max_length - 4)) <> "..."
  end

  defp truncate_display(text, _max_length), do: text

  # ============================================================================
  # Common Filter Configurations
  # ============================================================================

  @doc """
  Returns standard filter configuration for genres.
  """
  @spec genre_filter_config() :: map()
  def genre_filter_config do
    %{
      field: :genres,
      key: "genres",
      label: "Genres",
      type: :array_lookup,
      lookup_key: :available_genres,
      id_field: :id,
      name_field: :name
    }
  end

  @doc """
  Returns standard filter configuration for decade.
  """
  @spec decade_filter_config() :: map()
  def decade_filter_config do
    %{
      field: :decade,
      key: "decade",
      label: "Decade",
      type: :single_value,
      suffix: "s"
    }
  end

  @doc """
  Returns standard filter configuration for people_ids.
  """
  @spec people_filter_config() :: map()
  def people_filter_config do
    %{
      field: :people_ids,
      key: "people_ids",
      label: "People",
      type: :people_count
    }
  end

  @doc """
  Returns standard filter configuration for festivals.
  """
  @spec festivals_filter_config() :: map()
  def festivals_filter_config do
    %{
      field: :festivals,
      key: "festivals",
      label: "Festivals/Awards",
      type: :array_lookup,
      lookup_key: :festival_organizations,
      id_field: :id,
      name_field: :name
    }
  end

  @doc """
  Returns standard filter configuration for lists (curated lists).
  """
  @spec lists_filter_config() :: map()
  def lists_filter_config do
    %{
      field: :lists,
      key: "lists",
      label: "Lists",
      type: :array_lookup,
      lookup_key: :available_lists,
      id_field: :key,
      name_field: :name
    }
  end

  # ============================================================================
  # Filter Configuration Sets for Different Views
  # ============================================================================

  @doc """
  Returns the standard filter configurations for ListLive.Show.

  Includes: genres, decade, people_ids, festivals
  """
  @spec list_view_filter_configs() :: list(map())
  def list_view_filter_configs do
    [
      genre_filter_config(),
      decade_filter_config(),
      people_filter_config(),
      festivals_filter_config()
    ]
  end

  @doc """
  Returns the standard filter configurations for AwardsLive.Show.

  Includes: genres, decade, people_ids, lists
  """
  @spec awards_view_filter_configs() :: list(map())
  def awards_view_filter_configs do
    [
      genre_filter_config(),
      decade_filter_config(),
      people_filter_config(),
      lists_filter_config()
    ]
  end

  @doc """
  Returns the filter fields to check for ListLive.Show.
  """
  @spec list_view_filter_fields() :: list(atom())
  def list_view_filter_fields do
    [:genres, :decade, :people_ids, :festivals]
  end

  @doc """
  Returns the filter fields to check for AwardsLive.Show.
  """
  @spec awards_view_filter_fields() :: list(atom())
  def awards_view_filter_fields do
    [:genres, :decade, :people_ids, :lists]
  end
end
