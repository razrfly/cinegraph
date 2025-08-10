# Race Condition in People Nominations Creation

## Problem Summary

There is a persistent race condition causing inconsistent people nominations between import runs. The first import of Oscar 2024 data creates only 28 out of 44 expected people-based nominations, while a second import successfully creates all 44. This has been attempted to be fixed 3-4 times (#196, #197, #199, #200) without full resolution.

## Root Cause Analysis

### The Core Issue

The fundamental problem is an **inherent architectural race condition** in the asynchronous person entity creation workflow:

1. **FestivalDiscoveryWorker** processes ceremony data and tries to create nominations
2. For people-based categories, it attempts to find or create Person entities
3. If a person doesn't exist, it queues a **TMDbDetailsWorker** job to create them
4. The nomination is created with `person_id: nil` and `person_imdb_ids` as a pending state
5. Multiple workers processing the same ceremony can trigger duplicate person creation attempts
6. The timing window between checking for existence and creating entities causes duplicates

### Why Current Solutions Haven't Worked

#### 1. Database Constraints (Migration 20250807124645)
- Added unique indexes for person and film nominations
- **Problem**: Constraints fire AFTER the race condition has already occurred
- Transactions still allow the timing window between check and insert

#### 2. Complex Duplicate Detection (lines 468-536, 653-728)
- Extensive checking for existing nominations via multiple query patterns
- **Problem**: The queries themselves are not atomic with the insert
- Between the check and insert, another worker can create the same entity

#### 3. Synchronous Person Creation Attempt (lines 766-867)
- Added `find_or_create_person` that tries TMDb API synchronously first
- **Problem**: API calls are slow (500ms-2s), creating even larger timing windows
- Multiple workers waiting on API calls can still race on the insert

## Evidence of the Problem

### From OSCARS_2024_BASELINE_ANALYSIS.md:
- **Expected**: 44 people-based nominations across 11 categories
- **First Run**: Only 28 nominations created
- **Second Run**: All 44 nominations created successfully

### Code Evidence:

```elixir
# FestivalDiscoveryWorker.ex line 801-867
defp find_or_create_person(imdb_id, _nominee_name) when is_binary(imdb_id) do
  case Repo.get_by(Person, imdb_id: imdb_id) do
    nil ->
      # RACE CONDITION HERE: Multiple workers can pass this check simultaneously
      case TMDb.fetch_person_by_imdb(imdb_id) do
        {:ok, person_data} ->
          # Multiple workers can attempt this insert simultaneously
          create_person_from_tmdb(person_data, imdb_id)
```

## Why This Is Fundamentally Difficult

1. **Distributed System Problem**: Multiple Oban workers running concurrently
2. **External API Dependency**: TMDb API calls introduce variable latency
3. **Complex Entity Relationships**: Movies, People, and Nominations all interrelated
4. **Partial State Management**: Need to handle pending nominations while entities are being created

## Proposed Solutions (Not Previously Tried)

### Solution 1: Two-Phase Import with Batch Pre-Processing

**Approach**: Separate entity creation from nomination creation entirely

```elixir
# Phase 1: Collect all unique entities needed
def pre_process_ceremony(ceremony) do
  all_people_imdb_ids = extract_all_person_imdb_ids(ceremony)
  all_movie_imdb_ids = extract_all_movie_imdb_ids(ceremony)
  
  # Batch create all people and movies first
  batch_ensure_people_exist(all_people_imdb_ids)
  batch_ensure_movies_exist(all_movie_imdb_ids)
  
  # Phase 2: Now create nominations with all entities guaranteed to exist
  create_all_nominations(ceremony)
end
```

**Pros:**
- Eliminates race conditions by ensuring entities exist before nominations
- More efficient API usage with batching
- Predictable and consistent results

**Cons:**
- Requires significant refactoring
- Longer initial processing time
- All-or-nothing approach (less granular progress)

### Solution 2: Optimistic Locking with Retry Logic

**Approach**: Use database-level advisory locks or optimistic locking

```elixir
def find_or_create_person_with_lock(imdb_id) do
  lock_key = :erlang.phash2({:person, imdb_id})
  
  Repo.transaction(fn ->
    # Acquire advisory lock for this specific person
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])
    
    case Repo.get_by(Person, imdb_id: imdb_id) do
      nil -> create_person_from_tmdb(imdb_id)
      person -> person
    end
  end)
end
```

**Pros:**
- Minimal code changes required
- Works with existing architecture
- Handles concurrent access properly

**Cons:**
- Potential for lock contention and deadlocks
- Performance impact from locking
- Requires PostgreSQL-specific features

### Solution 3: Database-Level UPSERT with Conflict Resolution

**Approach**: Use PostgreSQL's INSERT ... ON CONFLICT at the database level

```elixir
def upsert_person(attrs) do
  Repo.insert!(
    %Person{},
    attrs,
    on_conflict: :replace_all_except_[:id, :inserted_at],
    conflict_target: :imdb_id,
    returning: true
  )
end
```

**Pros:**
- Atomic operation at database level
- No race conditions possible
- Simple and efficient

**Cons:**
- May lose data if conflicts aren't handled carefully
- Requires careful handling of partial updates
- Need to ensure all paths use upsert consistently

### Solution 4: Idempotent Import with Deterministic IDs

**Approach**: Make the entire import process idempotent by using deterministic IDs

```elixir
def create_nomination_idempotent(attrs) do
  # Generate deterministic ID based on unique combination
  id = generate_deterministic_id(
    attrs.ceremony_id,
    attrs.category_id,
    attrs.movie_id,
    attrs.person_name
  )
  
  %FestivalNomination{id: id}
  |> FestivalNomination.changeset(attrs)
  |> Repo.insert(
    on_conflict: :nothing,
    conflict_target: :id
  )
end
```

**Pros:**
- Truly idempotent - can run multiple times safely
- No race conditions or duplicates possible
- Works well with distributed systems

**Cons:**
- Requires UUID or similar ID strategy
- May need schema changes
- Could affect existing data

## Recommendation

Given the complexity and multiple previous attempts, I recommend **two approaches**:

### 1. Short-term: Accept the Limitation
- Document that imports may need to be run twice
- Add automatic retry logic to detect incomplete imports
- Focus engineering effort on more impactful issues
- Add monitoring to track when this occurs

### 2. Long-term: Implement Solution 1 (Two-Phase Import)
- Most architecturally sound solution
- Eliminates the race condition entirely
- Worth the refactoring effort if this remains a critical issue
- Can be implemented gradually alongside existing code

## Alternative: Solution 3 (Database UPSERT)
If quick fix is needed:
- Minimal code changes
- Leverages database guarantees
- Has been proven to work in similar systems
- Risk: May hide other data quality issues

## Impact Assessment

- **Severity**: Medium (data eventually consistent, but requires manual intervention)
- **Frequency**: Every festival import with people-based categories
- **User Impact**: Incorrect statistics shown until second import
- **Engineering Cost**: High (multiple attempts already made)

## Decision Criteria

Consider NOT fixing if:
- Two-run import is acceptable operationally
- Engineering resources needed elsewhere
- Risk of introducing new bugs outweighs benefit

Consider fixing if:
- Automated imports are critical
- Data accuracy on first run is required
- This pattern appears in other parts of the system

## Related Issues
- #196 - Initial attempt to fix duplicate nominations
- #197 - Academy Awards data import issues  
- #199 - Added unique constraints (partial fix)
- #200 - Current issue documenting the persistent problem

## Testing Checklist
- [ ] First import creates all 44 people nominations
- [ ] Second import doesn't create duplicates
- [ ] Concurrent ceremony processing doesn't cause races
- [ ] Person creation handles API failures gracefully
- [ ] Pending nominations are properly linked when entities are created