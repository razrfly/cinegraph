# Festival Import Process Flow - Current vs JSON Blob Approach

## Current Process Flow (With Race Conditions)

### Phase 1: Festival Ceremony Processing
```
1. FestivalDiscoveryWorker receives ceremony data
   └── Contains: categories, nominees, films, person info
```

### Phase 2: Category & Nominee Processing
```
2. For each category in ceremony:
   ├── Create/find FestivalCategory
   └── For each nominee in category:
       └── Process nominee data
```

### Phase 3: Film Resolution (BRANCHING POINT)
```
3. For each nominee's film:
   ├── Case A: Film exists (by IMDb ID)
   │   └── Continue to nomination creation
   │
   └── Case B: Film doesn't exist
       ├── Queue TMDbDetailsWorker job
       └── Create PENDING nomination with:
           ├── movie_imdb_id (instead of movie_id)
           ├── movie_title (for reference)
           └── Continue with partial data
```

### Phase 4: Person Resolution (RACE CONDITION HERE)
```
4. For person-based categories:
   ├── Case A: Person exists (by IMDb ID)
   │   └── Use person_id in nomination
   │
   └── Case B: Person doesn't exist
       ├── Try synchronous TMDb API call (500ms-2s)
       ├── If API returns data:
       │   └── RACE: Multiple workers may create duplicate
       └── If no person found:
           └── Create PENDING nomination with:
               ├── person_imdb_ids[] (array of IMDb IDs)
               ├── person_name (string)
               └── person_id = nil
```

### Phase 5: Nomination Creation (COMPLEX DEDUP LOGIC)
```
5. Create FestivalNomination with:
   ├── Check for duplicates (lines 468-536):
   │   ├── By person_id (if exists)
   │   ├── By person_imdb_ids overlap
   │   ├── By person_name match
   │   └── By movie-only (film categories)
   │
   └── Insert nomination with partial data:
       ├── movie_id OR movie_imdb_id
       ├── person_id OR (person_imdb_ids + person_name)
       └── details{} with metadata
```

### Phase 6: Async Entity Creation
```
6. TMDbDetailsWorker processes queued jobs:
   ├── Creates Movie entity
   ├── Creates Person entities
   └── Attempts to link pending nominations
```

### Phase 7: Linking Pending Nominations
```
7. After entity creation:
   ├── TMDbDetailsWorker.link_pending_nominations()
   │   └── Updates nominations where movie_imdb_id matches
   │
   └── TMDbDetailsWorker.link_pending_person_nominations()
       └── Updates nominations where person_imdb_ids overlap
```

## Problem: Temporary State Scattered Across Tables

Current temporary/pending state locations:
1. **festival_nominations.movie_imdb_id** - pending movie reference
2. **festival_nominations.movie_title** - movie name for pending
3. **festival_nominations.person_imdb_ids[]** - pending person references
4. **festival_nominations.person_name** - person name for pending
5. **festival_nominations.details{}** - some metadata

This creates complex queries and race conditions when trying to link entities later.

---

## Proposed: JSON Blob Approach

### New Schema Structure
```elixir
# Add to festival_ceremonies table
field :import_state, :map  # Complete import state in JSON

# Structure:
{
  "status": "processing|complete",
  "nominations_pending": [
    {
      "category": "Best Actor",
      "category_id": 123,
      "nominee": {
        "name": "Cillian Murphy",
        "person_imdb_ids": ["nm0614165"],
        "winner": true
      },
      "film": {
        "title": "Oppenheimer",
        "imdb_id": "tt15398776",
        "tmdb_id": null  # Will be filled when found
      },
      "movie_id": null,      # Will be filled when created
      "person_id": null,     # Will be filled when created
      "nomination_id": null, # Will be filled when created
      "status": "pending_movie|pending_person|complete"
    }
  ],
  "entities_to_create": {
    "movies": {
      "tt15398776": {"title": "Oppenheimer", "status": "queued|creating|created", "id": null},
      "tt5535276": {"title": "Maestro", "status": "queued|creating|created", "id": null}
    },
    "people": {
      "nm0614165": {"name": "Cillian Murphy", "status": "queued|creating|created", "id": null},
      "nm0000288": {"name": "Bradley Cooper", "status": "queued|creating|created", "id": null}
    }
  },
  "stats": {
    "total_nominations": 115,
    "pending_nominations": 28,
    "completed_nominations": 87,
    "movies_to_create": 15,
    "people_to_create": 44
  }
}
```

### New Process Flow

#### Phase 1: Collect Everything First
```elixir
def process_ceremony(ceremony) do
  import_state = %{
    status: "processing",
    nominations_pending: [],
    entities_to_create: %{movies: %{}, people: %{}},
    stats: %{}
  }
  
  # 1. Parse all nominations without creating anything
  import_state = parse_all_nominations(ceremony, import_state)
  
  # 2. Save the complete state to ceremony
  ceremony
  |> Changeset.change(%{import_state: import_state})
  |> Repo.update!()
  
  # 3. Queue batch entity creation
  queue_entity_creation_job(ceremony.id)
end
```

