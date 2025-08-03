# 🎯 Canonical Movies Storage: Boolean Field vs Separate Table Analysis

## 🤔 Problem Statement

We need to mark ~1,260 movies from "1001 Movies You Must See Before You Die" as canonical for backtesting purposes. The only data we actually need is: **"Is this movie canonical? Yes/No"**

## 📊 Objective Analysis: Storage Approaches

### Option 1: Boolean Field on Movies Table (Recommended)

**Implementation:**
```sql
-- Add to existing movies table
ALTER TABLE movies ADD COLUMN is_canonical boolean DEFAULT false;
CREATE INDEX idx_movies_canonical ON movies(is_canonical) WHERE is_canonical = true;
```

**Query Examples:**
```sql
-- Get all canonical movies (backtesting)
SELECT * FROM movies WHERE is_canonical = true;

-- Check if movie is canonical (instant lookup)
SELECT is_canonical FROM movies WHERE imdb_id = 'tt0111161';

-- Calculate precision (no JOIN needed)
SELECT COUNT(*) FROM movies 
WHERE id IN (1,2,3,4,5) -- predicted movie IDs
AND is_canonical = true;
```

**Pros:**
- ✅ **Simplest possible solution** - single boolean field
- ✅ **Fastest queries** - no JOINs required  
- ✅ **Minimal storage overhead** - 1 byte per movie
- ✅ **No data duplication** - leverages existing movie data
- ✅ **Easy migration** - single ALTER TABLE statement
- ✅ **Intuitive queries** - `WHERE is_canonical = true`

**Cons:**
- ❌ **Single canonical source** - can't track multiple lists easily
- ❌ **No metadata** - lose information about which edition, position, etc.
- ❌ **Less flexible** - harder to extend for future canonical sources

---

### Option 2: JSONB Field (Flexible Alternative)

**Implementation:**
```sql
-- Add to existing movies table  
ALTER TABLE movies ADD COLUMN canonical_sources jsonb DEFAULT '{}';
CREATE INDEX idx_movies_canonical_sources ON movies USING GIN(canonical_sources);
```

**Data Examples:**
```json
-- Single canonical source
{"1001_movies_2024": true}

-- Multiple canonical sources (future)
{"1001_movies_2024": true, "sight_sound_2022": true, "criterion": true}

-- With metadata if needed
{"1001_movies_2024": {"included": true, "edition": "2024", "scraped_at": "2025-01-08"}}
```

**Query Examples:**
```sql
-- Get all canonical movies
SELECT * FROM movies WHERE canonical_sources ? '1001_movies_2024';

-- Check if movie is canonical  
SELECT canonical_sources ? '1001_movies_2024' as is_canonical 
FROM movies WHERE imdb_id = 'tt0111161';

-- Get movies canonical in ANY source
SELECT * FROM movies WHERE canonical_sources != '{}';
```

**Pros:**
- ✅ **Future-proof** - can add Sight & Sound, Criterion, etc.
- ✅ **No JOINs** - still single table queries
- ✅ **Metadata storage** - can store edition, scrape date if needed
- ✅ **Flexible querying** - PostgreSQL JSONB operators

**Cons:**
- ❌ **More complex** - JSONB syntax less intuitive  
- ❌ **Slight overhead** - JSONB storage vs boolean
- ❌ **Query complexity** - `?` operator vs simple `= true`

---

### Option 3: Separate Table (Current Plan - Not Recommended)

**Implementation:**
```sql
CREATE TABLE canonical_movies (
  id bigserial PRIMARY KEY,
  imdb_id varchar(20) UNIQUE,
  -- title, year, list_position (all redundant!)
);
```

**Pros:**
- ✅ **Normalized design** - separate concerns
- ✅ **Rich metadata** - can store any canonical-specific data

**Cons:**
- ❌ **Data duplication** - title, year already in movies table
- ❌ **JOIN overhead** - every backtesting query needs JOIN
- ❌ **Complex queries** - `FROM movies m JOIN canonical_movies cm ON...`
- ❌ **More maintenance** - two tables to keep in sync
- ❌ **Overkill** - only need "is canonical" flag

---

## 🎯 Recommended Implementation

### **Primary Recommendation: Boolean Field**

For our specific use case (CRI backtesting), the boolean field is optimal:

