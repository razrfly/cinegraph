defmodule Cinegraph.Movies.Query.Params do
  @moduledoc """
  Parameter validation and normalization for movie searches.
  Provides a clean interface between LiveView and the query system.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Basic search
    field :search, :string

    # Flop will handle these basic filters
    field :page, :integer, default: 1
    field :per_page, :integer, default: 50
    field :sort, :string, default: "release_date_desc"

    # Complex filters that need custom handling
    field :genres, {:array, :integer}, default: []
    field :countries, {:array, :integer}, default: []
    field :languages, {:array, :string}, default: []
    field :lists, {:array, :string}, default: []

    # Date filters
    field :year, :integer
    field :year_from, :integer
    field :year_to, :integer
    field :decade, :integer
    field :show_unreleased, :boolean, default: false

    # Range filters
    field :runtime_min, :integer
    field :runtime_max, :integer
    field :rating_min, :float

    # Award filters
    field :award_status, :string
    # kept for backwards compatibility
    field :festival_id, :integer
    # new multi-select field
    field :festivals, {:array, :integer}, default: []
    field :award_category_id, :integer
    field :award_year_from, :integer
    field :award_year_to, :integer

    # Rating filters (simplified presets)
    field :rating_preset, :string

    # Discovery metric filters (simplified presets)
    field :discovery_preset, :string
    field :award_preset, :string

    # People filters
    field :people_ids, {:array, :integer}, default: []
    field :people_role, :string

    # Metric thresholds (for advanced users)
    field :popular_opinion_min, :float
    field :critical_acclaim_min, :float
    field :industry_recognition_min, :float
    field :cultural_impact_min, :float
    field :people_quality_min, :float
  end

  @valid_sorts ~w(
    title title_asc title_desc
    release_date release_date_asc release_date_desc
    runtime runtime_asc runtime_desc
    rating rating_asc rating_desc
    popularity popularity_asc popularity_desc
    popular_opinion popular_opinion_asc popular_opinion_desc
    critical_acclaim critical_acclaim_asc critical_acclaim_desc
    industry_recognition industry_recognition_asc industry_recognition_desc
    cultural_impact cultural_impact_asc cultural_impact_desc
    people_quality people_quality_asc people_quality_desc
  )

  @valid_rating_presets ~w(highly_rated well_reviewed critically_acclaimed)
  @valid_discovery_presets ~w(award_winners popular_favorites hidden_gems critically_acclaimed)
  @valid_award_presets ~w(recent_awards 2010s 2000s classic)
  @valid_award_statuses ~w(any_nomination won nominated_only multiple_awards)
  @valid_people_roles ~w(any director cast writer producer cinematographer composer editor)

  def changeset(params) do
    %__MODULE__{}
    |> cast(normalize_params(params), [
      :search,
      :page,
      :per_page,
      :sort,
      :genres,
      :countries,
      :languages,
      :lists,
      :festivals,
      :year,
      :year_from,
      :year_to,
      :decade,
      :show_unreleased,
      :runtime_min,
      :runtime_max,
      :rating_min,
      :award_status,
      :festival_id,
      :award_category_id,
      :award_year_from,
      :award_year_to,
      :rating_preset,
      :discovery_preset,
      :award_preset,
      :people_ids,
      :people_role,
      :popular_opinion_min,
      :critical_acclaim_min,
      :industry_recognition_min,
      :cultural_impact_min,
      :people_quality_min
    ])
    |> validate_inclusion(:sort, @valid_sorts)
    |> validate_inclusion(:rating_preset, @valid_rating_presets, allow_nil: true)
    |> validate_inclusion(:discovery_preset, @valid_discovery_presets, allow_nil: true)
    |> validate_inclusion(:award_preset, @valid_award_presets, allow_nil: true)
    |> validate_inclusion(:award_status, @valid_award_statuses, allow_nil: true)
    |> validate_inclusion(:people_role, @valid_people_roles, allow_nil: true)
    |> validate_number(:page, greater_than: 0)
    |> validate_number(:per_page, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:runtime_min, greater_than_or_equal_to: 0)
    |> validate_number(:runtime_max, greater_than_or_equal_to: 0)
    |> validate_number(:rating_min, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_year_range()
  end

  def validate(params) do
    params
    |> changeset()
    |> apply_action(:validate)
  end

  def to_flop_params(%__MODULE__{} = params) do
    {order_by, order_directions} = parse_sort_for_flop(params.sort)

    base_params = %{
      page: params.page,
      page_size: params.per_page,
      filters: build_flop_filters(params)
    }

    # Only add order_by if it's not nil (i.e., it's a sort that Flop can handle)
    if order_by do
      Map.merge(base_params, %{
        order_by: order_by,
        order_directions: order_directions
      })
    else
      base_params
    end
  end

  defp normalize_params(params) when is_map(params) do
    params
    |> normalize_array_params()
    |> normalize_people_search()
    |> normalize_blank_enums()
    |> normalize_numeric_params()
  end

  defp normalize_array_params(params) do
    # Handle both array notation and comma-separated strings
    Enum.reduce(
      [:genres, :countries, :languages, :lists, :festivals, :people_ids],
      params,
      fn key, acc ->
        key_str = to_string(key)
        array_key = "#{key_str}[]"

        value =
          cond do
            Map.has_key?(acc, array_key) ->
              Map.get(acc, array_key)

            Map.has_key?(acc, key_str) ->
              parse_list_param(Map.get(acc, key_str))

            true ->
              nil
          end

        if value do
          # Keep everything as strings for now, convert later if needed
          Map.put(acc, key_str, value)
        else
          acc
        end
      end
    )
  end

  defp normalize_people_search(params) do
    # If both people_ids and people_search exist, prioritize people_ids and clean up people_search
    params =
      if Map.has_key?(params, "people_ids") do
        params
        |> Map.delete("people_search")
        |> Map.delete("people_search[people_ids]")
        |> Map.delete("people_search[role_filter]")
      else
        params
      end

    case params do
      %{"people_search" => %{"people_ids" => ids, "role_filter" => role}} ->
        role =
          case role do
            nil -> nil
            "" -> nil
            "any" -> nil
            other -> other
          end

        params
        |> Map.put("people_ids", parse_list_param(ids))
        |> Map.put("people_role", role)
        |> Map.delete("people_search")

      %{"people_search[people_ids]" => ids} ->
        role =
          case params["people_search[role_filter]"] do
            nil -> nil
            "" -> nil
            "any" -> nil
            other -> other
          end

        params
        |> Map.put("people_ids", parse_list_param(ids))
        |> Map.put("people_role", role)
        |> Map.delete("people_search[people_ids]")
        |> Map.delete("people_search[role_filter]")

      _ ->
        params
    end
  end

  defp normalize_blank_enums(params) do
    enum_fields = ~w(rating_preset discovery_preset award_preset award_status people_role search)

    Enum.reduce(enum_fields, params, fn f, acc ->
      case Map.get(acc, f) do
        nil ->
          acc

        v when is_binary(v) ->
          trimmed = String.trim(v)
          if trimmed == "" do
            Map.delete(acc, f)
          else
            Map.put(acc, f, trimmed)
          end

        _ ->
          acc
      end
    end)
  end

  defp normalize_numeric_params(params) do
    numeric_fields = ~w(page per_page year year_from year_to decade 
                        runtime_min runtime_max festival_id award_category_id
                        award_year_from award_year_to genres countries festivals)

    float_fields = ~w(rating_min popular_opinion_min critical_acclaim_min
                      industry_recognition_min cultural_impact_min people_quality_min)

    params
    |> parse_integers(numeric_fields)
    |> parse_floats(float_fields)
  end

  defp parse_integers(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          Map.delete(acc, field)

        values when is_list(values) and field in ["genres", "countries", "festivals"] ->
          # Convert array of strings to integers for ID-based filters
          parsed =
            Enum.map(values, fn v ->
              case v do
                v when is_integer(v) ->
                  v

                v when is_binary(v) ->
                  case Integer.parse(v) do
                    {int, _} -> int
                    _ -> nil
                  end

                _ ->
                  nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          Map.put(acc, field, parsed)

        value when is_binary(value) ->
          case Integer.parse(value) do
            {int, _} -> Map.put(acc, field, int)
            _ -> Map.delete(acc, field)
          end

        value ->
          Map.put(acc, field, value)
      end
    end)
  end

  defp parse_floats(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          Map.delete(acc, field)

        value when is_binary(value) ->
          case Float.parse(value) do
            {float, _} -> Map.put(acc, field, float)
            _ -> Map.delete(acc, field)
          end

        value ->
          Map.put(acc, field, value)
      end
    end)
  end

  defp parse_list_param(nil), do: []
  defp parse_list_param(""), do: []
  defp parse_list_param(param) when is_list(param), do: param

  defp parse_list_param(param) when is_binary(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp validate_year_range(changeset) do
    year_from = get_field(changeset, :year_from)
    year_to = get_field(changeset, :year_to)

    if year_from && year_to && year_from > year_to do
      add_error(changeset, :year_from, "must be before or equal to year_to")
    else
      changeset
    end
  end

  defp parse_sort_for_flop(sort) do
    case sort do
      "title" -> {[:title], [:asc]}
      "title_asc" -> {[:title], [:asc]}
      "title_desc" -> {[:title], [:desc]}
      "release_date" -> {[:release_date], [:asc]}
      "release_date_asc" -> {[:release_date], [:asc]}
      "release_date_desc" -> {[:release_date], [:desc]}
      "runtime" -> {[:runtime], [:asc]}
      "runtime_asc" -> {[:runtime], [:asc]}
      "runtime_desc" -> {[:runtime], [:desc]}
      # Return nil for sorts that should be handled by CustomSorting
      _ -> {nil, nil}
    end
  end

  defp build_flop_filters(params) do
    filters = []

    # Add search filter
    filters =
      if params.search && params.search != "" do
        filters ++ [%{field: :title, op: :ilike, value: params.search}]
      else
        filters
      end

    # Add simple field filters that Flop can handle directly
    filters =
      if params.show_unreleased == false do
        filters ++ [%{field: :release_date, op: :<=, value: Date.utc_today()}]
      else
        filters
      end

    filters
  end
end
