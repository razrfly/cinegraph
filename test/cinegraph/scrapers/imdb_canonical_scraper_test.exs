defmodule Cinegraph.Scrapers.ImdbCanonicalScraperTest do
  use ExUnit.Case, async: true

  alias Cinegraph.Scrapers.ImdbCanonicalScraper

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

    assert Enum.map(movies, & &1.position) == [101, 102]
  end
end
