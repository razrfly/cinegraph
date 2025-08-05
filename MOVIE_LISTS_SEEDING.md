# Movie Lists Seeding Documentation

## Overview

The movie lists system includes built-in seeding functionality to restore the 5 default canonical lists when needed.

## Default Lists

The following lists are automatically seeded from `canonical_lists.ex`:

1. **1001 Movies You Must See Before You Die** (`1001_movies`)
   - Category: curated
   - IMDB List: ls024863935

2. **The Criterion Collection** (`criterion`)
   - Category: curated
   - IMDB List: ls081680443

3. **BFI's Sight & Sound Critics 2022** (`sight_sound_critics_2022`)
   - Category: critics
   - IMDB List: ls567380976

4. **National Film Registry** (`national_film_registry`)
   - Category: registry
   - IMDB List: ls084110988

5. **Cannes Film Festival Award Winners** (`cannes_winners`)
   - Category: awards
   - IMDB List: ls084792495
   - Tracks awards: true

## Seeding Methods

### Method 1: Database Seeds (Recommended)
```bash
mix run priv/repo/seeds.exs
```

### Method 2: Mix Task
```bash
mix seed_movie_lists
```

### Method 3: Convenience Script
```bash
./scripts/reseed_movie_lists.sh
```

### Method 4: During Database Clear
When running `./scripts/clear_database.sh`, you'll be prompted:
```
Would you like to reseed the default movie lists? (y/n)
```

## When to Reseed

You should reseed movie lists when:
- After clearing the database with `clear_database.sh`
- Setting up a new development environment
- The movie_lists table is accidentally truncated
- You want to restore default lists after testing

## Verification

To verify the lists are seeded:
```bash
mix run -e "Cinegraph.Movies.MovieLists.list_all_movie_lists() |> Enum.each(fn l -> IO.puts(l.name) end)"
```

Or check in the UI at: http://localhost:4001/import

## Important Notes

1. **Idempotent**: The seeding is idempotent - running it multiple times won't create duplicates
2. **Backward Compatible**: The system falls back to hardcoded lists if database lists aren't found
3. **Preserves Data**: Seeding won't overwrite existing lists with the same source_key
4. **No Movie Data**: Seeding only creates the list configurations, not the actual movies