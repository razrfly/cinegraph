## Extension for Multi-Source Events (IMDb + Oscar.org + Future Sources)

Great point! The proposed schema should be **source-agnostic** to handle both IMDb events AND direct Oscar website scraping, plus future sources.

### Current Source Diversity
- **IMDb Events**: Cannes, Venice, Berlin (via `ev0000147` URLs)  
- **Oscar.org Direct**: Academy Awards (via `oscars.org/ceremonies/2024`)
- **Future Sources**: BAFTA.org, festival-cannes.com, berlinale.de, etc.

### Enhanced Schema Design

```elixir
defmodule Cinegraph.Events.FestivalEvent do
  schema "festival_events" do
    # Basic Info (source-agnostic)
    field :source_key, :string          # "cannes", "oscars", "bafta"
    field :name, :string                # "Academy Awards", "Cannes Film Festival"
    field :organization, :string        # "AMPAS", "Festival de Cannes"
    
    # Multi-Source Configuration
    field :primary_source, :string      # "imdb", "official", "custom"
    field :source_config, :map          # Source-specific configuration
    # Examples:
    # IMDb: %{"event_id" => "ev0000147", "url_template" => "https://imdb.com/event/{id}/{year}/1/"}
    # Oscar: %{"base_url" => "https://oscars.org", "path_template" => "/ceremonies/{year}"}
    # BAFTA: %{"api_endpoint" => "https://bafta.org/api/awards/{year}"}
    
    field :fallback_sources, {:array, :map}  # Alternative sources if primary fails
    
    # Date Management (universal)
    field :typical_start_month, :integer    # 3 (March for Oscars), 5 (May for Cannes)  
    field :typical_start_day, :integer      # 10 (Oscar ceremony), 14 (Cannes opening)
    field :ceremony_vs_festival, :string    # "ceremony" (single night) vs "festival" (multi-day)
    
    # Universal metadata
    field :tracks_nominations, :boolean     # True for Oscars/BAFTA, varies for festivals
    field :tracks_winners_only, :boolean    # Some sources only have winners
    field :categories_structure, :string    # "hierarchical", "flat", "custom"
    
    timestamps()
  end
end
```

### Source-Specific Examples

#### Oscar Awards (oscar.org)
```elixir
%{
  source_key: "oscars",
  name: "Academy Awards", 
  organization: "Academy of Motion Picture Arts and Sciences",
  primary_source: "official",
  source_config: %{
    "base_url" => "https://www.oscars.org",
    "ceremony_path_template" => "/ceremonies/{year}",
    "scraping_method" => "html_parser",
    "requires_selenium" => false
  },
  typical_start_month: 3,
  typical_start_day: 10,
  ceremony_vs_festival: "ceremony",
  tracks_nominations: true,
  tracks_winners_only: false
}
```

#### Cannes Festival (IMDb)
```elixir
%{
  source_key: "cannes",
  name: "Cannes Film Festival",
  organization: "Festival de Cannes", 
  primary_source: "imdb",
  source_config: %{
    "event_id" => "ev0000147",
    "url_template" => "https://www.imdb.com/event/{event_id}/{year}/1/",
    "parser_type" => "next_data_json"
  },
  fallback_sources: [
    %{"source" => "official", "url" => "https://www.festival-cannes.com/en/archives/{year}"}
  ],
  typical_start_month: 5,
  ceremony_vs_festival: "festival",
  tracks_nominations: true
}
```

### Universal Scraper Interface

```elixir
defmodule Cinegraph.Scrapers.UniversalEventScraper do
  def fetch_event_data(festival_event, year) do
    case festival_event.primary_source do
      "imdb" -> ImdbEventScraper.fetch(festival_event.source_config, year)
      "official" -> OfficialSiteScraper.fetch(festival_event.source_config, year)  
      "api" -> ApiEventScraper.fetch(festival_event.source_config, year)
      _ -> {:error, "Unknown source type"}
    end
  end
end

# Oscar-specific implementation  
defmodule Cinegraph.Scrapers.OfficialSiteScraper do
  def fetch(%{"base_url" => base_url, "ceremony_path_template" => path}, year) do
    url = base_url <> String.replace(path, "{year}", to_string(year))
    # Use existing Oscar scraping logic
    Cinegraph.Cultural.OscarScraper.scrape_ceremony_year(year)
  end
end
```

### Benefits of Multi-Source Design

1. **Oscar Integration**: Same date tracking, reliability scoring for Oscar imports
2. **Source Flexibility**: Easy to add BAFTA.org, festival-cannes.com when IMDb fails  
3. **Reliability Fallbacks**: If IMDb changes, automatically try official sites
4. **Universal Date Logic**: Same "should_import_event?" logic for all sources

### Migration Path

1. **Phase 1**: Migrate IMDb events to database with multi-source schema
2. **Phase 2**: Add Oscar events using existing Cultural.OscarScraper  
3. **Phase 3**: Add official website fallbacks for major festivals
4. **Phase 4**: Deprecate separate oscar_ceremonies table in favor of unified system

This makes the system truly **composable** for any award ceremony or festival, regardless of data source! 🎯