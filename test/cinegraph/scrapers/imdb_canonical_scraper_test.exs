defmodule Cinegraph.Scrapers.ImdbCanonicalScraperTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Scrapers.ImdbCanonicalScraper

  describe "embedded __NEXT_DATA__ JSON parsing" do
    test "parses the full first-page list from __NEXT_DATA__ (not the ~75 DOM cap)" do
      edges =
        for i <- 1..100, do: edge(i, "tt#{1_000_000 + i}", "Movie #{i}", year: 1990 + rem(i, 30))

      html = next_data_html(edges)

      assert {:ok, movies} = ImdbCanonicalScraper.parse_single_page(html, 1, false)
      assert length(movies) == 100
      assert Enum.map(movies, & &1.position) |> Enum.take(3) == [1, 2, 3]
      assert List.first(movies).imdb_id == "tt1000001"
    end

    test "prefers originalTitleText over the localized titleText" do
      edges = [
        edge(1, "tt0068646", "The Godfather", localized: "Bố Già", year: 1972)
      ]

      assert {:ok, [movie]} =
               ImdbCanonicalScraper.parse_single_page(next_data_html(edges), 1, false)

      assert movie.title == "The Godfather"
      assert movie.year == 1972
      assert movie.position == 1
    end

    test "ignores recommendation-carousel links outside the list (pollution guard)" do
      edges = [
        edge(1, "tt0000001", "Real List Movie One"),
        edge(2, "tt0000002", "Real List Movie Two")
      ]

      # A "More to explore" carousel in the DOM with unrelated titles must NOT be tagged.
      carousel = """
      <section data-testid="more-to-explore">
        <a href="/title/tt9999991/">Recommended Movie A</a>
        <a href="/title/tt9999992/">Recommended Movie B</a>
      </section>
      """

      html = next_data_html(edges, extra_body: carousel)

      assert {:ok, movies} = ImdbCanonicalScraper.parse_single_page(html, 1, false)
      ids = Enum.map(movies, & &1.imdb_id)
      assert ids == ["tt0000001", "tt0000002"]
      refute "tt9999991" in ids
      refute "tt9999992" in ids
    end
  end

  describe "ld+json ItemList fallback" do
    test "parses ItemList when __NEXT_DATA__ is absent" do
      items = [
        ld_item(1, "tt0111161", "The Shawshank Redemption"),
        ld_item(2, "tt0068646", "The Godfather")
      ]

      assert {:ok, movies} = ImdbCanonicalScraper.parse_single_page(ld_json_html(items), 1, false)
      assert Enum.map(movies, & &1.imdb_id) == ["tt0111161", "tt0068646"]
      assert Enum.map(movies, & &1.title) == ["The Shawshank Redemption", "The Godfather"]
    end
  end

  describe "DOM fallback (legacy last resort)" do
    test "parse_single_page/3 returns absolute positions for page 2 windows" do
      html = """
      <html>
        <body>
          <div class="lister-item">
            <h3><a href="/title/tt0000001/">First Page Two Movie</a></h3>
            <span class="lister-item-year">(1984)</span>
          </div>
          <div class="lister-item">
            <h3><a href="/title/tt0000002/">Second Page Two Movie</a></h3>
            <span class="lister-item-year">(1985)</span>
          </div>
        </body>
      </html>
      """

      assert {:ok, movies} = ImdbCanonicalScraper.parse_single_page(html, 2, false)
      assert Enum.map(movies, & &1.position) == [76, 77]
    end

    test "parse_single_page/3 preserves absolute positions on alternative parser path" do
      html = """
      <html>
        <body>
          <section>
            <a href="/title/tt0000003/">Alternative Page Two Movie</a>
            <a href="/title/tt0000004/">Another Alternative Page Two Movie</a>
          </section>
        </body>
      </html>
      """

      assert {:ok, movies} = ImdbCanonicalScraper.parse_single_page(html, 2, false)
      assert Enum.map(movies, & &1.position) == [76, 77]
    end
  end

  # --- helpers ---

  defp edge(position, imdb_id, original_title, opts \\ []) do
    %{
      "node" => %{"absolutePosition" => position},
      "listItem" => %{
        "id" => imdb_id,
        "originalTitleText" => %{"text" => original_title},
        "titleText" => %{"text" => Keyword.get(opts, :localized, original_title)},
        "releaseYear" => %{"year" => Keyword.get(opts, :year)}
      }
    }
  end

  defp next_data_html(edges, opts \\ []) do
    data = %{
      "props" => %{
        "pageProps" => %{
          "mainColumnData" => %{
            "list" => %{
              "titleListItemSearch" => %{
                "total" => Keyword.get(opts, :total, length(edges)),
                "pageInfo" => %{
                  "hasNextPage" => Keyword.get(opts, :has_next, false),
                  "endCursor" => "CURSOR"
                },
                "edges" => edges
              }
            }
          }
        }
      }
    }

    """
    <html><body>
    #{Keyword.get(opts, :extra_body, "")}
    <script id="__NEXT_DATA__" type="application/json">#{Jason.encode!(data)}</script>
    </body></html>
    """
  end

  defp ld_item(position, imdb_id, name) do
    %{
      "@type" => "ListItem",
      "position" => position,
      "item" => %{
        "@type" => "Movie",
        "url" => "https://www.imdb.com/title/#{imdb_id}/",
        "name" => name
      }
    }
  end

  defp ld_json_html(items) do
    data = %{"@type" => "ItemList", "itemListElement" => items}

    """
    <html><body>
    <script type="application/ld+json">#{Jason.encode!(data)}</script>
    </body></html>
    """
  end
end
