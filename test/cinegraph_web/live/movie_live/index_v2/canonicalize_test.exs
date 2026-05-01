defmodule CinegraphWeb.MovieLive.IndexV2.CanonicalizeTest do
  use Cinegraph.DataCase, async: false

  alias Cinegraph.Movies.Person
  alias Cinegraph.Repo
  alias CinegraphWeb.MovieLive.IndexV2.Canonicalize

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
