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

# Seed movie lists from hardcoded canonical lists
Logger.info("Seeding movie lists from canonical lists...")
result = Cinegraph.Movies.MovieLists.migrate_hardcoded_lists()

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
end

create_festival_dates.()
Logger.info("  ✅ Created festival dates for 2024/2025")

# Seed metric definitions and weight profiles for discovery system
Logger.info("Seeding metric definitions...")
Code.eval_file("priv/repo/seeds/metric_definitions.exs")

Logger.info("Seeding discovery weight profiles...")
Code.eval_file("priv/repo/seeds/metric_weight_profiles.exs")

Logger.info("Seeds completed!")