#### Phase 2: Batch Entity Creation (Single Job)
```elixir
def perform(%Job{args: %{"ceremony_id" => ceremony_id}}) do
  ceremony = get_ceremony_with_import_state(ceremony_id)
  state = ceremony.import_state
  
  # 1. Create all movies in batch
  state = create_all_movies(state)
  
  # 2. Create all people in batch  
  state = create_all_people(state)
  
  # 3. Update state with created entity IDs
  ceremony |> update_import_state(state)
  
  # 4. Queue final nomination creation
  queue_nomination_creation_job(ceremony_id)
end
```

#### Phase 3: Create All Nominations (No Race Conditions!)
```elixir
def create_nominations_from_state(ceremony_id) do
  ceremony = get_ceremony_with_import_state(ceremony_id)
  
  Enum.each(ceremony.import_state["nominations_pending"], fn pending ->
    # All entities guaranteed to exist now
    movie_id = get_movie_id_from_state(pending)
    person_id = get_person_id_from_state(pending)
    
    # Simple, clean nomination creation
    create_nomination(%{
      ceremony_id: ceremony.id,
      category_id: pending["category_id"],
      movie_id: movie_id,
      person_id: person_id,
      won: pending["nominee"]["winner"]
    })
    
    # Update pending status
    mark_nomination_complete(ceremony, pending)
  end)
  
  # Mark ceremony import as complete
  finalize_ceremony_import(ceremony)
end
```

## Benefits of JSON Blob Approach

### 1. **No Race Conditions**
- Single source of truth for import state
- Sequential processing phases
- All entities exist before nominations

### 2. **Simpler Schema**
- Remove `movie_imdb_id`, `movie_title` from nominations
- Remove `person_imdb_ids`, `person_name` from nominations  
- Clean foreign keys only: `movie_id`, `person_id`

### 3. **Better Observability**
```elixir
# Can easily query import status
ceremony.import_state["stats"]["pending_nominations"]
# => 28

# Can see what's blocking
ceremony.import_state["entities_to_create"]["people"]
  |> Enum.filter(fn {_, p} -> p["status"] != "created" end)
# => Shows which people still need creation
```

### 4. **Resumable Process**
If job fails, can resume from exact state:
```elixir
def resume_import(ceremony_id) do
  ceremony = get_ceremony_with_import_state(ceremony_id)
  
  case ceremony.import_state["status"] do
    "pending_entities" -> queue_entity_creation_job(ceremony_id)
    "pending_nominations" -> queue_nomination_creation_job(ceremony_id)
    "complete" -> :ok
  end
end
```

### 5. **Atomic Operations**
```elixir
# Can validate entire import before committing
def validate_import_complete(ceremony) do
  state = ceremony.import_state
  
  all_movies_created? = 
    state["entities_to_create"]["movies"]
    |> Enum.all?(fn {_, m} -> m["status"] == "created" end)
    
  all_people_created? =
    state["entities_to_create"]["people"]
    |> Enum.all?(fn {_, p} -> p["status"] == "created" end)
    
  all_movies_created? && all_people_created?
end
```

## Migration Path

### Step 1: Add import_state to ceremonies
```elixir
alter table(:festival_ceremonies) do
  add :import_state, :map, default: %{}
  add :import_status, :string  # "pending", "processing", "complete"
end
```

### Step 2: New Worker Structure
```elixir
# Replace current complex flow with 3 simple workers:
1. CeremonyParserWorker     # Parse and save state
2. EntityCreationWorker     # Batch create entities  
3. NominationFinalizerWorker # Create nominations
```

### Step 3: Gradual Migration
- Keep old fields temporarily for backward compatibility
- New imports use JSON blob approach
- Migration script to convert old pending nominations

## Example: Oscar 2024 Import

### Current Approach (Problem)
```
Run 1: 28/44 people nominations created (race conditions)
Run 2: 44/44 people nominations created (finds existing entities)
```

### JSON Blob Approach (Solution)
```
Run 1:
  Phase 1: Parse all 115 nominations → import_state
  Phase 2: Create 40 movies, 50 people (batch, no races)
  Phase 3: Create all 115 nominations (all entities exist)
  Result: 44/44 people nominations first time!
```

## Summary

The JSON blob approach:
1. **Eliminates race conditions** by ensuring entities exist before nominations
2. **Simplifies the schema** by removing temporary fields
3. **Provides clear visibility** into import progress
4. **Makes the process resumable** at any point
5. **Reduces complexity** from 7 phases to 3 phases

The key insight: **Don't create partial records across multiple tables. Store the complete import intent in one place, then execute it sequentially.**