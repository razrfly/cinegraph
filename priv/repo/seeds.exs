# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Cinegraph.Repo.insert!(%Cinegraph.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

require Logger

Logger.info("Running seeds...")

# Seed movie lists (DB is the single source of truth)
Logger.info("Seeding default movie lists...")
result = Cinegraph.Movies.MovieLists.seed_default_lists()

Logger.info("""
Movie Lists Seeding Results:
  - Created: #{result.created}
  - Already existed: #{result.existed}
  - Errors: #{length(result.errors)}
  - Total processed: #{result.total}
""")

if length(result.errors) > 0 do
  Logger.warning("Errors occurred during seeding:")

  Enum.each(result.errors, fn {:error, source_key, changeset} ->
    Logger.warning("  - #{source_key}: #{inspect(changeset.errors)}")
  end)
end

# Seed festival events
Logger.info("Seeding festival events...")

alias Cinegraph.Events

# Academy Awards (Oscars) - Official source
case Events.get_by_source_key("oscars") do
  nil ->
    {:ok, _oscar_event} =
      Events.create_festival_event(%{
        source_key: "oscars",
        name: "Academy Awards",
        abbreviation: "AMPAS",
        country: "USA",
        founded_year: 1929,
        website: "https://www.oscars.org",
        primary_source: "official",
        source_config: %{
          "base_url" => "https://www.oscars.org",
          "ceremony_path_template" => "/ceremonies/{year}",
          "scraping_method" => "html_parser"
        },
        typical_start_month: 3,
        typical_start_day: 10,
        typical_duration_days: 1,
        ceremony_vs_festival: "ceremony",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1929,
        max_available_year: 2024,
        import_priority: 100,
        reliability_score: 0.95,
        metadata: %{
          "organization" => "Academy of Motion Picture Arts and Sciences",
          "categories_structure" => "hierarchical",
          "parser_hints" => %{
            "expected_format" => "structured_categories",
            "category_path" => "categories"
          }
        }
      })

    Logger.info("  ✅ Created Oscar events configuration")

  _ ->
    Logger.info("  ⏭️  Oscar events already exists")
end

