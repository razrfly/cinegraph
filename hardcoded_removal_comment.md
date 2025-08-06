## Eliminate Festival-Specific Hardcoded Logic

Critical requirement: **Remove ALL festival-specific hardcoded logic** to achieve true scalability and robustness.

### Current Hardcoded Dependencies 🚨

#### 1. **Festival Event Mappings** (`unified_festival_scraper.ex:13-46`)
```elixir
# ❌ HARDCODED: Adding Toronto requires code deployment
@event_mappings %{
  "cannes" => %{event_id: "ev0000147", abbreviation: "CFF"},
  "bafta" => %{event_id: "ev0000123", abbreviation: "BAFTA"},
  # ... more hardcoded configs
}
```

#### 2. **Festival-Specific Parsing Logic** (`festival_discovery_worker.ex:150+`)
```elixir
# ❌ HARDCODED: Oscar vs Venice format detection
cond do
  # Oscar format: data["categories"] with nominees inside (and not empty)
  length(oscar_categories) > 0 ->
    {oscar_categories, :oscar_format}
    
  # Venice/Festival format: data["awards"] with categories as keys (and not empty)
  map_size(awards) > 0 ->
    # Venice-specific parsing...
```

#### 3. **Category Name Mappings** (`unified_festival_scraper.ex:329-362`)
```elixir
# ❌ HARDCODED: Festival-specific category transformations
defp apply_festival_mappings(name, %{abbreviation: "CFF"}) do
  # Cannes-specific mappings
  case name do
    "palme_dor" -> "palme_dor"
    "prix_du_jury" -> "jury_prize"
    # ... 
  end
end

defp apply_festival_mappings(name, %{abbreviation: "BIFF"}) do
  # Berlin-specific mappings...
end
```

#### 4. **Default Category Generation** (`unified_festival_scraper.ex:384-388`)
```elixir
# ❌ HARDCODED: Festival abbreviation → category mapping
defp get_default_category(%{abbreviation: "CFF"}), do: "cannes_award"
defp get_default_category(%{abbreviation: "BIFF"}), do: "berlin_award"
defp get_default_category(%{abbreviation: "BAFTA"}), do: "bafta_award"
defp get_default_category(%{abbreviation: "VIFF"}), do: "venice_award"
```

### Problems with Hardcoded Logic

1. **Deployment Friction**: Adding Sundance Film Festival requires:
   - Code modification in multiple files
   - Testing festival-specific parsing logic  
   - Deployment coordination
   - Potential production bugs

2. **Format Assumption Brittleness**: 
   - "Oscar format" vs "Venice format" assumptions break when festivals change HTML structure
   - New festivals may not fit existing format patterns

3. **Category Mapping Maintenance**:
   - Each festival needs custom category name transformations
   - Manual maintenance for international festival names
   - No consistent approach for handling new category types

### Database-Driven Solution ✅

#### Replace `@event_mappings` with Database
```elixir
# ✅ DYNAMIC: Query from database instead of module attribute
def get_festival_config(festival_key) do
  case Cinegraph.Events.get_active_by_source_key(festival_key) do
    nil -> {:error, "Festival not configured: #{festival_key}"}
    event -> {:ok, convert_to_scraper_config(event)}
  end
end
```

#### Generic Format Detection
```elixir
# ✅ GENERIC: Pattern-based detection without festival names
defp detect_data_format(data) do
  cond do
    # GraphQL/JSON API format (IMDb __NEXT_DATA__)
    has_nested_path?(data, ["props", "pageProps", "edition", "awards"]) ->
      {:graphql_api, get_in(data, ["props", "pageProps", "edition", "awards"])}
      
    # Structured categories format (Oscars, BAFTA)
    is_list(data["categories"]) and length(data["categories"]) > 0 ->
      {:structured_categories, data["categories"]}
      
    # Key-value awards format (festivals)
    is_map(data["awards"]) and map_size(data["awards"]) > 0 ->
      {:key_value_awards, data["awards"]}
      
    # Legacy HTML parsing fallback
    true ->
      {:html_fallback, %{}}
  end
end
```

#### Configurable Category Mappings
```elixir
# ✅ DATABASE-DRIVEN: Store mappings in festival_events.metadata
%{
  source_key: "cannes",
  metadata: %{
    "category_mappings" => %{
      "palme_dor" => "palme_dor",
      "prix_du_jury" => "jury_prize",
      "prix_de_la_mise_en_scene" => "best_director"
    },
    "default_category" => "cannes_award",
    "parser_hints" => %{
      "expected_format" => "key_value_awards",
      "category_path" => "awards",
      "nomination_structure" => "flat"
    }
  }
}
```

#### Universal Parsing Pipeline
```elixir
# ✅ CONFIGURABLE: Use database metadata for parsing decisions
defmodule Cinegraph.Scrapers.UniversalParser do
  def parse_event_data(raw_data, festival_event) do
    format = detect_data_format(raw_data)
    parser_hints = get_in(festival_event.metadata, ["parser_hints"]) || %{}
    category_mappings = get_in(festival_event.metadata, ["category_mappings"]) || %{}
    
    raw_data
    |> extract_categories(format, parser_hints)
    |> normalize_category_names(category_mappings)
    |> structure_nominations(festival_event)
  end
  
  # No festival-specific case statements!
  defp normalize_category_names(categories, mappings) do
    Enum.map(categories, fn {name, nominees} ->
      normalized_name = Map.get(mappings, name, normalize_generic(name))
      {normalized_name, nominees}
    end)
  end
end
```

### Migration Benefits

#### Before (Hardcoded) ❌
```elixir
# Adding Toronto Film Festival:
# 1. Modify @event_mappings in unified_festival_scraper.ex
# 2. Add apply_festival_mappings clause for "TIFF"  
# 3. Add get_default_category clause for "TIFF"
# 4. Test TIFF-specific parsing logic
# 5. Deploy to production
# 6. Monitor for TIFF-specific bugs
```

#### After (Database-Driven) ✅
```elixir
# Adding Toronto Film Festival:
# 1. Insert into festival_events table via UI/API
Cinegraph.Events.create_festival_event(%{
  source_key: "toronto",
  name: "Toronto International Film Festival",
  imdb_event_id: "ev0000456",
  metadata: %{
    "category_mappings" => %{"people_choice" => "peoples_choice"},
    "default_category" => "tiff_award"
  }
})
# 2. Test with generic parsing pipeline
# 3. No deployment needed!
```

### Implementation Checklist

- [ ] **Replace `@event_mappings`** → Database queries  
- [ ] **Remove `apply_festival_mappings/2`** → Configurable metadata
- [ ] **Replace `get_default_category/1`** → Database `default_category` field
- [ ] **Generic format detection** → Pattern-based instead of festival-name-based
- [ ] **Configurable parser hints** → Store parsing preferences in database
- [ ] **Universal category normalization** → Use database mappings instead of hardcoded case statements

### Success Criteria

🎯 **Zero Festival Names in Parser Code**: No "cannes", "oscar", "venice" strings in parsing logic
🎯 **Add-Festival-via-UI**: New festivals configurable through admin interface only  
🎯 **Format Flexibility**: Same parser handles Oscar JSON, Venice HTML, BAFTA API
🎯 **Category Universality**: Category mappings stored as data, not code

This eliminates **100% of festival-specific hardcoded logic**, making the system truly scalable for any award ceremony or festival worldwide! 🌍