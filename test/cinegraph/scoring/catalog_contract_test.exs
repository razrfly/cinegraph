defmodule Cinegraph.Scoring.CatalogContractTest do
  @moduledoc """
  Complete registry↔feed contract for the Layer-0 catalog (#1036 Session 1 + 2.5).

  The Session-1 version of this test was fixture-scoped to external metrics only, so it
  could pass while the full catalog and the full `metric_values_view` silently disagreed
  (Session 2.5 found 33 emitted-but-uncatalogued + 14 catalogued-but-unemitted codes).

  This version is a STRUCTURAL reconciliation: a single fixture movie is given one instance
  of EVERY catalogued raw source (external numeric + text, festival, canonical, movie columns,
  junctions, video, person), and we assert both directions hold:
    * backward — every catalogued raw+available code is emitted (reachability)
    * forward  — every emitted code is catalogued-active OR a member of a dynamic family
                 (festival `{abbr}_win/_nom` ↔ festival_organizations; canonical key ↔ movie_lists)
  Derived / unavailable rows are exempt from emission but must still be catalogued correctly.
  """
  use Cinegraph.DataCase

  alias Cinegraph.Metrics
  alias Cinegraph.Metrics.{CatalogSeed, MetricDefinition}
  alias Cinegraph.Movies.{Credit, Movie, Person}
  alias Cinegraph.Scoring.DerivedFeatures

  alias Cinegraph.Festivals.{
    FestivalCategory,
    FestivalCeremony,
    FestivalNomination,
    FestivalOrganization
  }

  alias Cinegraph.Repo

  setup do
    CatalogSeed.seed!()
    :ok
  end

  @expected_members %{
    "mob" => ~w(imdb_rating tmdb_rating),
    "critics" => ~w(metacritic_metascore rotten_tomatoes_tomatometer),
    "box_office" => ~w(tmdb_budget tmdb_revenue_worldwide),
    "auteurs" => ~w(person_quality_score),
    "time_machine" =>
      ~w(1001_movies afi_100 bfi_top_100 criterion national_film_registry sight_sound_critics_2022 tmdb_popularity_score),
    "festival_recognition" =>
      ~w(berlin_golden_bear cannes_palme_dor oscar_nominations oscar_wins venice_golden_lion)
  }

  # Canonical keys the catalog knows about, with a representative JSONB value per key.
  @canonical_keys %{
    "1001_movies" => true,
    "criterion" => true,
    "national_film_registry" => true,
    "sight_sound_critics_2022" => 50,
    "afi_100" => 50,
    "bfi_top_100" => 50
  }

  describe "lens membership reflects the :absolute formulas" do
    test "absolute_lens_members matches the reconciled membership for every lens" do
      for {lens, expected} <- @expected_members do
        actual = Metrics.absolute_lens_members(lens) |> Enum.map(& &1.code)

        assert MapSet.new(actual) == MapSet.new(expected),
               "lens #{lens}: expected #{inspect(expected)}, got #{inspect(actual)}"
      end
    end
  end

  describe "catalog integrity" do
    test "every active raw available definition has a usable source mapping" do
      offenders =
        Metrics.list_metric_definitions(only_available: true, kind: "raw")
        |> Enum.filter(fn d ->
          is_nil(d.source_table) or is_nil(d.source_field) or
            (d.source_table == "external_metrics" and is_nil(d.source_type))
        end)
        |> Enum.map(& &1.code)

      assert offenders == [],
             "raw available rows with an incomplete source mapping: #{inspect(offenders)}"
    end

    test "derived rows declare a derivation; ML-only rows have no lens" do
      derived = Metrics.list_metric_definitions(kind: "derived")
      assert derived != []
      assert Enum.all?(derived, &(&1.derivation not in [nil, ""]))

      ml_only = Metrics.list_metric_definitions() |> Enum.filter(&is_nil(&1.category))
      assert "runtime" in Enum.map(ml_only, & &1.code)
      assert Enum.all?(ml_only, &(&1.kind in ["raw", "derived"]))
    end

    test "available derived codes exactly match DerivedFeatures.supported_codes/0 (#1044)" do
      # The catalog's is_available flag is documentary for derived codes (routing gates on
      # supported_codes/0), but the two must agree: the catalog must not hide a derived feature the
      # data-point surface emits, nor advertise one it doesn't. prior_collab_density closed the gap.
      available_derived =
        Metrics.list_metric_definitions(only_available: true, kind: "derived")
        |> Enum.map(& &1.code)
        |> MapSet.new()

      assert available_derived == MapSet.new(DerivedFeatures.supported_codes())
      assert "prior_collab_density" in available_derived
    end
  end

  describe "complete registry↔feed reconciliation (live structural contract)" do
    setup do
      movie = plant_full_movie()
      %{movie: movie}
    end

    test "backward: every catalogued raw+available code is emitted (reachability)", %{
      movie: movie
    } do
      catalogued =
        Metrics.list_metric_definitions(only_available: true, kind: "raw")
        |> Enum.map(& &1.code)
        |> MapSet.new()

      emitted = emitted_codes(movie.id)
      unreachable = MapSet.difference(catalogued, emitted) |> MapSet.to_list() |> Enum.sort()

      assert unreachable == [],
             "catalogued raw+available codes the view cannot emit (no branch): #{inspect(unreachable)}"
    end

    test "forward: every emitted code is catalogued-active or a dynamic-family member", %{
      movie: movie
    } do
      catalogued = MapSet.new(active_codes())
      families = dynamic_family_context()

      orphans =
        emitted_codes(movie.id)
        |> Enum.reject(fn code ->
          MapSet.member?(catalogued, code) or dynamic_family?(code, families)
        end)
        |> Enum.sort()

      assert orphans == [],
             "emitted codes that are neither catalogued nor a dynamic family: #{inspect(orphans)}"
    end

    test "every emitted external/canonical/junction numeric row carries a normalized_value",
         %{movie: movie} do
      # Categorical/text metrics (e.g. original_language, content_rating) legitimately have a
      # null normalized_value; numeric ones must be normalized when catalogued.
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT v.metric_code
          FROM metric_values_view v
          JOIN metric_definitions md ON md.code = v.metric_code AND md.active = true
          WHERE v.movie_id = $1 AND v.raw_value_numeric IS NOT NULL AND v.normalized_value IS NULL
          """,
          [movie.id]
        )

      assert rows == [], "catalogued numeric codes missing a normalized_value: #{inspect(rows)}"
    end
  end

  describe "dynamic-family rule" do
    test "an uncatalogued festival org emits a {abbr}_win code accepted as a family member" do
      movie = plant_movie()
      org = plant_org!("ZZZ")
      plant_nom!(org, movie, true)

      emitted = emitted_codes(movie.id)
      assert MapSet.member?(emitted, "zzz_win")
      refute "zzz_win" in active_codes(), "precondition: zzz_win must be uncatalogued"
      assert dynamic_family?("zzz_win", dynamic_family_context())
    end

    test "an uncatalogued-but-in-movie_lists canonical key is accepted as a family member" do
      Repo.insert_all("movie_lists", [movie_list_row("cult_movies_400")])
      movie = plant_movie(canonical_sources: %{"cult_movies_400" => true})

      emitted = emitted_codes(movie.id)
      assert MapSet.member?(emitted, "cult_movies_400")
      refute "cult_movies_400" in active_codes(), "precondition: must be uncatalogued"
      assert dynamic_family?("cult_movies_400", dynamic_family_context())
    end

    test "a canonical key absent from movie_lists is NOT a family member (would be flagged)" do
      movie = plant_movie(canonical_sources: %{"totally_bogus_xyz" => true})

      assert MapSet.member?(emitted_codes(movie.id), "totally_bogus_xyz")
      refute dynamic_family?("totally_bogus_xyz", dynamic_family_context())
    end
  end

  describe "dynamic-family auto-cataloguing (DB-driven generators)" do
    test "seeding generates normalized ML-only rows for festival orgs and movie lists" do
      # A festival org (the view emits `lff_win`/`lff_nom` for it) and a curated list.
      plant_org!("LFF")
      Repo.insert_all("movie_lists", [movie_list_row("tspdt_1000")])

      # Re-seed now that the DB has these rows — the generators pick them up.
      CatalogSeed.seed!()

      defs = Metrics.list_metric_definitions() |> Map.new(&{&1.code, &1})

      for code <- ["lff_win", "lff_nom", "tspdt_1000"] do
        assert d = defs[code], "expected generated catalog row for #{code}"
        assert d.category == nil, "#{code} must be ML-only (no lens)"
        assert d.normalization_type == "boolean"
        assert d.kind == "raw" and d.is_available
      end

      # And the generated code now normalizes in the feed.
      movie = plant_movie(canonical_sources: %{"tspdt_1000" => true})

      {:ok, %{rows: [[norm]]}} =
        Repo.query(
          "SELECT normalized_value FROM metric_values_view WHERE movie_id = $1 AND metric_code = 'tspdt_1000'",
          [movie.id]
        )

      assert norm == 1.0, "auto-catalogued list code must carry a normalized_value"
    end

    test "generators never duplicate or override a hand-curated code" do
      # afi_100 / oscar_wins are hand-curated; planting orgs/lists that could collide
      # must not produce a second row or change their normalization.
      plant_org!("AMPAS")
      Repo.insert_all("movie_lists", [movie_list_row("afi_100")])
      CatalogSeed.seed!()

      assert Metrics.get_metric_definition("afi_100").normalization_type == "sigmoid"
      assert Metrics.get_metric_definition("oscar_wins").category == "festival_recognition"
      assert length(Enum.filter(Metrics.list_metric_definitions(), &(&1.code == "afi_100"))) == 1
    end
  end

  describe "adding a data point (the robustness contract)" do
    test "a new catalog row flows to the score AND the view with no formula change" do
      movie = plant_movie()
      now = now()

      # A real mob rating present, plus a brand-new mob source (Letterboxd, 0–5 scale).
      Repo.insert_all("external_metrics", [
        ext_row(movie.id, "imdb", "rating_average", 8.0, now),
        ext_row(movie.id, "letterboxd", "rating", 2.0, now)
      ])

      # Before cataloguing letterboxd, mob = imdb only = 8.0 (the new source is ignored).
      before = Cinegraph.Movies.MovieScoring.calculate_movie_scores(movie).components.mob
      assert before == 8.0

      # One catalog row — no formula code touched.
      {:ok, _} =
        %MetricDefinition{}
        |> MetricDefinition.changeset(%{
          code: "letterboxd_rating",
          name: "Letterboxd Rating",
          source_table: "external_metrics",
          source_type: "letterboxd",
          source_field: "rating",
          category: "mob",
          normalization_type: "linear",
          raw_scale_min: 0.0,
          raw_scale_max: 5.0,
          kind: "raw",
          is_available: true
        })
        |> Repo.insert()

      # Now it flows into the mob lens: letterboxd 2.0/5 → 4.0 on the 0–10 scale,
      # mob = mean(imdb 8.0, letterboxd 4.0) = 6.0. The score MOVED — inclusion is real.
      after_add = Cinegraph.Movies.MovieScoring.calculate_movie_scores(movie).components.mob
      assert after_add == 6.0, "new mob member must flow into the lens with no code change"

      # And it is emitted by the view, normalized (2.0 / 5.0 = 0.4).
      {:ok, %{rows: [[normalized]]}} =
        Repo.query(
          "SELECT normalized_value FROM metric_values_view WHERE movie_id = $1 AND metric_code = 'letterboxd_rating'",
          [movie.id]
        )

      assert_in_delta normalized, 0.4, 1.0e-6
    end
  end

  # ---- fixtures -----------------------------------------------------------------

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp uniq, do: System.unique_integer([:positive])

  defp plant_movie(opts \\ []) do
    attrs =
      %{
        tmdb_id: uniq(),
        title: "Contract #{uniq()}",
        release_date: ~D[2015-01-01]
      }
      |> Map.merge(Map.new(opts))

    %Movie{}
    |> Movie.changeset(attrs)
    |> Repo.insert!()
  end

  # A movie carrying one instance of every catalogued raw source across all source tables.
  defp plant_full_movie do
    movie = plant_movie(canonical_sources: @canonical_keys)

    # Movie-column attributes (force-set, in case the changeset doesn't cast them).
    movie =
      movie
      |> Ecto.Changeset.change(runtime: 120, original_language: "en", collection_id: 42)
      |> Repo.update!()

    now = now()

    # External metrics: one row per catalogued external raw+available def.
    # content_rating is text-only (numeric value is NULL) — exercise the text path.
    external_rows =
      Metrics.list_metric_definitions(only_available: true, kind: "raw")
      |> Enum.filter(&(&1.source_table == "external_metrics"))
      |> Enum.map(fn d ->
        if d.source_field == "content_rating" do
          ext_row(movie.id, d.source_type, d.source_field, nil, now, "PG-13")
        else
          ext_row(movie.id, d.source_type, d.source_field, 1.0, now)
        end
      end)

    Repo.insert_all("external_metrics", external_rows)

    # Festival nominations: the four catalogued special-case organizations.
    ampas = plant_org!("AMPAS")
    plant_nom!(ampas, movie, true)
    plant_nom!(ampas, movie, false)
    plant_nom!(plant_org!("CANNES"), movie, true)
    plant_nom!(plant_org!("VIFF"), movie, true)
    plant_nom!(plant_org!("BERLINALE"), movie, true)

    # Person quality score.
    person =
      %Person{} |> Person.changeset(%{tmdb_id: uniq(), name: "P #{uniq()}"}) |> Repo.insert!()

    %Credit{}
    |> Credit.changeset(%{
      movie_id: movie.id,
      person_id: person.id,
      credit_type: "cast",
      character: "Self",
      cast_order: 0,
      credit_id: "credit-#{uniq()}"
    })
    |> Repo.insert!()

    Repo.insert_all("person_metrics", [
      %{
        person_id: person.id,
        metric_type: "quality_score",
        score: 7.5,
        calculated_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])

    # Junctions: genre, keyword, production country.
    genre = parent_row!("genres", now)
    keyword = parent_row!("keywords", now)
    country = parent_row!("production_countries", now, %{iso_3166_1: "US-#{uniq()}"})

    Repo.insert_all("movie_genres", [%{movie_id: movie.id, genre_id: genre}])
    Repo.insert_all("movie_keywords", [%{movie_id: movie.id, keyword_id: keyword}])

    Repo.insert_all("movie_production_countries", [
      %{movie_id: movie.id, production_country_id: country}
    ])

    # Official trailer.
    Repo.insert_all("movie_videos", [
      %{
        movie_id: movie.id,
        tmdb_id: "v-#{uniq()}",
        name: "Official Trailer",
        key: "k-#{uniq()}",
        site: "YouTube",
        type: "Trailer",
        official: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    movie
  end

  defp parent_row!(table, now, extra \\ %{}) do
    base = %{tmdb_id: uniq(), name: "X #{uniq()}", inserted_at: now, updated_at: now}
    # production_countries has no tmdb_id; iso_3166_1 instead.
    attrs =
      case table do
        "production_countries" -> %{name: "X #{uniq()}", inserted_at: now, updated_at: now}
        _ -> base
      end
      |> Map.merge(extra)

    {1, [%{id: id}]} = Repo.insert_all(table, [attrs], returning: [:id])
    id
  end

  # Returns {org, ceremony}. One ceremony per org (the schema has a unique (org_id, year)).
  defp plant_org!(abbr) do
    org =
      %FestivalOrganization{}
      |> FestivalOrganization.changeset(%{name: "Org #{abbr} #{uniq()}", abbreviation: abbr})
      |> Repo.insert!()

    ceremony =
      %FestivalCeremony{
        organization_id: org.id,
        year: 2024,
        name: "Cer #{uniq()}",
        data_source: "test",
        date: ~D[2024-01-01]
      }
      |> Repo.insert!()

    {org, ceremony}
  end

  defp plant_nom!({org, ceremony}, movie, won) do
    category =
      %FestivalCategory{}
      |> FestivalCategory.changeset(%{organization_id: org.id, name: "Cat #{uniq()}"})
      |> Repo.insert!()

    %FestivalNomination{}
    |> FestivalNomination.changeset(%{
      ceremony_id: ceremony.id,
      category_id: category.id,
      movie_id: movie.id,
      won: won,
      details: %{}
    })
    |> Repo.insert!()
  end

  defp ext_row(movie_id, source, metric_type, value, now, text_value \\ nil) do
    %{
      movie_id: movie_id,
      source: source,
      metric_type: metric_type,
      value: value,
      text_value: text_value,
      fetched_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp movie_list_row(source_key) do
    now = now()

    %{
      name: "List #{source_key}",
      source_key: source_key,
      source_type: "imdb",
      source_url: "https://example.com/list/#{source_key}",
      category: "test",
      slug: "#{source_key}-#{uniq()}",
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end

  # ---- reconciliation helpers ---------------------------------------------------

  defp emitted_codes(movie_id) do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT DISTINCT metric_code FROM metric_values_view WHERE movie_id = $1", [
        movie_id
      ])

    rows |> List.flatten() |> MapSet.new()
  end

  defp active_codes do
    # active: true is explicit — the forward contract's "catalogued" set is active-only.
    Metrics.list_metric_definitions(active: true) |> Enum.map(& &1.code)
  end

  defp dynamic_family_context do
    {:ok, %{rows: abbrs}} =
      Repo.query("SELECT DISTINCT LOWER(abbreviation) FROM festival_organizations")

    {:ok, %{rows: keys}} = Repo.query("SELECT source_key FROM movie_lists")

    %{
      abbrs: abbrs |> List.flatten() |> MapSet.new(),
      list_keys: keys |> List.flatten() |> MapSet.new()
    }
  end

  defp dynamic_family?(code, %{abbrs: abbrs, list_keys: list_keys}) do
    MapSet.member?(list_keys, code) or
      (Regex.match?(~r/^[a-z0-9]+_(win|nom)$/, code) and
         MapSet.member?(abbrs, Regex.replace(~r/_(win|nom)$/, code, "")))
  end
end