# Cannes Film Festival - IMDb source
case Events.get_by_source_key("cannes") do
  nil ->
    {:ok, _cannes_event} =
      Events.create_festival_event(%{
        source_key: "cannes",
        name: "Cannes Film Festival",
        abbreviation: "CFF",
        country: "France",
        founded_year: 1946,
        website: "https://www.festival-cannes.com",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000147",
          "imdb_event_id" => "ev0000147",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.festival-cannes.com/en/archives/{year}"}
        ],
        typical_start_month: 5,
        typical_start_day: 14,
        typical_duration_days: 11,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1946,
        max_available_year: 2024,
        import_priority: 90,
        reliability_score: 0.85,
        metadata: %{
          "festival" => "Cannes Film Festival",
          "category_mappings" => %{
            "palme_dor" => "palme_dor",
            "grand_prix" => "grand_prix",
            "prix_du_jury" => "jury_prize",
            "prix_de_la_mise_en_scene" => "best_director"
          },
          "default_category" => "cannes_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Cannes events configuration")

  _ ->
    Logger.info("  ⏭️  Cannes events already exists")
end

# Venice International Film Festival - IMDb source
case Events.get_by_source_key("venice") do
  nil ->
    {:ok, _venice_event} =
      Events.create_festival_event(%{
        source_key: "venice",
        name: "Venice International Film Festival",
        abbreviation: "VIFF",
        country: "Italy",
        founded_year: 1932,
        website: "https://www.labiennale.org/en/cinema",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000681",
          "imdb_event_id" => "ev0000681",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{
            "source" => "official",
            "url" => "https://www.labiennale.org/en/cinema/archive/{year}"
          }
        ],
        typical_start_month: 8,
        typical_start_day: 28,
        typical_duration_days: 11,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: true,
        min_available_year: 1932,
        max_available_year: 2024,
        import_priority: 85,
        reliability_score: 0.90,
        metadata: %{
          "festival" => "Venice International Film Festival",
          "category_mappings" => %{
            "golden_lion" => "golden_lion",
            "silver_lion" => "silver_lion"
          },
          "default_category" => "venice_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Venice events configuration")

  _ ->
    Logger.info("  ⏭️  Venice events already exists")
end

# Berlin International Film Festival - IMDb source
case Events.get_by_source_key("berlin") do
  nil ->
    {:ok, _berlin_event} =
      Events.create_festival_event(%{
        source_key: "berlin",
        name: "Berlin International Film Festival",
        abbreviation: "BIFF",
        country: "Germany",
        founded_year: 1951,
        website: "https://www.berlinale.de",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000091",
          "imdb_event_id" => "ev0000091",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.berlinale.de/en/archive/{year}/"}
        ],
        typical_start_month: 2,
        typical_start_day: 13,
        typical_duration_days: 11,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1951,
        max_available_year: 2024,
        import_priority: 85,
        reliability_score: 0.90,
        metadata: %{
          "festival" => "Berlin International Film Festival",
          "category_mappings" => %{
            "golden_bear" => "golden_bear",
            "silver_bear" => "silver_bear",
            "alfred_bauer_prize" => "alfred_bauer_prize"
          },
          "default_category" => "berlin_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Berlin events configuration")

  _ ->
    Logger.info("  ⏭️  Berlin events already exists")
end

# New Horizons International Film Festival - IMDb source
case Events.get_by_source_key("new_horizons") do
  nil ->
    {:ok, _new_horizons_event} =
      Events.create_festival_event(%{
        source_key: "new_horizons",
        name: "New Horizons International Film Festival",
        abbreviation: "NHIFF",
        country: "Poland",
        founded_year: 2001,
        website: "https://www.nowehoryzonty.pl/?lang=en",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0002561",
          "imdb_event_id" => "ev0002561",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.nowehoryzonty.pl/?lang=en"}
        ],
        typical_start_month: 7,
        typical_start_day: 17,
        typical_duration_days: 11,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 2001,
        max_available_year: 2024,
        import_priority: 75,
        reliability_score: 0.80,
        metadata: %{
          "festival" => "New Horizons International Film Festival",
          "location" => "Wrocław, Poland",
          "specialization" => "arthouse cinema",
          "category_mappings" => %{
            "grand_prix" => "grand_prix",
            "audience_award" => "audience_award"
          },
          "default_category" => "new_horizons_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created New Horizons events configuration")

  _ ->
    Logger.info("  ⏭️  New Horizons events already exists")
end

# Sundance Film Festival - IMDb source
case Events.get_by_source_key("sundance") do
  nil ->
    {:ok, _sundance_event} =
      Events.create_festival_event(%{
        source_key: "sundance",
        name: "Sundance Film Festival",
        abbreviation: "SFF",
        country: "USA",
        founded_year: 1978,
        website: "https://www.sundance.org",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000631",
          "imdb_event_id" => "ev0000631",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.sundance.org"}
        ],
        typical_start_month: 1,
        typical_start_day: 18,
        typical_duration_days: 10,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1978,
        max_available_year: 2024,
        import_priority: 90,
        reliability_score: 0.95,
        metadata: %{
          "festival" => "Sundance Film Festival",
          "location" => "Park City, Utah (through 2026), Boulder, Colorado (2027+)",
          "specialization" => "independent film",
          "category_mappings" => %{
            "grand_jury_prize" => "grand_jury_prize",
            "audience_award" => "audience_award",
            "directing_award" => "directing_award"
          },
          "default_category" => "sundance_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Sundance events configuration")

  _ ->
    Logger.info("  ⏭️  Sundance events already exists")
end

# SXSW Film Festival - IMDb source
case Events.get_by_source_key("sxsw") do
  nil ->
    {:ok, _sxsw_event} =
      Events.create_festival_event(%{
        source_key: "sxsw",
        name: "SXSW Film Festival",
        abbreviation: "SXSW",
        country: "USA",
        founded_year: 1987,
        website: "https://www.sxsw.com/festivals/film/",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000636",
          "imdb_event_id" => "ev0000636",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.sxsw.com/festivals/film/"}
        ],
        typical_start_month: 3,
        typical_start_day: 8,
        typical_duration_days: 9,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1987,
        max_available_year: 2024,
        import_priority: 85,
        reliability_score: 0.88,
        metadata: %{
          "festival" => "SXSW Film Festival",
          "location" => "Austin, Texas",
          "specialization" => "emerging talent and innovation",
          "category_mappings" => %{
            "adobe_editing_award" => "adobe_editing_award",
            "audience_award" => "audience_award",
            "audience_award_midnighters" => "audience_award_midnighters"
          },
          "default_category" => "sxsw_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created SXSW events configuration")

  _ ->
    Logger.info("  ⏭️  SXSW events already exists")
end

# Golden Globe Awards - IMDb source
case Events.get_by_source_key("golden_globes") do
  nil ->
    {:ok, _golden_globes_event} =
      Events.create_festival_event(%{
        source_key: "golden_globes",
        name: "Golden Globe Awards",
        abbreviation: "HFPA",
        country: "USA",
        founded_year: 1944,
        website: "https://www.goldenglobes.com",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000292",
          "imdb_event_id" => "ev0000292",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.goldenglobes.com"}
        ],
        typical_start_month: 1,
        typical_start_day: 5,
        typical_duration_days: 1,
        ceremony_vs_festival: "ceremony",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1944,
        max_available_year: 2025,
        import_priority: 95,
        reliability_score: 0.90,
        metadata: %{
          "organization" => "Hollywood Foreign Press Association",
          "category_mappings" => %{
            "best_motion_picture_drama" => "best_picture_drama",
            "best_motion_picture_musical_or_comedy" => "best_picture_comedy",
            "best_director" => "best_director",
            "best_actor_drama" => "best_actor_drama",
            "best_actress_drama" => "best_actress_drama"
          },
          "default_category" => "golden_globe_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Golden Globes events configuration")

  _ ->
    Logger.info("  ⏭️  Golden Globes events already exists")
end

# BAFTA Film Awards - IMDb source
case Events.get_by_source_key("bafta") do
  nil ->
    {:ok, _bafta_event} =
      Events.create_festival_event(%{
        source_key: "bafta",
        name: "BAFTA Film Awards",
        abbreviation: "BAFTA",
        country: "UK",
        founded_year: 1949,
        website: "https://www.bafta.org",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000123",
          "imdb_event_id" => "ev0000123",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.bafta.org/film/awards"}
        ],
        typical_start_month: 2,
        typical_start_day: 16,
        typical_duration_days: 1,
        ceremony_vs_festival: "ceremony",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1949,
        max_available_year: 2025,
        import_priority: 95,
        reliability_score: 0.90,
        metadata: %{
          "organization" => "British Academy of Film and Television Arts",
          "category_mappings" => %{
            "best_film" => "best_film",
            "best_director" => "best_director",
            "best_leading_actor" => "best_actor",
            "best_leading_actress" => "best_actress"
          },
          "default_category" => "bafta_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created BAFTA events configuration")

  _ ->
    Logger.info("  ⏭️  BAFTA events already exists")
end

# SAG Awards - IMDb source
case Events.get_by_source_key("sag") do
  nil ->
    {:ok, _sag_event} =
      Events.create_festival_event(%{
        source_key: "sag",
        name: "Screen Actors Guild Awards",
        abbreviation: "SAG",
        country: "USA",
        founded_year: 1995,
        website: "https://www.sagawards.org",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000598",
          "imdb_event_id" => "ev0000598",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.sagawards.org"}
        ],
        typical_start_month: 2,
        typical_start_day: 23,
        typical_duration_days: 1,
        ceremony_vs_festival: "ceremony",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1995,
        max_available_year: 2025,
        import_priority: 90,
        reliability_score: 0.90,
        metadata: %{
          "organization" =>
            "Screen Actors Guild - American Federation of Television and Radio Artists",
          "category_mappings" => %{
            "outstanding_cast" => "outstanding_cast",
            "outstanding_male_actor_leading" => "best_actor",
            "outstanding_female_actor_leading" => "best_actress"
          },
          "default_category" => "sag_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created SAG Awards events configuration")

  _ ->
    Logger.info("  ⏭️  SAG Awards events already exists")
end

# Critics Choice Awards - IMDb source
case Events.get_by_source_key("critics_choice") do
  nil ->
    {:ok, _critics_choice_event} =
      Events.create_festival_event(%{
        source_key: "critics_choice",
        name: "Critics Choice Awards",
        abbreviation: "CCA",
        country: "USA",
        founded_year: 1996,
        website: "https://www.criticschoice.com",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000133",
          "imdb_event_id" => "ev0000133",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.criticschoice.com"}
        ],
        typical_start_month: 1,
        typical_start_day: 12,
        typical_duration_days: 1,
        ceremony_vs_festival: "ceremony",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1996,
        max_available_year: 2025,
        import_priority: 85,
        reliability_score: 0.85,
        metadata: %{
          "organization" => "Critics Choice Association",
          "category_mappings" => %{
            "best_picture" => "best_picture",
            "best_director" => "best_director",
            "best_actor" => "best_actor",
            "best_actress" => "best_actress"
          },
          "default_category" => "critics_choice_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Critics Choice Awards events configuration")

  _ ->
    Logger.info("  ⏭️  Critics Choice Awards events already exists")
end

# Toronto International Film Festival (TIFF) - IMDb source
case Events.get_by_source_key("toronto") do
  nil ->
    {:ok, _toronto_event} =
      Events.create_festival_event(%{
        source_key: "toronto",
        name: "Toronto International Film Festival",
        abbreviation: "TIFF",
        country: "Canada",
        founded_year: 1976,
        website: "https://www.tiff.net",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000659",
          "imdb_event_id" => "ev0000659",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.tiff.net"}
        ],
        typical_start_month: 9,
        typical_start_day: 5,
        typical_duration_days: 11,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1976,
        max_available_year: 2025,
        import_priority: 90,
        reliability_score: 0.90,
        metadata: %{
          "festival" => "Toronto International Film Festival",
          "location" => "Toronto, Ontario, Canada",
          "specialization" => "premiere platform, Oscar bellwether",
          "category_mappings" => %{
            "peoples_choice_award" => "peoples_choice",
            "platform_prize" => "platform_prize"
          },
          "default_category" => "tiff_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created TIFF events configuration")

  _ ->
    Logger.info("  ⏭️  TIFF events already exists")
end

# Telluride Film Festival - IMDb source
case Events.get_by_source_key("telluride") do
  nil ->
    {:ok, _telluride_event} =
      Events.create_festival_event(%{
        source_key: "telluride",
        name: "Telluride Film Festival",
        abbreviation: "TFF",
        country: "USA",
        founded_year: 1974,
        website: "https://www.telluridefilmfestival.org",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000645",
          "imdb_event_id" => "ev0000645",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.telluridefilmfestival.org"}
        ],
        typical_start_month: 8,
        typical_start_day: 30,
        typical_duration_days: 4,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1974,
        max_available_year: 2025,
        import_priority: 80,
        reliability_score: 0.85,
        metadata: %{
          "festival" => "Telluride Film Festival",
          "location" => "Telluride, Colorado",
          "specialization" => "curated premieres, no advance program announcement",
          "category_mappings" => %{
            "silver_medallion" => "silver_medallion"
          },
          "default_category" => "telluride_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Telluride events configuration")

  _ ->
    Logger.info("  ⏭️  Telluride events already exists")
end

# New York Film Festival - IMDb source
case Events.get_by_source_key("nyff") do
  nil ->
    {:ok, _nyff_event} =
      Events.create_festival_event(%{
        source_key: "nyff",
        name: "New York Film Festival",
        abbreviation: "NYFF",
        country: "USA",
        founded_year: 1963,
        website: "https://www.filmlinc.org/nyff",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000484",
          "imdb_event_id" => "ev0000484",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.filmlinc.org/nyff"}
        ],
        typical_start_month: 9,
        typical_start_day: 27,
        typical_duration_days: 17,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1963,
        max_available_year: 2025,
        import_priority: 80,
        reliability_score: 0.85,
        metadata: %{
          "festival" => "New York Film Festival",
          "location" => "New York City, New York",
          "organization" => "Film at Lincoln Center",
          "specialization" => "curated selection, no competitive awards",
          "default_category" => "nyff_selection",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created NYFF events configuration")

  _ ->
    Logger.info("  ⏭️  NYFF events already exists")
end

# Locarno Film Festival - IMDb source
case Events.get_by_source_key("locarno") do
  nil ->
    {:ok, _locarno_event} =
      Events.create_festival_event(%{
        source_key: "locarno",
        name: "Locarno Film Festival",
        abbreviation: "LFF",
        country: "Switzerland",
        founded_year: 1946,
        website: "https://www.locarnofestival.ch",
        primary_source: "imdb",
        source_config: %{
          "event_id" => "ev0000400",
          "imdb_event_id" => "ev0000400",
          "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
          "parser_type" => "next_data_json"
        },
        fallback_sources: [
          %{"source" => "official", "url" => "https://www.locarnofestival.ch"}
        ],
        typical_start_month: 8,
        typical_start_day: 7,
        typical_duration_days: 10,
        ceremony_vs_festival: "festival",
        tracks_nominations: true,
        tracks_winners_only: false,
        min_available_year: 1946,
        max_available_year: 2025,
        import_priority: 75,
        reliability_score: 0.85,
        metadata: %{
          "festival" => "Locarno Film Festival",
          "location" => "Locarno, Switzerland",
          "specialization" => "arthouse and independent cinema",
          "category_mappings" => %{
            "golden_leopard" => "golden_leopard",
            "special_jury_prize" => "special_jury_prize",
            "best_director" => "best_director"
          },
          "default_category" => "locarno_award",
          "parser_hints" => %{
            "expected_format" => "key_value_awards",
            "category_path" => "awards"
          }
        }
      })

    Logger.info("  ✅ Created Locarno events configuration")

  _ ->
    Logger.info("  ⏭️  Locarno events already exists")
end

# Add some festival dates for 2024 (completed) and 2025 (upcoming where known)
Logger.info("Seeding festival dates for 2024/2025...")

# Helper function to create festival dates
create_festival_dates = fn ->
  # Get events
  oscar_event = Events.get_by_source_key("oscars")
  cannes_event = Events.get_by_source_key("cannes")
  venice_event = Events.get_by_source_key("venice")
  berlin_event = Events.get_by_source_key("berlin")
  new_horizons_event = Events.get_by_source_key("new_horizons")
  sundance_event = Events.get_by_source_key("sundance")
  sxsw_event = Events.get_by_source_key("sxsw")
  golden_globes_event = Events.get_by_source_key("golden_globes")
  bafta_event = Events.get_by_source_key("bafta")
  sag_event = Events.get_by_source_key("sag")
  critics_choice_event = Events.get_by_source_key("critics_choice")
  toronto_event = Events.get_by_source_key("toronto")
  telluride_event = Events.get_by_source_key("telluride")
  nyff_event = Events.get_by_source_key("nyff")
  locarno_event = Events.get_by_source_key("locarno")

  # 2024 dates (completed)
  if oscar_event do
    Events.upsert_festival_date(%{
      festival_event_id: oscar_event.id,
      year: 2024,
      start_date: ~D[2024-03-10],
      end_date: ~D[2024-03-10],
      status: "completed",
      source: "official"
    })
  end

  if cannes_event do
    Events.upsert_festival_date(%{
      festival_event_id: cannes_event.id,
      year: 2024,
      start_date: ~D[2024-05-14],
      end_date: ~D[2024-05-25],
      status: "completed",
      source: "official"
    })
  end

  if venice_event do
    Events.upsert_festival_date(%{
      festival_event_id: venice_event.id,
      year: 2024,
      start_date: ~D[2024-08-28],
      end_date: ~D[2024-09-07],
      status: "completed",
      source: "official"
    })
  end

  if berlin_event do
    Events.upsert_festival_date(%{
      festival_event_id: berlin_event.id,
      year: 2024,
      start_date: ~D[2024-02-15],
      end_date: ~D[2024-02-25],
      status: "completed",
      source: "official"
    })
  end

  if new_horizons_event do
    Events.upsert_festival_date(%{
      festival_event_id: new_horizons_event.id,
      year: 2024,
      start_date: ~D[2024-07-17],
      end_date: ~D[2024-07-27],
      status: "completed",
      source: "official"
    })
  end

  if sundance_event do
    Events.upsert_festival_date(%{
      festival_event_id: sundance_event.id,
      year: 2024,
      start_date: ~D[2024-01-18],
      end_date: ~D[2024-01-28],
      status: "completed",
      source: "official"
    })
  end

  if sxsw_event do
    Events.upsert_festival_date(%{
      festival_event_id: sxsw_event.id,
      year: 2024,
      start_date: ~D[2024-03-08],
      end_date: ~D[2024-03-16],
      status: "completed",
      source: "official"
    })
  end

  if golden_globes_event do
    Events.upsert_festival_date(%{
      festival_event_id: golden_globes_event.id,
      year: 2024,
      start_date: ~D[2024-01-07],
      end_date: ~D[2024-01-07],
      status: "completed",
      source: "official"
    })
  end

  if bafta_event do
    Events.upsert_festival_date(%{
      festival_event_id: bafta_event.id,
      year: 2024,
      start_date: ~D[2024-02-18],
      end_date: ~D[2024-02-18],
      status: "completed",
      source: "official"
    })
  end

  if sag_event do
    Events.upsert_festival_date(%{
      festival_event_id: sag_event.id,
      year: 2024,
      start_date: ~D[2024-02-24],
      end_date: ~D[2024-02-24],
      status: "completed",
      source: "official"
    })
  end

  if critics_choice_event do
    Events.upsert_festival_date(%{
      festival_event_id: critics_choice_event.id,
      year: 2024,
      start_date: ~D[2024-01-14],
      end_date: ~D[2024-01-14],
      status: "completed",
      source: "official"
    })
  end

  if toronto_event do
    Events.upsert_festival_date(%{
      festival_event_id: toronto_event.id,
      year: 2024,
      start_date: ~D[2024-09-05],
      end_date: ~D[2024-09-15],
      status: "completed",
      source: "official"
    })
  end

  if telluride_event do
    Events.upsert_festival_date(%{
      festival_event_id: telluride_event.id,
      year: 2024,
      start_date: ~D[2024-08-30],
      end_date: ~D[2024-09-02],
      status: "completed",
      source: "official"
    })
  end

  if nyff_event do
    Events.upsert_festival_date(%{
      festival_event_id: nyff_event.id,
      year: 2024,
      start_date: ~D[2024-09-27],
      end_date: ~D[2024-10-13],
      status: "completed",
      source: "official"
    })
  end

  if locarno_event do
    Events.upsert_festival_date(%{
      festival_event_id: locarno_event.id,
      year: 2024,
      start_date: ~D[2024-08-07],
      end_date: ~D[2024-08-17],
      status: "completed",
      source: "official"
    })
  end

  # 2025 dates (upcoming where known)
  if oscar_event do
    Events.upsert_festival_date(%{
      festival_event_id: oscar_event.id,
      year: 2025,
      start_date: ~D[2025-03-02],
      end_date: ~D[2025-03-02],
      status: "upcoming",
      source: "estimated"
    })
  end

  if berlin_event do
    Events.upsert_festival_date(%{
      festival_event_id: berlin_event.id,
      year: 2025,
      start_date: ~D[2025-02-13],
      end_date: ~D[2025-02-23],
      status: "upcoming",
      source: "official"
    })
  end

  if cannes_event do
    Events.upsert_festival_date(%{
      festival_event_id: cannes_event.id,
      year: 2025,
      start_date: ~D[2025-05-13],
      end_date: ~D[2025-05-24],
      status: "upcoming",
      source: "estimated"
    })
  end

  if venice_event do
    Events.upsert_festival_date(%{
      festival_event_id: venice_event.id,
      year: 2025,
      start_date: ~D[2025-08-27],
      end_date: ~D[2025-09-06],
      status: "upcoming",
      source: "estimated"
    })
  end

  if new_horizons_event do
    Events.upsert_festival_date(%{
      festival_event_id: new_horizons_event.id,
      year: 2025,
      start_date: ~D[2025-07-17],
      end_date: ~D[2025-07-27],
      status: "upcoming",
      source: "estimated"
    })
  end

  if sundance_event do
    Events.upsert_festival_date(%{
      festival_event_id: sundance_event.id,
      year: 2025,
      start_date: ~D[2025-01-23],
      end_date: ~D[2025-02-02],
      status: "upcoming",
      source: "official"
    })
  end

  if sxsw_event do
    Events.upsert_festival_date(%{
      festival_event_id: sxsw_event.id,
      year: 2025,
      start_date: ~D[2025-03-07],
      end_date: ~D[2025-03-15],
      status: "upcoming",
      source: "official"
    })
  end

  if golden_globes_event do
    Events.upsert_festival_date(%{
      festival_event_id: golden_globes_event.id,
      year: 2025,
      start_date: ~D[2025-01-05],
      end_date: ~D[2025-01-05],
      status: "completed",
      source: "official"
    })
  end

  if bafta_event do
    Events.upsert_festival_date(%{
      festival_event_id: bafta_event.id,
      year: 2025,
      start_date: ~D[2025-02-16],
      end_date: ~D[2025-02-16],
      status: "completed",
      source: "official"
    })
  end

  if sag_event do
    Events.upsert_festival_date(%{
      festival_event_id: sag_event.id,
      year: 2025,
      start_date: ~D[2025-02-23],
      end_date: ~D[2025-02-23],
      status: "completed",
      source: "official"
    })
  end

  if critics_choice_event do
    Events.upsert_festival_date(%{
      festival_event_id: critics_choice_event.id,
      year: 2025,
      start_date: ~D[2025-01-12],
      end_date: ~D[2025-01-12],
      status: "completed",
      source: "official"
    })
  end

  if toronto_event do
    Events.upsert_festival_date(%{
      festival_event_id: toronto_event.id,
      year: 2025,
      start_date: ~D[2025-09-04],
      end_date: ~D[2025-09-14],
      status: "upcoming",
      source: "estimated"
    })
  end

  if telluride_event do
    Events.upsert_festival_date(%{
      festival_event_id: telluride_event.id,
      year: 2025,
      start_date: ~D[2025-08-29],
      end_date: ~D[2025-09-01],
      status: "upcoming",
      source: "estimated"
    })
  end

  if nyff_event do
    Events.upsert_festival_date(%{
      festival_event_id: nyff_event.id,
      year: 2025,
      start_date: ~D[2025-09-26],
      end_date: ~D[2025-10-12],
      status: "upcoming",
      source: "estimated"
    })
  end

  if locarno_event do
    Events.upsert_festival_date(%{
      festival_event_id: locarno_event.id,
      year: 2025,
      start_date: ~D[2025-08-06],
      end_date: ~D[2025-08-16],
      status: "upcoming",
      source: "estimated"
    })
  end
end

create_festival_dates.()
Logger.info("  ✅ Created festival dates for 2024/2025")

# Seed metric definitions and weight profiles for discovery system
Logger.info("Seeding metric definitions...")

try do
  Code.eval_file(Application.app_dir(:cinegraph, "priv/repo/seeds/metric_definitions.exs"))
rescue
  e ->
    Logger.error("Failed seeding metric definitions: #{Exception.message(e)}")
    reraise e, __STACKTRACE__
end

Logger.info("Seeding discovery weight profiles...")

try do
  Code.eval_file(Application.app_dir(:cinegraph, "priv/repo/seeds/metric_weight_profiles.exs"))
rescue
  e ->
    Logger.error("Failed seeding metric weight profiles: #{Exception.message(e)}")
    reraise e, __STACKTRACE__
end

Logger.info("Seeding calibration system...")

try do
  Code.eval_file(Application.app_dir(:cinegraph, "priv/repo/seeds/calibration_seeds.exs"))
rescue
  e ->
    Logger.error("Failed seeding calibration system: #{Exception.message(e)}")
    reraise e, __STACKTRACE__
end

Logger.info("Seeds completed!")
