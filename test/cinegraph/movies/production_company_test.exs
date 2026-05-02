defmodule Cinegraph.Movies.ProductionCompanyTest do
  use Cinegraph.DataCase, async: true

  alias Cinegraph.Movies
  alias Cinegraph.Movies.{Movie, ProductionCompany}
  alias Cinegraph.Maintenance.Companies

  describe "changeset/2" do
    test "accepts display and metadata fields" do
      changeset =
        ProductionCompany.changeset(%ProductionCompany{}, %{
          tmdb_id: 41_077,
          name: "A24",
          description: "Independent entertainment company.",
          website: "https://a24films.com",
          logo_url: "https://image.tmdb.org/t/p/original/a24.svg",
          hero_image_url: "https://example.com/a24-hero.jpg",
          metadata: %{"tmdb" => %{"company_details" => %{"id" => 41_077}}}
        })

      assert changeset.valid?
      assert get_change(changeset, :slug) == "a24"
      assert get_change(changeset, :metadata)["tmdb"]["company_details"]["id"] == 41_077
    end

    test "preserves and normalizes explicit slug" do
      changeset =
        ProductionCompany.changeset(%ProductionCompany{}, %{
          tmdb_id: 2,
          name: "Studio Ghibli",
          slug: "Studio Ghibli!"
        })

      assert changeset.valid?
      assert get_change(changeset, :slug) == "studio-ghibli"
    end

    test "rejects invalid display urls" do
      changeset =
        ProductionCompany.changeset(%ProductionCompany{}, %{
          tmdb_id: 3,
          name: "Bad Links",
          website: "javascript:alert(1)",
          logo_url: "not-a-url",
          hero_image_url: "ftp://example.com/hero.jpg"
        })

      refute changeset.valid?
      assert "must be a valid HTTP(S) URL" in errors_on(changeset).website
      assert "must be a valid HTTP(S) URL" in errors_on(changeset).logo_url
      assert "must be a valid HTTP(S) URL" in errors_on(changeset).hero_image_url
    end

    test "keeps basic TMDb company payload valid" do
      changeset =
        ProductionCompany.changeset(%ProductionCompany{}, %{
          tmdb_id: 4,
          name: "Basic Company",
          logo_path: "/basic.png",
          origin_country: "US"
        })

      assert changeset.valid?
      assert get_change(changeset, :slug) == "basic-company"
    end

    test "metadata defaults to empty map" do
      {:ok, company} =
        %ProductionCompany{}
        |> ProductionCompany.changeset(%{tmdb_id: 5, name: "Metadata Default"})
        |> Repo.insert()

      assert company.metadata == %{}
    end
  end

  describe "backfill_production_company_slugs/0" do
    test "fills missing slugs with stable duplicate suffixes" do
      company_a = insert_company!(tmdb_id: 10, name: "Duplicate Films", slug: "duplicate-films")
      company_b = insert_company!(tmdb_id: 11, name: "Duplicate Films", slug: "temporary-slug")

      Repo.update_all(from(c in ProductionCompany, where: c.id == ^company_b.id),
        set: [slug: nil]
      )

      assert {:ok, 1} = Movies.backfill_production_company_slugs()

      assert Repo.reload!(company_a).slug == "duplicate-films"
      assert Repo.reload!(company_b).slug == "duplicate-films-11"
    end
  end

  describe "company index stats and audit" do
    test "list_production_companies_with_stats/1 excludes orphans and counts full movies" do
      company = insert_company!(tmdb_id: 12, name: "Stats Company")
      orphan = insert_company!(tmdb_id: 13, name: "Orphan Company")
      full_movie = insert_movie!(title: "Full Movie", import_status: "full")
      soft_movie = insert_movie!(title: "Soft Movie", import_status: "soft")
      add_companies!(full_movie, [company])
      add_companies!(soft_movie, [company])

      companies = Movies.list_production_companies_with_stats()

      stats_company = Enum.find(companies, &(&1.id == company.id))
      refute Enum.any?(companies, &(&1.id == orphan.id))
      assert stats_company.movie_count == 1
      assert stats_company.latest_movie_title == "Full Movie"
    end

    test "audit detects SVG logo metadata and missing company metadata" do
      company =
        insert_company!(
          tmdb_id: 14,
          name: "Audit Company",
          logo_url: "https://example.com/audit.svg",
          metadata: %{
            "tmdb" => %{
              "selected_logo" => %{"file_type" => "svg"},
              "company_details" => %{"id" => 14}
            }
          }
        )

      add_companies!(insert_movie!(title: "Audit Movie"), [company])

      assert {:ok, audit} = Companies.audit()
      assert audit.companies_with_svg_logo >= 1
      assert audit.companies_missing_tmdb_images_metadata >= 1
    end
  end

  describe "refresh_production_company_metadata/2" do
    test "stores raw TMDb payloads and derives website and SVG logo_url" do
      company =
        insert_company!(
          tmdb_id: 41_077,
          name: "A24",
          metadata: %{"manual" => %{"note" => "keep"}}
        )

      fetched_at = ~U[2026-05-02 12:00:00Z]

      assert {:ok, refreshed} =
               Movies.refresh_production_company_metadata(company,
                 details_fetcher: fn 41_077 -> {:ok, company_details()} end,
                 images_fetcher: fn 41_077 -> {:ok, company_images()} end,
                 fetched_at: fetched_at
               )

      assert refreshed.website == "https://a24films.com"
      assert refreshed.logo_url == "https://image.tmdb.org/t/p/original/a24.svg"
      assert refreshed.logo_path == nil
      assert refreshed.metadata["manual"]["note"] == "keep"
      assert refreshed.metadata["tmdb"]["company_details"] == company_details()
      assert refreshed.metadata["tmdb"]["company_images"] == company_images()
      assert refreshed.metadata["tmdb"]["details_fetched_at"] == DateTime.to_iso8601(fetched_at)
      assert refreshed.metadata["tmdb"]["images_fetched_at"] == DateTime.to_iso8601(fetched_at)

      assert refreshed.metadata["tmdb"]["selected_logo"] == %{
               "file_path" => "/a24.svg",
               "file_type" => "svg",
               "iso_639_1" => "en",
               "chosen_from" => "tmdb_company_images",
               "vote_average" => 4.0,
               "vote_count" => 5
             }
    end

    test "falls back to existing logo_path when company images have no logos" do
      company = insert_company!(tmdb_id: 20, name: "Fallback Logo", logo_path: "/fallback.png")

      assert {:ok, refreshed} =
               Movies.refresh_production_company_metadata(company,
                 details_fetcher: fn 20 -> {:ok, %{"id" => 20, "homepage" => ""}} end,
                 images_fetcher: fn 20 -> {:ok, %{"logos" => []}} end,
                 fetched_at: ~U[2026-05-02 12:00:00Z]
               )

      assert refreshed.logo_url == "https://image.tmdb.org/t/p/w500/fallback.png"

      assert refreshed.metadata["tmdb"]["selected_logo"] == %{
               "file_path" => "/fallback.png",
               "file_type" => "png",
               "chosen_from" => "tmdb_embedded_logo_path"
             }
    end

    test "empty images response persists and leaves logo_url unchanged when no logo exists" do
      company = insert_company!(tmdb_id: 21, name: "No Logo")

      assert {:ok, refreshed} =
               Movies.refresh_production_company_metadata(company,
                 details_fetcher: fn 21 -> {:ok, %{"id" => 21}} end,
                 images_fetcher: fn 21 -> {:ok, %{"logos" => []}} end,
                 fetched_at: ~U[2026-05-02 12:00:00Z]
               )

      assert refreshed.logo_url == nil
      assert refreshed.metadata["tmdb"]["company_images"] == %{"logos" => []}
      refute Map.has_key?(refreshed.metadata["tmdb"], "selected_logo")
    end

    test "details fetch error leaves company unchanged" do
      company =
        insert_company!(
          tmdb_id: 22,
          name: "Details Error",
          website: "https://existing.example",
          metadata: %{"manual" => true}
        )

      assert {:error, {:company_details, :not_found}} =
               Movies.refresh_production_company_metadata(company,
                 details_fetcher: fn 22 -> {:error, :not_found} end,
                 images_fetcher: fn 22 -> {:ok, company_images()} end
               )

      unchanged = Repo.reload!(company)
      assert unchanged.website == "https://existing.example"
      assert unchanged.metadata == %{"manual" => true}
    end

    test "images fetch error leaves company unchanged" do
      company =
        insert_company!(
          tmdb_id: 23,
          name: "Images Error",
          metadata: %{"manual" => true}
        )

      assert {:error, {:company_images, :timeout}} =
               Movies.refresh_production_company_metadata(company,
                 details_fetcher: fn 23 -> {:ok, company_details()} end,
                 images_fetcher: fn 23 -> {:error, :timeout} end
               )

      assert Repo.reload!(company).metadata == %{"manual" => true}
    end

    test "accepts a production company ID" do
      company = insert_company!(tmdb_id: 24, name: "By ID")

      assert {:ok, refreshed} =
               Movies.refresh_production_company_metadata(company.id,
                 details_fetcher: fn 24 ->
                   {:ok, %{"id" => 24, "homepage" => "https://by-id.example"}}
                 end,
                 images_fetcher: fn 24 -> {:ok, %{"logos" => []}} end
               )

      assert refreshed.id == company.id
      assert refreshed.website == "https://by-id.example"
    end
  end

  defp insert_company!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      name: "Company #{System.unique_integer([:positive])}"
    }

    %ProductionCompany{}
    |> ProductionCompany.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp insert_movie!(attrs) do
    defaults = %{
      tmdb_id: System.unique_integer([:positive]),
      title: "Movie #{System.unique_integer([:positive])}",
      original_title: "Test Movie",
      release_date: ~D[2024-01-01],
      import_status: "full"
    }

    %Movie{}
    |> Movie.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp add_companies!(movie, companies) do
    rows =
      Enum.map(companies, fn company ->
        [movie_id: movie.id, production_company_id: company.id]
      end)

    Repo.insert_all("movie_production_companies", rows)
    movie
  end

  defp company_details do
    %{
      "id" => 41_077,
      "name" => "A24",
      "homepage" => "https://a24films.com"
    }
  end

  defp company_images do
    %{
      "logos" => [
        %{
          "file_path" => "/a24.png",
          "file_type" => ".png",
          "iso_639_1" => "en",
          "vote_average" => 10.0,
          "vote_count" => 100
        },
        %{
          "file_path" => "/a24.svg",
          "file_type" => ".svg",
          "iso_639_1" => "en",
          "vote_average" => 4.0,
          "vote_count" => 5
        }
      ]
    }
  end
end
