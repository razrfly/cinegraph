defmodule CinegraphWeb.Admin.FestivalsLive.IndexTest do
  use CinegraphWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinegraph.Festivals
  alias Cinegraph.Festivals.FestivalOrganization
  alias Cinegraph.Images.R2Stub
  alias Cinegraph.Repo

  @cdn_base "https://test-cdn.example"

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

    # Reset stub state for each test (test process owns the dictionary).
    R2Stub.reset!()
    on_exit(fn -> R2Stub.reset!() end)

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

    test "close_drawer clears the editing state", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      after_close = render_click(live, "close_drawer", %{})

      # Admin layout's mobile menu also uses role="dialog"; use the festival
      # drawer's unique close-button aria-label.
      refute after_close =~ ~s(aria-label="Close drawer")
    end

    test "open_suggest works for hero (logo no longer supports suggest)", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")

      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      # Hero field still supports the suggest modal.
      after_suggest = render_click(live, "open_suggest", %{"field" => "hero_image_url"})

      # Suggest modal renders headline.
      assert after_suggest =~ "Click a result to use it for"
    end
  end

  # The four named tests from issue #890 acceptance criteria.

  describe "save flow — R2 rehost (#890)" do
    test "rehosts pasted external URL to R2 on save", %{conn: conn, org: org} do
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

      reloaded = Repo.get!(FestivalOrganization, org.id)

      # Stub returns a URL on the test-cdn host. Ensure save persisted that,
      # not the original external URL.
      assert String.starts_with?(reloaded.logo_url, @cdn_base)
      assert reloaded.logo_url =~ "/festivals/#{org.slug}/logo-"

      # Stub recorded a put_curated_image call with {:url, ...} source.
      [{:put_curated_image, args}] = R2Stub.calls()
      assert args.kind == "logo"
      assert args.identifier == org.slug
      assert args.source == {:url, url}
    end

    test "saves original URL with flash hint when R2 not configured", %{conn: conn, org: org} do
      R2Stub.disable!()

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

      reloaded = Repo.get!(FestivalOrganization, org.id)

      # When R2 is disabled, the original URL is persisted unchanged.
      assert reloaded.logo_url == url

      # Stub was NOT called — the rehost path is short-circuited.
      assert R2Stub.calls() == []
    end

    test "shows form error when paste-URL fetch fails on save", %{conn: conn, org: org} do
      R2Stub.put_response({:error, {:http_error, 404}})

      {:ok, live, _html} = live(conn, ~p"/admin/festivals")
      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      url = "https://broken.test/logo.png"

      result =
        render_submit(live, "save", %{
          "organization" => %{
            "name" => org.name,
            "logo_url" => url,
            "hero_image_url" => "",
            "country" => org.country
          }
        })

      reloaded = Repo.get!(FestivalOrganization, org.id)

      # Save aborted — DB unchanged.
      assert reloaded.logo_url in [nil, ""]

      # Error message surfaced in the LiveView.
      assert result =~ "Could not rehost logo"
      assert result =~ "HTTP 404"
    end

    test "skips rehost when URL already on our CDN (idempotent)", %{conn: conn, org: org} do
      cdn_url = "#{@cdn_base}/festivals/#{org.slug}/logo-deadbeef.svg"

      # Persist a URL already on the CDN to simulate a saved-then-resaved org.
      {:ok, _} = Festivals.update_organization(org, %{logo_url: cdn_url})

      org = Repo.get!(FestivalOrganization, org.id)

      {:ok, live, _html} = live(conn, ~p"/admin/festivals")
      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      _ =
        render_submit(live, "save", %{
          "organization" => %{
            "name" => org.name,
            "logo_url" => cdn_url,
            "hero_image_url" => "",
            "country" => org.country
          }
        })

      reloaded = Repo.get!(FestivalOrganization, org.id)
      assert reloaded.logo_url == cdn_url

      # No R2 calls — idempotent re-save.
      assert R2Stub.calls() == []
    end

    test "uploads logo file to R2 and updates logo_url", %{conn: conn, org: org} do
      {:ok, live, _html} = live(conn, ~p"/admin/festivals")
      _ = render_click(live, "edit_org", %{"id" => to_string(org.id)})

      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)

      logo_upload =
        file_input(live, "#org-form-#{org.id}", :logo_upload, [
          %{name: "test-logo.png", content: png_bytes, type: "image/png"}
        ])

      assert render_upload(logo_upload, "test-logo.png") =~ "test-logo.png"

      _ =
        render_submit(live, "save", %{
          "organization" => %{
            "name" => org.name,
            "logo_url" => "",
            "hero_image_url" => "",
            "country" => org.country
          }
        })

      reloaded = Repo.get!(FestivalOrganization, org.id)

      assert String.starts_with?(reloaded.logo_url, @cdn_base)
      assert reloaded.logo_url =~ "/festivals/#{org.slug}/logo-"

      # Stub recorded a put_curated_image with the {:upload, filename, byte_size} source.
      [{:put_curated_image, args}] = R2Stub.calls()
      assert args.kind == "logo"
      assert match?({:upload, "test-logo.png", _byte_size}, args.source)
    end
  end
end
