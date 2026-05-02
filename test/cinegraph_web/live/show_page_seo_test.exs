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

    assert html =~ ~s(<link rel="canonical" href="https://cinegraph.io/lists/#{list.slug}")
    assert html =~ ~s(<meta property="og:title" content="SEO Test List")
    assert html =~ ~s(<meta name="twitter:title" content="SEO Test List")
    assert html =~ ~s("ItemList")
    assert html =~ ~s("BreadcrumbList")
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

    assert html =~
             ~s(<link rel="canonical" href="https://cinegraph.io/awards/#{organization.slug}/winners")

    assert html =~ ~s(<meta property="og:title" content="SEO Test Awards Winners")
    assert html =~ ~s(<meta name="twitter:title" content="SEO Test Awards Winners")
    assert html =~ ~s("ItemList")
    assert html =~ ~s("BreadcrumbList")
  end
end
