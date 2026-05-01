defmodule CinegraphWeb.MovieLive.IndexV2.Canonicalize do
  @moduledoc """
  Canonical URL parameter handling for the V2 movie index.
  """

  import Ecto.Query

  alias Cinegraph.Movies.Genre
  alias Cinegraph.Movies.Person
  alias Cinegraph.Repo
  alias CinegraphWeb.LiveViewHelpers

  def filter_params(socket, params) do
    params
    |> canonicalize_genre_param(socket)
    |> canonicalize_festival_param(socket)
    |> canonicalize_list_param(socket)
    |> canonicalize_people_param(socket)
    |> strip_empty_filter_params()
  end

  def people_slug_cache_from_params(params) do
    params
    |> people_param_values()
    |> LiveViewHelpers.parse_array_param()
    |> people_slug_cache_for_values()
  end

  defp canonicalize_genre_param(params, socket) do
    genres = Map.get(params, "genres") || Map.get(params, "genres[]")

    params =
      case canonical_genre_slugs(socket, genres) do
        [] -> Map.delete(params, "genres")
        slugs -> Map.put(params, "genres", Enum.join(slugs, ","))
      end

    Map.delete(params, "genres[]")
  end

  defp canonicalize_festival_param(params, socket) do
    festivals = Map.get(params, "festivals") || Map.get(params, "festivals[]")

    params =
      case canonical_festival_slugs(socket, festivals) do
        [] -> Map.delete(params, "festivals")
        slugs -> Map.put(params, "festivals", Enum.join(slugs, ","))
      end

    Map.delete(params, "festivals[]")
  end

  defp canonicalize_list_param(params, socket) do
    lists = Map.get(params, "lists") || Map.get(params, "lists[]")

    params =
      case canonical_list_slugs(socket, lists) do
        [] -> Map.delete(params, "lists")
        slugs -> Map.put(params, "lists", Enum.join(slugs, ","))
      end

    Map.delete(params, "lists[]")
  end

  defp canonicalize_people_param(params, socket) do
    values = people_param_values(params)

    params =
      case canonical_people_slugs(values, socket.assigns[:people_slug_cache] || %{}) do
        [] -> Map.delete(params, "people")
        slugs -> Map.put(params, "people", Enum.join(slugs, ","))
      end

    params
    |> Map.delete("people_ids")
    |> Map.delete("people_search")
    |> Map.delete("people_search[people_ids]")
    |> Map.delete("people_search[role_filter]")
  end

  defp people_param_values(params) do
    cond do
      Map.has_key?(params, "people") ->
        params["people"]

      Map.has_key?(params, "people_ids") ->
        params["people_ids"]

      match?(%{}, params["people_search"]) ->
        get_in(params, ["people_search", "people_ids"])

      Map.has_key?(params, "people_search[people_ids]") ->
        params["people_search[people_ids]"]

      true ->
        nil
    end
  end

  defp canonical_genre_slugs(_socket, nil), do: []
  defp canonical_genre_slugs(_socket, []), do: []

  defp canonical_genre_slugs(socket, values) do
    values = LiveViewHelpers.parse_array_param(values)

    genres =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:genres, [])

    values
    |> Enum.map(&genre_slug_for_value(&1, genres))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp genre_slug_for_value(value, genres) when is_integer(value) do
    genres
    |> Enum.find(&(&1.id == value))
    |> Genre.slug()
  end

  defp genre_slug_for_value(value, genres) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} ->
        genre_slug_for_value(id, genres)

      _ ->
        slug = Genre.slug(value)

        if Enum.any?(genres, &(Genre.slug(&1) == slug)) do
          slug
        end
    end
  end

  defp genre_slug_for_value(_value, _genres), do: nil

  defp canonical_festival_slugs(_socket, nil), do: []
  defp canonical_festival_slugs(_socket, []), do: []

  defp canonical_festival_slugs(socket, values) do
    values = LiveViewHelpers.parse_array_param(values)

    festivals =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:festivals, [])

    values
    |> Enum.map(&festival_slug_for_value(&1, festivals))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp festival_slug_for_value(value, festivals) when is_integer(value) do
    festivals
    |> Enum.find(&(&1.id == value))
    |> map_slug()
  end

  defp festival_slug_for_value(value, festivals) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} ->
        festival_slug_for_value(id, festivals)

      _ ->
        festivals
        |> Enum.find(&(map_slug(&1) == value))
        |> map_slug()
    end
  end

  defp festival_slug_for_value(_value, _festivals), do: nil

  defp canonical_list_slugs(_socket, nil), do: []
  defp canonical_list_slugs(_socket, []), do: []

  defp canonical_list_slugs(socket, values) do
    values = LiveViewHelpers.parse_array_param(values)

    lists =
      socket.assigns
      |> Map.get(:filter_options, %{})
      |> Map.get(:lists, [])

    values
    |> Enum.map(&list_slug_for_value(&1, lists))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_slug_for_value(value, lists) do
    value = to_string(value)

    case Enum.find(lists, &(&1.key == value or Map.get(&1, :slug) == value)) do
      nil -> nil
      list -> Map.get(list, :slug) || list.key
    end
  end

  defp canonical_people_slugs(nil, _cache), do: []
  defp canonical_people_slugs([], _cache), do: []

  defp canonical_people_slugs(values, cache) do
    values
    |> LiveViewHelpers.parse_array_param()
    |> people_slugs_for_values(cache)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp people_slug_cache_for_values(values) do
    ids =
      values
      |> Enum.flat_map(fn
        v when is_integer(v) ->
          [v]

        v when is_binary(v) ->
          case Integer.parse(v) do
            {id, ""} -> [id]
            _ -> []
          end

        _ ->
          []
      end)
      |> Enum.uniq()

    ids
    |> query_slugs_for_ids()
    |> Map.new(fn %{id: id, slug: slug} -> {id, slug} end)
  end

  defp people_slugs_for_values(values, cache) do
    {ids, slugs} =
      Enum.reduce(values, {[], []}, fn
        v, {ids, slugs} when is_integer(v) ->
          {[v | ids], slugs}

        v, {ids, slugs} when is_binary(v) ->
          case Integer.parse(v) do
            {id, ""} -> {[id | ids], slugs}
            _ -> {ids, [v | slugs]}
          end

        _v, acc ->
          acc
      end)

    id_slugs = slugs_from_cache_or_query(ids, cache)

    (slugs ++ id_slugs)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp slugs_from_cache_or_query([], _cache), do: []

  defp slugs_from_cache_or_query(ids, cache) do
    ids = Enum.uniq(ids)
    {cached, missing_ids} = Enum.split_with(ids, &Map.has_key?(cache, &1))

    queried =
      missing_ids
      |> query_slugs_for_ids()
      |> Enum.map(& &1.slug)

    Enum.map(cached, &Map.get(cache, &1)) ++ queried
  end

  defp query_slugs_for_ids([]), do: []

  defp query_slugs_for_ids(ids) do
    Person
    |> where([p], p.id in ^ids)
    |> select([p], %{id: p.id, slug: p.slug})
    |> Repo.replica().all()
  end

  defp strip_empty_filter_params(params) do
    params
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  defp map_slug(nil), do: nil
  defp map_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp map_slug(_), do: nil
end
