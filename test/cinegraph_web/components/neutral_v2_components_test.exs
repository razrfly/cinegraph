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

  describe "n_collaboration_card/1" do
    test "does not render a leading separator when person_a is missing" do
      html =
        render_component(&n_collaboration_card/1,
          collaboration: %{
            person_a: nil,
            person_b: "Greta Gerwig",
            films_together: 3,
            strength: :strong
          }
        )

      text = html |> Floki.parse_document!() |> Floki.text(sep: " ") |> String.trim()

      assert text =~ "Greta Gerwig"
      refute text =~ "· Greta Gerwig"
    end

    test "uses CSS spacing for optional year range separator" do
      html =
        render_component(&n_collaboration_card/1,
          collaboration: %{
            person_a: "Greta Gerwig",
            person_b: "Noah Baumbach",
            films_together: 4,
            strength: :strong,
            year_range: "2010-2024"
          }
        )

      assert html =~ ~s(class="mx-1">·</span>2010-2024)
      refute html =~ "·     2010-2024"
    end

    test "does not show card-level hover affordance on a non-interactive wrapper" do
      html =
        render_component(&n_collaboration_card/1,
          collaboration: %{
            person_a: "Greta Gerwig",
            person_b: "Noah Baumbach",
            films_together: 4,
            strength: :strong,
            href: "/collaborations/1"
          }
        )

      refute html =~ "hover:shadow"
      assert html =~ "hover:decoration"
    end

    test "renders poster chips for collaboration movies with poster paths" do
      html =
        render_component(&n_collaboration_card/1,
          collaboration: %{
            person_a: "Meryl Streep",
            person_b: "Emily Blunt",
            films_together: 2,
            strength: :moderate,
            movies: [
              %{
                id: 1,
                title: "The Devil Wears Prada",
                slug: "the-devil-wears-prada",
                release_date: ~D[2006-06-30],
                poster_path: "/poster.jpg"
              }
            ]
          }
        )

      assert html =~ ~s(src="https://image.tmdb.org/t/p/w92/poster.jpg")
      assert html =~ ~s(alt="The Devil Wears Prada")
    end

    test "falls back to year tiles for collaboration movies without posters" do
      html =
        render_component(&n_collaboration_card/1,
          collaboration: %{
            person_a: "Meryl Streep",
            person_b: "Anne Hathaway",
            films_together: 1,
            strength: :moderate,
            movies: [
              %{
                id: 1,
                title: "Posterless Movie",
                slug: "posterless-movie",
                release_date: ~D[2006-06-30],
                poster_path: nil
              }
            ]
          }
        )

      text = html |> Floki.parse_document!() |> Floki.text(sep: " ")

      refute html =~ "<img"
      assert text =~ "2006"
    end
  end
end
