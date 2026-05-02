defmodule CinegraphWeb.MovieLive.ShowV2.ProductionDetailsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CinegraphWeb.MovieLive.ShowV2.ProductionDetails

  describe "production_details/1" do
    test "preserves the em dash fallback for missing and blank names" do
      html =
        render_component(&ProductionDetails.production_details/1,
          production_companies: [
            %{id: 1, name: nil},
            %{id: 2, name: "   "}
          ]
        )

      assert length(Regex.scan(~r/—/, html)) == 2
      refute html =~ ~r/>\s+-\s*</
    end
  end

  describe "hero_production_companies/1" do
    test "renders logo_path as a linked hero logo" do
      html =
        render_component(&ProductionDetails.hero_production_companies/1,
          production_companies: [
            %{id: 1, slug: "a24", name: "A24", logo_path: "/a24.png"}
          ]
        )

      assert html =~ "Studios"
      assert html =~ ~s(href="/companies/a24")
      assert html =~ ~s(src="https://image.tmdb.org/t/p/w92/a24.png")
      assert html =~ ~s(alt="A24")
    end

    test "falls back to stored logo_url when logo_path is missing" do
      html =
        render_component(&ProductionDetails.hero_production_companies/1,
          production_companies: [
            %{id: 2, slug: "neon", name: "Neon", logo_url: "https://example.com/neon.svg"}
          ]
        )

      assert html =~ ~s(href="/companies/neon")
      assert html =~ ~s(src="https://example.com/neon.svg")
      assert html =~ ~s(alt="Neon")
    end

    test "renders linked name fallback when no logo exists" do
      html =
        render_component(&ProductionDetails.hero_production_companies/1,
          production_companies: [
            %{id: 3, slug: "fallback-studio", name: "Fallback Studio"}
          ]
        )

      assert html =~ ~s(href="/companies/fallback-studio")
      assert html =~ "Fallback Studio"
      refute html =~ "<img"
    end

    test "limits visible companies and shows overflow count" do
      html =
        render_component(&ProductionDetails.hero_production_companies/1,
          production_companies: [
            %{id: 1, slug: "one", name: "One"},
            %{id: 2, slug: "two", name: "Two"},
            %{id: 3, slug: "three", name: "Three"},
            %{id: 4, slug: "four", name: "Four"},
            %{id: 5, slug: "five", name: "Five"}
          ]
        )

      assert html =~ "One"
      assert html =~ "Two"
      assert html =~ "Three"
      refute html =~ "Four"
      refute html =~ "Five"
      assert html =~ "+2"
    end
  end
end
