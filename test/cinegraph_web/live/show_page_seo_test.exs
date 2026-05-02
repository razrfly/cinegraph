defmodule CinegraphWeb.ShowPageSEOTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Movies.MovieList
  alias Cinegraph.Repo

  setup do
    Cachex.clear(:filter_options_cache)
    :ok
  end

  test "list show renders SEO tags in the initial HTML", %{conn: conn} do
    list =
      %MovieList{}
      |> MovieList.changeset(%{
        source_key: "seo_test_list",
        name: "SEO Test List",
        description: "A carefully selected group of films.",
        source_type: "imdb",
        source_url: "https://www.imdb.com/list/ls123456789/",
        category: "curated",
        slug: "seo-test-list",
        active: true
      })
      |> Repo.insert!()

    {:ok, _view, html} = live(conn, ~p"/lists/#{list.slug}")
    document = Floki.parse_document!(html)

    assert document
           |> Floki.find(
             ~s(link[rel="canonical"][href="https://cinegraph.io/lists/#{list.slug}"])
           )
           |> Enum.any?()

    assert document
           |> Floki.find(~s(meta[property="og:title"][content="SEO Test List"]))
           |> Enum.any?()

    assert document
           |> Floki.find(~s(meta[name="twitter:title"][content="SEO Test List"]))
           |> Enum.any?()

    assert json_ld_types(document) |> Enum.member?("ItemList")
    assert json_ld_types(document) |> Enum.member?("BreadcrumbList")
  end

  test "award winners show renders mode-specific SEO tags in the initial HTML", %{conn: conn} do
    organization =
      %FestivalOrganization{}
      |> FestivalOrganization.changeset(%{
        name: "SEO Test Awards",
        slug: "seo-test-awards",
        abbreviation: "SEOT"
      })
      |> Repo.insert!()

    {:ok, _view, html} = live(conn, ~p"/awards/#{organization.slug}/winners")
    document = Floki.parse_document!(html)

    assert document
           |> Floki.find(
             ~s(link[rel="canonical"][href="https://cinegraph.io/awards/#{organization.slug}/winners"])
           )
           |> Enum.any?()

    assert document
           |> Floki.find(~s(meta[property="og:title"][content="SEO Test Awards Winners"]))
           |> Enum.any?()

    assert document
           |> Floki.find(~s(meta[name="twitter:title"][content="SEO Test Awards Winners"]))
           |> Enum.any?()

    assert json_ld_types(document) |> Enum.member?("ItemList")
    assert json_ld_types(document) |> Enum.member?("BreadcrumbList")
  end

  defp json_ld_types(document) do
    document
    |> Floki.find(~s(script[type="application/ld+json"]))
    |> Enum.flat_map(fn script ->
      script
      |> script_content()
      |> Jason.decode!()
      |> List.wrap()
      |> Enum.map(& &1["@type"])
    end)
  end

  defp script_content({_tag, _attrs, children}) do
    children
    |> Enum.map(fn
      child when is_binary(child) -> child
      child -> Floki.raw_html([child])
    end)
    |> Enum.join()
    |> String.trim()
  end
end
