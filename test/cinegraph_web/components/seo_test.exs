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
end
