#!/usr/bin/env mix
# One-shot seed (#880 Phase 2 PR-A) — populate `logo_url` and `hero_image_url`
# on existing festival_organizations rows so the home page "Pick a festival"
# shelf stops rendering blank cards.
#
# Idempotent: only writes a field if the current value is `nil` or `""`. Re-run
# is a no-op for already-populated orgs.
#
# Source URLs are Wikimedia Commons / Wikipedia stable redirects. Any URL that
# 404s or feels off can be replaced via the upcoming /admin/festivals editor
# (#880 Phase 2 PR-C).
#
#   mix run priv/repo/seeds/festival_organization_images.exs

require Logger

alias Cinegraph.Festivals

# Match on canonical name substrings — slugs in this DB are out of sync with
# names for a few rows (e.g., the "cannes" slug actually points at "Berlin
# International Film Festival"), so name matching is more reliable.
seeds = [
  %{
    match: "Academy of Motion Picture",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/5/56/Oscars_logo.svg/512px-Oscars_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Dolby_Theatre_at_Night.jpg/1280px-Dolby_Theatre_at_Night.jpg"
  },
  %{
    match: "BAFTA",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/en/thumb/4/45/BAFTA_logo.svg/512px-BAFTA_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/9/93/Royal_Albert_Hall_-_Central_View_-_London_-_2012.jpg/1280px-Royal_Albert_Hall_-_Central_View_-_London_-_2012.jpg"
  },
  %{
    match: "Berlin International",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a8/Berlinale_Bears_Logo.svg/512px-Berlinale_Bears_Logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/5/57/Berlinale_Palast_2013.jpg/1280px-Berlinale_Palast_2013.jpg"
  },
  %{
    match: "Cannes",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/en/thumb/0/0a/Cannes_film_festival_logo.svg/512px-Cannes_film_festival_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/9/9c/Palais_des_Festivals_in_Cannes.jpg/1280px-Palais_des_Festivals_in_Cannes.jpg"
  },
  %{
    match: "Critics Choice",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/en/thumb/9/95/Critics%27_Choice_Movie_Awards_logo.png/512px-Critics%27_Choice_Movie_Awards_logo.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Barker_Hangar.jpg/1280px-Barker_Hangar.jpg"
  },
  %{
    match: "Golden Globe",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/9/93/Golden_Globe_Award_Trophy.png/256px-Golden_Globe_Award_Trophy.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/6/61/The_Beverly_Hilton_Hotel.jpg/1280px-The_Beverly_Hilton_Hotel.jpg"
  },
  %{
    match: "Locarno",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Locarno_Festival_Logo.svg/512px-Locarno_Festival_Logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5d/Locarno_Piazza_Grande.jpg/1280px-Locarno_Piazza_Grande.jpg"
  },
  %{
    match: "New Horizons",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/T-Mobile_Nowe_Horyzonty_logo.svg/512px-T-Mobile_Nowe_Horyzonty_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Wroc%C5%82aw_Rynek_Panorama.jpg/1280px-Wroc%C5%82aw_Rynek_Panorama.jpg"
  },
  %{
    match: "New York Film",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5e/New_York_Film_Festival_Logo.png/512px-New_York_Film_Festival_Logo.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/7/72/Lincoln_Center_Twilight.jpg/1280px-Lincoln_Center_Twilight.jpg"
  },
  %{
    match: "Screen Actors Guild",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/2/22/Screen_Actors_Guild_Awards_logo.svg/512px-Screen_Actors_Guild_Awards_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/3/35/Shrine_Auditorium.jpg/1280px-Shrine_Auditorium.jpg"
  },
  %{
    match: "Sundance Film",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a7/Sundance_Film_Festival_logo.svg/512px-Sundance_Film_Festival_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Park_City_Main_Street_Sundance.jpg/1280px-Park_City_Main_Street_Sundance.jpg"
  },
  %{
    match: "SXSW",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/South_by_Southwest_logo.svg/512px-South_by_Southwest_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4a/Austin_skyline_2014.jpg/1280px-Austin_skyline_2014.jpg"
  },
  %{
    match: "Telluride",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/Telluride_Film_Festival_Logo.png/512px-Telluride_Film_Festival_Logo.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4f/Telluride%2C_Colorado.jpg/1280px-Telluride%2C_Colorado.jpg"
  },
  %{
    match: "Toronto International",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/7/77/Toronto_International_Film_Festival_logo.svg/512px-Toronto_International_Film_Festival_logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/3/30/TIFF_Bell_Lightbox_Building.jpg/1280px-TIFF_Bell_Lightbox_Building.jpg"
  },
  %{
    match: "Venice",
    logo_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/d/df/Venice_Film_Festival_Logo.svg/512px-Venice_Film_Festival_Logo.svg.png",
    hero_image_url:
      "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/Lido_di_Venezia.jpg/1280px-Lido_di_Venezia.jpg"
  }
]

orgs = Festivals.list_organizations()

# Helper: only put a field into attrs when the org's current value is empty.
maybe_put = fn attrs, key, new_value, current_value ->
  if is_nil(current_value) or current_value == "" do
    Map.put(attrs, key, new_value)
  else
    attrs
  end
end

results =
  Enum.map(seeds, fn %{match: needle} = seed ->
    case Enum.find(orgs, &String.contains?(&1.name, needle)) do
      nil ->
        Logger.warning("Seed: no org matched '#{needle}'")
        {:miss, needle}

      org ->
        attrs =
          %{}
          |> maybe_put.(:logo_url, seed.logo_url, org.logo_url)
          |> maybe_put.(:hero_image_url, seed.hero_image_url, org.hero_image_url)

        cond do
          map_size(attrs) == 0 ->
            Logger.info("Seed: '#{org.name}' already has imagery, skipping")
            {:skip, org.name}

          true ->
            case Festivals.update_organization(org, attrs) do
              {:ok, _} ->
                Logger.info(
                  "Seed: '#{org.name}' updated (#{Map.keys(attrs) |> Enum.join(", ")})"
                )

                {:ok, org.name}

              {:error, changeset} ->
                Logger.error("Seed: '#{org.name}' failed — #{inspect(changeset.errors)}")
                {:error, org.name}
            end
        end
    end
  end)

ok = Enum.count(results, &match?({:ok, _}, &1))
skip = Enum.count(results, &match?({:skip, _}, &1))
miss = Enum.count(results, &match?({:miss, _}, &1))
err = Enum.count(results, &match?({:error, _}, &1))

IO.puts(
  "\nSeed complete: #{ok} updated, #{skip} skipped (already populated), #{miss} unmatched, #{err} errors\n"
)

if err > 0, do: System.halt(1)
