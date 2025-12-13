defmodule CinegraphWeb.LiveViewHelpers do
  @moduledoc """
  Shared helper functions for LiveView modules.

  This module contains common utility functions used across multiple LiveViews
  including sort handling, pagination, and parameter parsing.

  ## Usage

  Import this module in your LiveView:

      use CinegraphWeb, :live_view
      import CinegraphWeb.LiveViewHelpers

  Or import specific functions:

      import CinegraphWeb.LiveViewHelpers, only: [
        extract_sort_criteria: 1,
        extract_sort_direction: 1,
        pagination_range: 2
      ]
  """

  import Phoenix.Component, only: [assign: 3]

  # ============================================================================
  # Sort Helpers
  # ============================================================================

  @doc """
  Extracts the sort criteria from a sort parameter string.

  Removes the `_asc` or `_desc` suffix to get the base sort field.

  ## Examples

      iex> extract_sort_criteria("release_date_desc")
      "release_date"

      iex> extract_sort_criteria("title_asc")
      "title"

      iex> extract_sort_criteria("rating")
      "rating"
  """
  @spec extract_sort_criteria(String.t()) :: String.t()
  def extract_sort_criteria(sort_string) do
    sort_string
    |> String.replace(~r/_(asc|desc)$/, "")
  end

  @doc """
  Extracts the sort direction from a sort parameter string.

  Returns `:asc` or `:desc` based on the suffix. Defaults to `:desc` if no suffix.

  ## Examples

      iex> extract_sort_direction("release_date_desc")
      :desc

      iex> extract_sort_direction("title_asc")
      :asc

      iex> extract_sort_direction("rating")
      :desc
  """
  @spec extract_sort_direction(String.t()) :: :asc | :desc
  def extract_sort_direction(sort_string) do
    if String.ends_with?(sort_string, "_asc"), do: :asc, else: :desc
  end

  @doc """
  Builds a sort parameter string from criteria and direction.

  ## Examples

      iex> build_sort_param("release_date", :desc)
      "release_date_desc"

      iex> build_sort_param("title", :asc)
      "title_asc"
  """
  @spec build_sort_param(String.t(), :asc | :desc) :: String.t()
  def build_sort_param(criteria, direction) do
    "#{criteria}_#{direction}"
  end

  # ============================================================================
  # Pagination Helpers
  # ============================================================================

  @doc """
  Assigns pagination data from Flop meta to socket.

  Extracts total count, pages, current page, and page size from the meta struct
  and assigns them to standard socket keys.

  ## Example

      socket
      |> assign_pagination(meta)
  """
  @spec assign_pagination(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_pagination(socket, meta) do
    socket
    |> assign(:total_movies, meta.total_count || 0)
    |> assign(:total_pages, meta.total_pages || 1)
    |> assign(:current_page, meta.current_page || 1)
    |> assign(:page, meta.current_page || 1)
    |> assign(:per_page, meta.page_size || 50)
  end

  @doc """
  Generates a pagination range with ellipsis for large page counts.

  Returns a list of page numbers and "..." strings for rendering pagination controls.
  Keeps the display compact while showing relevant pages around the current page.

  ## Options

    * `:max_links` - Maximum number of page links to show (default: 7)

  ## Examples

      iex> pagination_range(1, 5)
      [1, 2, 3, 4, 5]

      iex> pagination_range(1, 10)
      [1, 2, 3, 4, "...", 10]

      iex> pagination_range(5, 10)
      [1, "...", 4, 5, 6, "...", 10]

      iex> pagination_range(9, 10)
      [1, "...", 7, 8, 9, 10]
  """
  @spec pagination_range(pos_integer(), pos_integer(), keyword()) :: list()
  def pagination_range(current_page, total_pages, opts \\ [])

  def pagination_range(_current_page, total_pages, _opts) when total_pages <= 7 do
    1..max(total_pages, 1) |> Enum.to_list()
  end

  def pagination_range(current_page, total_pages, _opts) do
    cond do
      current_page <= 3 ->
        [1, 2, 3, 4, "...", total_pages]

      current_page >= total_pages - 2 ->
        [1, "...", total_pages - 3, total_pages - 2, total_pages - 1, total_pages]

      true ->
        [1, "...", current_page - 1, current_page, current_page + 1, "...", total_pages]
    end
  end

  @doc """
  Builds pagination params by merging page number with existing params.

  Converts page to string and removes slug if present.

  ## Example

      iex> build_pagination_params(%{params: %{"sort" => "title_asc"}}, 3)
      %{"sort" => "title_asc", "page" => "3"}
  """
  @spec build_pagination_params(map(), pos_integer()) :: map()
  def build_pagination_params(assigns, page) do
    assigns.params
    |> Map.put("page", to_string(page))
    |> Map.delete("slug")
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  # ============================================================================
  # Parameter Parsing Helpers
  # ============================================================================

  @doc """
  Parses an array parameter from URL params.

  Handles nil, empty list, list, and comma-separated string inputs.

  ## Examples

      iex> parse_array_param(nil)
      []

      iex> parse_array_param([])
      []

      iex> parse_array_param(["1", "2"])
      ["1", "2"]

      iex> parse_array_param("1,2,3")
      ["1", "2", "3"]
  """
  @spec parse_array_param(nil | list() | String.t()) :: list()
  def parse_array_param(nil), do: []
  def parse_array_param([]), do: []
  def parse_array_param(value) when is_list(value), do: value
  def parse_array_param(value) when is_binary(value), do: String.split(value, ",", trim: true)

  @doc """
  Safely converts a value to integer, returning nil on invalid input.

  Only accepts values that are entirely numeric (no trailing characters).

  ## Examples

      iex> safe_to_integer(42)
      42

      iex> safe_to_integer("42")
      42

      iex> safe_to_integer("  42  ")
      42

      iex> safe_to_integer("42abc")
      nil

      iex> safe_to_integer("abc")
      nil

      iex> safe_to_integer(nil)
      nil
  """
  @spec safe_to_integer(integer() | String.t() | nil) :: integer() | nil
  def safe_to_integer(value) when is_integer(value), do: value

  def safe_to_integer(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def safe_to_integer(_), do: nil

  # ============================================================================
  # URL/Params Building Helpers
  # ============================================================================

  @doc """
  Cleans filter params by removing empty values and normalizing arrays.

  Converts single empty strings to empty arrays and filters out nil/empty values.

  ## Example

      iex> clean_filter_params(%{"genres" => [""], "decade" => "1990", "search" => ""})
      %{"decade" => "1990"}
  """
  @spec clean_filter_params(map()) :: map()
  def clean_filter_params(filters) do
    filters
    |> Enum.map(fn
      {key, [""]} -> {key, []}
      {key, value} when is_list(value) -> {key, Enum.reject(value, &(&1 == "" || &1 == nil))}
      other -> other
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  @doc """
  Merges new params with existing params and cleans the result.

  Sets page to "1" by default when applying new filters.

  ## Example

      socket.assigns.params
      |> merge_and_clean_params(%{"genres" => ["28"], "page" => "1"})
  """
  @spec merge_and_clean_params(map(), map()) :: map()
  def merge_and_clean_params(existing_params, new_params) do
    existing_params
    |> Map.merge(new_params)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end
end
