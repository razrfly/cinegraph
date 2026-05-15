defmodule CinegraphWeb.SEOTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CinegraphWeb.SEO

  describe "meta_tags/1" do
    test "renders canonical meta assigns with JSON-LD" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            page_title: "Fallback Title",
            meta_title: "The Matrix (1999)",
            meta_description: "A hacker discovers reality is stranger than it looks.",
            meta_image: "https://image.tmdb.org/t/p/w1280/backdrop.jpg",
            meta_image_width: 1200,
            meta_image_height: 630,
            meta_type: "video.movie",
            canonical_url: "https://cinegraph.org/movies/the-matrix-1999",
            json_ld: %{"@context" => "https://schema.org", "@type" => "Movie"}
          }
        )

      assert html =~ ~S|<meta name="description" content="A hacker discovers reality|
      assert html =~ ~S|<link rel="canonical" href="https://cinegraph.org/movies/the-matrix-1999"|
      assert html =~ ~S|<meta property="og:type" content="video.movie"|
      assert html =~ ~S|<meta property="og:title" content="The Matrix (1999)"|

      assert html =~
               ~S|<meta property="og:image" content="https://image.tmdb.org/t/p/w1280/backdrop.jpg"|

      assert html =~ ~S|<meta property="og:image:width" content="1200"|
      assert html =~ ~S|<meta property="og:image:height" content="630"|
      assert html =~ ~S|<meta name="twitter:title" content="The Matrix (1999)"|
      assert html =~ ~s("Movie")
    end

    test "falls back to legacy og assigns" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            page_title: "Page Title",
            og_title: "Legacy Title",
            og_description: "Legacy description",
            og_image: "https://example.com/legacy.jpg",
            og_type: "profile",
            og_url: "https://cinegraph.org/legacy"
          }
        )

      assert html =~ ~S|<meta property="og:title" content="Legacy Title"|
      assert html =~ ~S|<meta property="og:description" content="Legacy description"|
      assert html =~ ~S|<meta property="og:image" content="https://example.com/legacy.jpg"|
      assert html =~ ~S|<meta property="og:type" content="profile"|
      assert html =~ ~S|<meta property="og:url" content="https://cinegraph.org/legacy"|
    end

    test "renders a list of JSON-LD schemas" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            page_title: "Schema Page",
            json_ld: [
              %{"@context" => "https://schema.org", "@type" => "Movie"},
              %{"@context" => "https://schema.org", "@type" => "BreadcrumbList"}
            ]
          }
        )

      assert html =~ ~s("Movie")
      assert html =~ ~s("BreadcrumbList")
      assert html |> String.split(~s(type="application/ld+json")) |> length() == 3
    end

    test "escapes closing script sequences in JSON-LD" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            page_title: "Schema Page",
            json_ld: %{
              "@context" => "https://schema.org",
              "@type" => "Movie",
              "name" => "</script>"
            }
          }
        )

      assert html =~ ~S(<\/script>)
      refute html =~ ~S("</script>")
    end

    test "omits image tags when no image is available" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            meta_title: "No Image",
            meta_description: "No image here."
          }
        )

      refute html =~ ~S|property="og:image"|
      refute html =~ ~S|name="twitter:image"|
    end

    test "omits image dimensions when they are not explicitly known" do
      html =
        render_component(&SEO.meta_tags/1,
          assigns: %{
            meta_title: "Poster Image",
            meta_description: "Uses a source image without known dimensions.",
            meta_image: "https://image.tmdb.org/t/p/w780/poster.jpg"
          }
        )

      assert html =~ ~S|property="og:image"|
      refute html =~ ~S|property="og:image:width"|
      refute html =~ ~S|property="og:image:height"|
    end
  end

  describe "movie_schema/1 (#913 PR A pt 2 — reads external_metrics, not JSONB)" do
    test "populates aggregateRating from external_metrics" do
      movie = %{
        id: 1,
        title: "Test Movie",
        slug: "test-movie",
        original_title: "Test Movie",
        overview: nil,
        release_date: nil,
        runtime: nil,
        poster_path: nil,
        original_language: nil,
        imdb_id: nil,
        tmdb_id: nil,
        origin_country: nil,
        external_metrics: [
          %{source: "tmdb", metric_type: "rating_average", value: 8.456},
          %{source: "tmdb", metric_type: "rating_votes", value: 12_345.0}
        ],
        production_companies: []
      }

      schema = SEO.movie_schema(movie)

      assert schema["aggregateRating"]["@type"] == "AggregateRating"
      # Float.round to 1 decimal place
      assert schema["aggregateRating"]["ratingValue"] == 8.5
      # trunc on float
      assert schema["aggregateRating"]["ratingCount"] == 12_345
      assert schema["aggregateRating"]["bestRating"] == 10
    end

    test "omits aggregateRating when external_metrics is empty" do
      movie = %{
        id: 1,
        title: "Test Movie",
        slug: "test-movie",
        original_title: "Test Movie",
        overview: nil,
        release_date: nil,
        runtime: nil,
        poster_path: nil,
        original_language: nil,
        imdb_id: nil,
        tmdb_id: nil,
        origin_country: nil,
        external_metrics: [],
        production_companies: []
      }

      refute Map.has_key?(SEO.movie_schema(movie), "aggregateRating")
    end

    test "omits aggregateRating when rating_average is missing" do
      movie = %{
        id: 1,
        title: "Test Movie",
        slug: "test-movie",
        original_title: "Test Movie",
        overview: nil,
        release_date: nil,
        runtime: nil,
        poster_path: nil,
        original_language: nil,
        imdb_id: nil,
        tmdb_id: nil,
        origin_country: nil,
        # rating_votes alone is not enough
        external_metrics: [%{source: "tmdb", metric_type: "rating_votes", value: 12_345.0}],
        production_companies: []
      }

      refute Map.has_key?(SEO.movie_schema(movie), "aggregateRating")
    end

    test "populates productionCompany from production_companies association" do
      movie = %{
        id: 1,
        title: "Test Movie",
        slug: "test-movie",
        original_title: "Test Movie",
        overview: nil,
        release_date: nil,
        runtime: nil,
        poster_path: nil,
        original_language: nil,
        imdb_id: nil,
        tmdb_id: nil,
        origin_country: nil,
        external_metrics: [],
        production_companies: [
          %{name: "A24"},
          %{name: "Plan B Entertainment"}
        ]
      }

      schema = SEO.movie_schema(movie)
      assert schema["productionCompany"]["@type"] == "Organization"
      assert schema["productionCompany"]["name"] == "A24"
    end

    test "omits productionCompany when association is empty" do
      movie = %{
        id: 1,
        title: "Test Movie",
        slug: "test-movie",
        original_title: "Test Movie",
        overview: nil,
        release_date: nil,
        runtime: nil,
        poster_path: nil,
        original_language: nil,
        imdb_id: nil,
        tmdb_id: nil,
        origin_country: nil,
        external_metrics: [],
        production_companies: []
      }

      refute Map.has_key?(SEO.movie_schema(movie), "productionCompany")
    end
  end
end
