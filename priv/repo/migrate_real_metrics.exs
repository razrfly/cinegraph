# Script to migrate real data from external_metrics to our new metrics table
# Run with: mix run priv/repo/migrate_real_metrics.exs

alias Cinegraph.Repo
alias Cinegraph.Metrics.{CRI, Metric, MetricDefinition}
import Ecto.Query

IO.puts "\n========== MIGRATING REAL METRICS DATA ==========\n"

# Mapping from external_metrics to our metric codes
metric_mappings = %{
  {"imdb", "rating_average"} => "imdb_rating",
  {"imdb", "rating_votes"} => "imdb_vote_count",
  {"tmdb", "rating_average"} => "tmdb_rating",
  {"tmdb", "rating_votes"} => "tmdb_vote_count",
  {"tmdb", "popularity_score"} => "tmdb_popularity",
  {"tmdb", "budget"} => "tmdb_budget",
  {"tmdb", "revenue_worldwide"} => "tmdb_revenue",
  {"metacritic", "metascore"} => "metacritic_score",
  {"rotten_tomatoes", "tomatometer"} => "rt_tomatometer",
  {"omdb", "revenue_domestic"} => "omdb_box_office"
}

# Also check for canonical sources in movies table
canonical_mappings = %{
  "1001_movies" => "1001_movies",
  "afi_top_100" => "afi_top_100",
  "bfi_top_100" => "bfi_top_100",
  "sight_sound" => "sight_sound_rank",
  "criterion_collection" => "criterion_collection",
  "nfr_preserved" => "nfr_preserved"
}

# Get all metric definitions for validation
definitions = Repo.all(MetricDefinition) |> Map.new(&{&1.code, &1})

# Clear existing metrics to avoid duplicates
Repo.delete_all(Metric)
IO.puts "Cleared existing metrics"

# Process external_metrics table
{:ok, external_count} = Agent.start_link(fn -> 0 end)
external_metrics = Repo.all(
  from em in "external_metrics",
    select: %{
      movie_id: em.movie_id,
      source: em.source,
      metric_type: em.metric_type,
      value: em.value,
      fetched_at: em.fetched_at
    }
)

IO.puts "Processing #{length(external_metrics)} external metrics..."

Enum.each(external_metrics, fn em ->
  metric_code = Map.get(metric_mappings, {em.source, em.metric_type})
  
  if metric_code && Map.has_key?(definitions, metric_code) do
    _definition = definitions[metric_code]
    
    # Parse the value (it might be stored as string)
    raw_value = case em.value do
      v when is_number(v) -> v
      v when is_binary(v) ->
        case Float.parse(v) do
          {num, _} -> num
          :error -> 
            case Integer.parse(v) do
              {num, _} -> num
              :error -> nil
            end
        end
      _ -> nil
    end
    
    if raw_value do
      # Normalize the value
      normalized = CRI.normalize_value(metric_code, raw_value)
      
      # Convert datetime to UTC if needed
      observed_at = case em.fetched_at do
        nil -> DateTime.utc_now()
        %DateTime{} = dt -> dt
        %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
        _ -> DateTime.utc_now()
      end |> DateTime.truncate(:second)
      
      # Insert into metrics table
      %Metric{
        movie_id: em.movie_id,
        metric_code: metric_code,
        raw_value_numeric: raw_value,
        normalized_value: normalized,
        observed_at: observed_at
      }
      |> Repo.insert!(
        on_conflict: :replace_all,
        conflict_target: [:movie_id, :metric_code]
      )
      
      Agent.update(external_count, &(&1 + 1))
    end
  end
end)

final_external = Agent.get(external_count, & &1)
Agent.stop(external_count)
IO.puts "✓ Migrated #{final_external} metrics from external_metrics"

# Process canonical sources from movies table
{:ok, canonical_count} = Agent.start_link(fn -> 0 end)
movies_with_canonical = Repo.all(
  from m in "movies",
    where: not is_nil(m.canonical_sources),
    select: %{
      id: m.id,
      canonical_sources: m.canonical_sources
    }
)

IO.puts "Processing canonical sources from #{length(movies_with_canonical)} movies..."

