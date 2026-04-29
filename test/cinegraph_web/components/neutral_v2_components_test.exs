defmodule CinegraphWeb.NeutralV2ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import CinegraphWeb.NeutralV2Components

  describe "n_film_card/1" do
    test "generates a poster SVG from rich film data" do
      html =
        render_component(&n_film_card/1,
          film: %{
            id: 101,
            title: "The Matrix",
            year: 1999,
            dir: "Lana Wachowski",
            genre: ["Sci-Fi"]
          }
        )

      {:ok, document} = Floki.parse_document(html)
      [src] = Floki.attribute(document, "img", "src")

      assert src =~ "data:image/svg+xml"
      assert URI.decode(src) =~ "The Matrix"
      assert URI.decode(src) =~ "LANA WACHOWSKI"
    end
  end

  describe "n_score_bar/1" do
    test "renders zero as a real score with an empty bar" do
      html = render_component(&n_score_bar/1, label: "Popularity", value: 0)
      text = html |> Floki.parse_document!() |> Floki.text()

      assert text =~ "0.0"
      assert html =~ ~s(style="width: 0%")
      refute text =~ "—"
    end
  end
end
