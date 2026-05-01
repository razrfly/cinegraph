defmodule CinegraphWeb.MovieLive.IndexV2.CanonicalizeTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.Person
  alias Cinegraph.Repo
  alias CinegraphWeb.MovieLive.IndexV2.Canonicalize
  alias CinegraphWeb.MovieLive.IndexV2Components.ParamHelpers

  describe "filter_params/2 people canonicalization" do
    test "preserves explicit people_ids instead of deriving a people slug" do
      slug_person = insert_person!("Slug Person")
      id_person = insert_person!("Explicit Person")

      params =
        Canonicalize.filter_params(socket(), %{
          "people" => slug_person.slug,
          "people_ids" => to_string(id_person.id),
          "people_role" => "director",
          "people_search[people_ids]" => to_string(slug_person.id),
          "people_search[role_filter]" => "cast"
        })

      assert params["people_ids"] == to_string(id_person.id)
      assert params["people_role"] == "director"
      refute Map.has_key?(params, "people")
      refute Map.has_key?(params, "people_search[people_ids]")
      refute Map.has_key?(params, "people_search[role_filter]")
    end

    test "clears stale role filters when no people resolve" do
      params =
        Canonicalize.filter_params(socket(), %{
          "people" => "not-a-real-person",
          "people_role" => "director",
          "people_search[people_ids]" => "",
          "people_search[role_filter]" => "director"
        })

      refute Map.has_key?(params, "people")
      refute Map.has_key?(params, "people_role")
      refute Map.has_key?(params, "people_search[people_ids]")
      refute Map.has_key?(params, "people_search[role_filter]")
    end

    test "clears stale people_ids when no people resolve" do
      params =
        Canonicalize.filter_params(socket(), %{
          "people_ids" => "-1",
          "people_role" => "director",
          "people_match" => "all"
        })

      refute Map.has_key?(params, "people_ids")
      refute Map.has_key?(params, "people_role")
      refute Map.has_key?(params, "people_match")
    end
  end

  describe "people_slug_cache_from_params/2" do
    test "merges ids found in params into the existing socket cache" do
      cached_person = insert_person!("Cached Person")
      param_person = insert_person!("Param Person")

      cache =
        Canonicalize.people_slug_cache_from_params(
          %{"people_ids" => to_string(param_person.id)},
          %{cached_person.id => cached_person.slug}
        )

      assert cache[cached_person.id] == cached_person.slug
      assert cache[param_person.id] == param_person.slug
    end

    test "uses explicit people_ids before people slugs when both are present" do
      slug_person = insert_person!("Slug Cache Person")
      id_person = insert_person!("ID Cache Person")

      cache =
        Canonicalize.people_slug_cache_from_params(%{
          "people" => slug_person.slug,
          "people_ids" => to_string(id_person.id)
        })

      assert cache == %{id_person.id => id_person.slug}
    end
  end

  describe "normalize_people_filter/1" do
    test "treats empty-string-only people_ids lists as absent" do
      params = ParamHelpers.normalize_people_filter(%{"people_ids" => [""]})

      refute Map.has_key?(params, "people")
      refute Map.has_key?(params, "people_ids")
    end

    test "keeps people_ids lists with at least one real value" do
      params = ParamHelpers.normalize_people_filter(%{"people_ids" => ["", "123"]})

      assert params["people"] == ["", "123"]
      refute Map.has_key?(params, "people_ids")
    end
  end

  defp socket do
    %{assigns: %{people_slug_cache: %{}, filter_options: %{}}}
  end

  defp insert_person!(name) do
    unique = System.unique_integer([:positive])

    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    %Person{}
    |> Person.changeset(%{
      tmdb_id: unique,
      name: "#{name} #{unique}",
      slug: "#{slug}-#{unique}"
    })
    |> Repo.insert!()
  end
end
