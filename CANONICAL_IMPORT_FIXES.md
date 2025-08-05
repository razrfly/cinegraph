# Canonical Import Fixes - Implementation Summary

## Changes Implemented from Issue #122

### 1. Fixed Canonical Source Update Logic ✅

**Problem**: When movies already existed, canonical sources weren't being added properly.

**Solution**: Modified `TMDbDetailsWorker` to ensure canonical sources are added even when movies already exist:
- Added canonical source handling in the `existing_movie` branch
- Added canonical source handling in the `movie_exists?` check
- Both cases now properly call `mark_movie_canonical`

**Files Modified**:
- `lib/cinegraph/workers/tmdb_details_worker.ex`

### 2. Enhanced Validation & Logging ✅

**Problem**: No visibility into whether canonical sources were actually saved.

**Solution**: Added comprehensive logging and validation:
- Log current canonical sources before update
- Log the update attempt with full data
- Verify after update that the source was actually added
- Error logging if verification fails

**Files Modified**:
- `lib/cinegraph/workers/tmdb_details_worker.ex` - `mark_movie_canonical` function

### 3. Post-Import Audit Script ✅

**Problem**: No way to identify and fix movies missing canonical sources.

**Solution**: Created comprehensive audit script that:
- Shows expected vs actual counts for each canonical list
- Identifies missing movies by comparing Oban metadata to database
- Attempts to fix missing canonical sources automatically
- Provides detailed reporting

**Files Created**:
- `scripts/audit_canonical_sources.exs`

### 4. Retry Mechanism ✅

**Problem**: Failed canonical source updates were lost forever.

**Solution**: Implemented retry worker:
- New `CanonicalRetryWorker` handles retries
- Automatically queued when updates fail
- 3 retry attempts with unique constraints
- Added to Oban queue configuration

**Files Created**:
- `lib/cinegraph/workers/canonical_retry_worker.ex`

**Files Modified**:
- `lib/cinegraph/workers/tmdb_details_worker.ex` - Added retry queueing
- `config/config.exs` - Added `canonical_retry` queue

## How to Use

### 1. Run the Audit Script
```bash
mix run scripts/audit_canonical_sources.exs
```

This will:
- Show what was scraped vs what's in the database
- Identify missing canonical sources
- Attempt to fix them automatically
- Show final counts

### 2. Monitor Retry Queue
Check the Oban dashboard or query:
```sql
SELECT * FROM oban_jobs 
WHERE queue = 'canonical_retry' 
AND state IN ('available', 'executing', 'retryable');
```

### 3. Verify Fix Success
After running imports again, the success rates should improve significantly:
- Cannes Winners: 22.8% → ~95%+
- National Film Registry: 60.7% → ~95%+

## Key Improvements

1. **No Silent Failures**: All canonical source updates are logged
2. **Automatic Recovery**: Failed updates are retried automatically
3. **Visibility**: Audit script shows exactly what's missing
4. **Verification**: Every update is verified to ensure it persisted

## Next Steps

1. Run the audit script to fix existing data
2. Clear and re-import problem lists (Cannes, NFR) to test fixes
3. Monitor logs to ensure canonical sources are being added
4. Check retry queue for any persistent failures