```elixir
# Migration
defmodule Cinegraph.Repo.Migrations.AddCanonicalFlag do
  use Ecto.Migration
  
  def change do
    alter table(:movies) do
      add :is_canonical, :boolean, default: false
    end
    
    # Partial index for fast canonical queries
    create index(:movies, [:is_canonical], where: "is_canonical = true")
  end
end

# Schema update
defmodule Cinegraph.Movies.Movie do
  schema "movies" do
    # ... existing fields
    field :is_canonical, :boolean, default: false
  end
end

# Usage in backtesting
def get_canonical_movies do
  from(m in Movie, where: m.is_canonical == true)
  |> Repo.all()
end

def calculate_precision(predicted_movie_ids) do
  canonical_matches = 
    from(m in Movie, 
      where: m.id in ^predicted_movie_ids and m.is_canonical == true)
    |> Repo.aggregate(:count)
  
  canonical_matches / length(predicted_movie_ids)
end
```

### **Future-Proofing Option: JSONB Field**

If we want to support multiple canonical sources later:

```elixir
# Migration
defmodule Cinegraph.Repo.Migrations.AddCanonicalSources do
  use Ecto.Migration
  
  def change do
    alter table(:movies) do
      add :canonical_sources, :map, default: %{}
    end
    
    create index(:movies, [:canonical_sources], using: :gin)
  end
end

# Usage
def mark_as_canonical(movie_id, source \\ "1001_movies_2024") do
  movie = Repo.get!(Movie, movie_id)
  new_sources = Map.put(movie.canonical_sources || %{}, source, true)
  
  movie
  |> Movie.changeset(%{canonical_sources: new_sources})
  |> Repo.update()
end

def is_canonical?(movie, source \\ "1001_movies_2024") do
  Map.get(movie.canonical_sources || %{}, source, false)
end
```

## 🚀 Implementation Plan

### **Phase 1: Add Boolean Field**
- [ ] **Create migration** to add `is_canonical boolean DEFAULT false`
- [ ] **Add partial index** for fast canonical queries  
- [ ] **Update Movie schema** with new field
- [ ] **Create helper functions** for canonical operations

### **Phase 2: Import & Mark Movies**
- [ ] **Scrape IMDb list** for 1,260 IMDb IDs
- [ ] **Match against existing movies** in our database
- [ ] **Set `is_canonical = true`** for matched movies
- [ ] **Queue imports** for missing canonical movies via TMDbDetailsWorker

### **Phase 3: Backtesting Integration**
- [ ] **Update CRI calculation** to use `is_canonical` field
- [ ] **Create precision/recall** measurement functions
- [ ] **Build backtesting queries** leveraging the boolean field

## 🎯 Success Metrics

- ✅ **Query Performance**: `SELECT * FROM movies WHERE is_canonical = true` < 5ms
- ✅ **Data Coverage**: 90%+ of canonical movies exist in our database
- ✅ **Precision Calculation**: Fast computation without JOINs
- ✅ **Storage Efficiency**: <1MB overhead for canonical flags

## 🤝 Decision Factors

**Choose Boolean Field If:**
- ✅ Only need "1001 Movies" canonical list
- ✅ Prioritize simplicity and query performance  
- ✅ Backtesting is primary use case

**Choose JSONB Field If:**
- ✅ Plan to add Sight & Sound, Criterion, etc. lists
- ✅ Want metadata about canonical sources
- ✅ Need flexibility for future expansion

**Avoid Separate Table Because:**
- ❌ Data duplication (title, year)
- ❌ JOIN overhead for every query
- ❌ Over-engineering for boolean flag

---

## 💡 Final Recommendation

**Start with boolean field** (`is_canonical`) for immediate backtesting needs. This gives us:
- Fastest implementation and queries
- Minimal complexity
- Perfect for CRI validation

**Future migration path**: If we later need multiple canonical sources, we can migrate the boolean to JSONB:
```sql
-- Future migration if needed
UPDATE movies SET canonical_sources = '{"1001_movies_2024": true}' WHERE is_canonical = true;
ALTER TABLE movies DROP COLUMN is_canonical;
```

The boolean approach is the right solution for our current objective: **validate CRI algorithm against authoritative film canon with maximum simplicity and performance.**