Enum.each(movies_with_canonical, fn movie ->
  if movie.canonical_sources do
    Enum.each(canonical_mappings, fn {source_key, metric_code} ->
      if Map.has_key?(movie.canonical_sources, source_key) && Map.has_key?(definitions, metric_code) do
        _definition = definitions[metric_code]
        
        # Canonical sources are typically boolean or rank
        value = movie.canonical_sources[source_key]
        {raw_value, raw_text} = case value do
          true -> {nil, "true"}
          false -> {nil, "false"}
          v when is_number(v) -> {v, nil}  # For rankings
          _ -> {nil, nil}
        end
        
        if raw_value || raw_text do
          # Normalize based on type
          normalized = if raw_value do
            CRI.normalize_value(metric_code, raw_value)
          else
            CRI.normalize_value(metric_code, raw_text == "true")
          end
          
          %Metric{
            movie_id: movie.id,
            metric_code: metric_code,
            raw_value_numeric: raw_value,
            raw_value_text: raw_text,
            normalized_value: normalized,
            observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
          |> Repo.insert!(
            on_conflict: :replace_all,
            conflict_target: [:movie_id, :metric_code]
          )
          
          Agent.update(canonical_count, &(&1 + 1))
        end
      end
    end)
  end
end)

final_canonical = Agent.get(canonical_count, & &1)
Agent.stop(canonical_count)
IO.puts "✓ Migrated #{final_canonical} canonical source metrics"

# Process festival awards
{:ok, festival_count} = Agent.start_link(fn -> 0 end)
festival_nominations = Repo.all(
  from nom in "festival_nominations",
    join: fc in "festival_ceremonies", on: nom.ceremony_id == fc.id,
    join: fo in "festival_organizations", on: fc.organization_id == fo.id,
    where: nom.won == true,
    select: %{
      movie_id: nom.movie_id,
      organization: fo.abbreviation,
      year: fc.year
    }
)

IO.puts "Processing #{length(festival_nominations)} festival wins..."

# Map festival abbreviations to our metric codes
festival_mappings = %{
  "CANNES" => "cannes_palme_dor",
  "VIFF" => "venice_golden_lion",
  "BERLINALE" => "berlin_golden_bear",
  "SUNDANCE" => "sundance_grand_jury"
}

Enum.each(festival_nominations, fn nom ->
  metric_code = Map.get(festival_mappings, nom.organization)
  
  if metric_code && Map.has_key?(definitions, metric_code) && nom.movie_id do
    normalized = CRI.normalize_value(metric_code, true)
    
    %Metric{
      movie_id: nom.movie_id,
      metric_code: metric_code,
      raw_value_text: "true",
      normalized_value: normalized,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: [:movie_id, :metric_code]
    )
    
    Agent.update(festival_count, &(&1 + 1))
  end
end)

final_festival = Agent.get(festival_count, & &1)
Agent.stop(festival_count)
IO.puts "✓ Migrated #{final_festival} festival award metrics"

# Count Oscar data
oscar_noms = Repo.all(
  from nom in "festival_nominations",
    join: fc in "festival_ceremonies", on: nom.ceremony_id == fc.id,
    join: fo in "festival_organizations", on: fc.organization_id == fo.id,
    where: fo.abbreviation == "AMPAS",
    group_by: nom.movie_id,
    select: %{
      movie_id: nom.movie_id,
      nominations: count(nom.id),
      wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", nom.won))
    }
)

{:ok, oscar_count} = Agent.start_link(fn -> 0 end)
Enum.each(oscar_noms, fn oscar ->
  if oscar.movie_id do
    # Oscar nominations
    if oscar.nominations > 0 do
      normalized = CRI.normalize_value("oscar_nominations", oscar.nominations)
      
      %Metric{
        movie_id: oscar.movie_id,
        metric_code: "oscar_nominations",
        raw_value_numeric: Float.round(oscar.nominations * 1.0, 1),
        normalized_value: normalized,
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Repo.insert!(
        on_conflict: :replace_all,
        conflict_target: [:movie_id, :metric_code]
      )
      Agent.update(oscar_count, &(&1 + 1))
    end
    
    # Oscar wins
    if oscar.wins && oscar.wins > 0 do
      normalized = CRI.normalize_value("oscar_wins", oscar.wins)
      
      %Metric{
        movie_id: oscar.movie_id,
        metric_code: "oscar_wins",
        raw_value_numeric: Float.round(oscar.wins * 1.0, 1),
        normalized_value: normalized,
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Repo.insert!(
        on_conflict: :replace_all,
        conflict_target: [:movie_id, :metric_code]
      )
      Agent.update(oscar_count, &(&1 + 1))
    end
  end
end)

final_oscar = Agent.get(oscar_count, & &1)
Agent.stop(oscar_count)
IO.puts "✓ Migrated #{final_oscar} Oscar metrics"

# Summary
total_metrics = Repo.one(from m in Metric, select: count(m.id))
unique_movies = Repo.one(from m in Metric, select: count(m.movie_id, :distinct))
metrics_by_category = Repo.all(
  from m in Metric,
    join: md in MetricDefinition, on: m.metric_code == md.code,
    group_by: md.category,
    select: {md.category, count(m.id)}
)

IO.puts "\n========== MIGRATION COMPLETE ==========\n"
IO.puts "Total metrics: #{total_metrics}"
IO.puts "Unique movies with metrics: #{unique_movies}"
IO.puts "\nMetrics by category:"
Enum.each(metrics_by_category, fn {category, count} ->
  IO.puts "  #{category}: #{count}"
end)