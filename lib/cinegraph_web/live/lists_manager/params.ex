defmodule CinegraphWeb.ListsManager.Params do
  @moduledoc """
  Normalizes list manager form params into movie list attributes.
  """

  alias Cinegraph.Slugs.SlugUtils

  def list_attrs_from_params(params, source_type, slug, display_order_default) do
    %{
      source_url: params["source_url"],
      name: params["name"],
      category: params["category"],
      description: params["description"],
      source_type: source_type,
      tracks_awards: params["tracks_awards"] == "on",
      slug: slug,
      short_name: params["short_name"],
      icon: params["icon"],
      cover_image_url: params["cover_image_url"],
      hero_image_url: params["hero_image_url"],
      display_order: parse_int(params["display_order"], display_order_default)
    }
  end

  def normalize_slug(params, fallback \\ nil)

  def normalize_slug(%{"slug" => nil}, fallback), do: fallback

  def normalize_slug(%{"slug" => ""} = params, _fallback), do: SlugUtils.slugify(params["name"])

  def normalize_slug(%{"slug" => slug}, _fallback), do: slug

  def normalize_slug(params, fallback), do: params["slug"] || fallback

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
