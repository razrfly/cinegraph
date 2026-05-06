defmodule CinegraphWeb.Admin.FestivalsLive.IndexTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Repo

  setup do
    # Insert a clean test festival org so we don't depend on the full seeded
    # set in dev DB. ConnCase wraps in a sandbox transaction by default.
    {:ok, org} =
      %FestivalOrganization{}
      |> FestivalOrganization.changeset(%{
        name: "Test Festival #{System.unique_integer([:positive])}",
        country: "Testland",
        prestige_tier: 3
      })
      |> Repo.insert()

    %{org: org}
  end

  describe "GET /admin/festivals" do
    test "renders the table with the test org", %{conn: conn, org: org} do
      {:ok, _live, html} = live(conn, ~p"/admin/festivals")

      assert html =~ "Festivals"
      assert html =~ org.name
      assert html =~ "no logo"
      assert html =~ "no hero"
    end

    test "edit_org event opens the drawer", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      result = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      assert result =~ "Identity"
      assert result =~ "Imagery"
      assert result =~ org.name
    end

    test "saving with a paste-URL persists logo_url", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      url = "https://example.test/logo.png"

      _ =
        render_submit(live, "save", %{
          "organization" => %{
            "name" => org.name,
            "logo_url" => url,
            "hero_image_url" => "",
            "country" => org.country
          }
        })

      reloaded =
        Festivals.get_organization_by_slug(org.slug) || Repo.get!(FestivalOrganization, org.id)

      assert reloaded.logo_url == url
    end

    test "close_drawer clears the editing state", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      after_close = render_click(live, "close_drawer", %{})

      # Admin layout's mobile menu also uses role="dialog"; use the festival
      # drawer's unique close-button aria-label.
      refute after_close =~ ~s(aria-label="Close drawer")
    end

    test "open_suggest with a known field initializes suggest UI", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      after_suggest = render_click(live, "open_suggest", %{"field" => "logo_url"})

      assert after_suggest =~ "Suggest images"
    end
  end
end
