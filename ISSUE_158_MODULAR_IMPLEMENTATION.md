# Issue #158: Restore Modular Task Architecture - Implementation Status

## Summary
We've implemented Option 1 (Full Restoration) to restore the modular task architecture for Oscar imports while using the new unified `festival_*` tables. However, nominations are not being created due to a ceremony ID mismatch issue.

## Implementation Progress

### ✅ Completed Tasks

#### 1. Created FestivalDiscoveryWorker
- **File**: `lib/cinegraph/workers/festival_discovery_worker.ex`
- **Based on**: Original OscarDiscoveryWorker
- **Changes**:
  - Uses `FestivalCeremony`, `FestivalCategory`, `FestivalNomination` tables
  - Processes ceremony data and creates nominations
  - Queues TMDbDetailsWorker for new movies
  - Handles both atom and string keys from scraper

#### 2. Updated Cultural.import_oscar_year
- **File**: `lib/cinegraph/cultural.ex` (lines 383-435)
- **Changes**:
  - Now creates/finds FestivalCeremony record
  - Queues FestivalDiscoveryWorker instead of synchronous processing
  - Returns queued status with job ID for tracking

#### 3. Updated OscarImportWorker
- **File**: `lib/cinegraph/workers/oscar_import_worker.ex`
- **Changes**:
  - Handles new queued response format from Cultural.import_oscar_year
  - Broadcasts appropriate progress messages for queued jobs
  - Maintains backward compatibility with direct processing results

### ✅ RESOLVED: Ceremony ID Issue Was From Earlier Test

#### Investigation Results
The ceremony ID mismatch (job processing ID 44 instead of 50) was from an earlier test run. Current implementation correctly passes ceremony IDs.

### ⚠️ Current Issue: IMDb Enhancement Only Matching 15/120 Nominees

#### Problem Discovery
After fixing the ceremony ID issue, the system is creating nominations but only for a small subset:
- Ceremony has 23 categories with 120 total nominees
- Only 15 nominees have IMDb IDs after enhancement
- FestivalDiscoveryWorker skips nominees without IMDb IDs (line 166-168)
- Result: Only 15 nominations created instead of 120

#### Root Cause Analysis
```
=== IMDb ID Coverage ===
Total nominees: 120
With IMDb IDs: 15
Without IMDb IDs: 105

=== Sample from Best Picture Category ===
🏆 Oppenheimer - IMDb: tt15398776  ✅
📽️ American Fiction - IMDb: NO IMDB ID ❌
📽️ Anatomy of a Fall - IMDb: NO IMDB ID ❌
📽️ Barbie - IMDb: NO IMDB ID ❌
📽️ The Holdovers - IMDb: NO IMDB ID ❌
```

The IMDb enhancement process is failing to match most nominees. Warnings show:
- No IMDb match for category: Animated Feature Film
- No IMDb match for category: Documentary Feature Film
- No IMDb match for category: International Feature Film
- etc.

#### Why This Is Happening
The `ImdbOscarScraper.enhance_ceremony_with_imdb` function is not properly matching nominee names to IMDb IDs. It successfully fetches the IMDb page but fails to extract/match most of the data.

### 🔧 Fix Required

#### Investigation Needed
1. Check how ceremony_id is being passed from Cultural.import_oscar_year to FestivalDiscoveryWorker
2. Verify the ceremony creation/lookup logic
3. Ensure the correct ID is being queued

#### Potential Issues to Check
```elixir
# In Cultural.import_oscar_year:
{:ok, fest_ceremony} = Cinegraph.Festivals.find_or_create_ceremony(
  oscar_org.id,
  year,
  %{ceremony_number: ceremony_number, data: ceremony_data}
)

# The job args use fest_ceremony.id
job_args = %{
  "ceremony_id" => fest_ceremony.id,  # <-- This should be 50, not 44
  "organization" => "AMPAS",
  "options" => Enum.into(options, %{})
}
```

### Worker Flow (As Implemented)

```
OscarImportWorker 
  ↓ (calls)
Cultural.import_oscar_year()
  ↓ (creates ceremony & queues)
FestivalDiscoveryWorker [Job ID returned]
  ↓ (processes ceremony - BUT WRONG ID!)
  ↓ (should queue)
TMDbDetailsWorker (per new movie)
  ↓ (should queue)
OMDbEnrichmentWorker (per movie)
  ↓ (should queue)
CollaborationWorker (for credits)
```

## Next Steps

### Immediate Actions
1. **Debug ceremony ID mismatch**:
   - Add logging to trace ceremony ID through the flow
   - Verify Festivals.find_or_create_ceremony returns correct ID
   - Check if there's ID confusion between old and new ceremonies

2. **Fix the ID passing**:
   - Ensure fest_ceremony.id is correctly captured
   - Verify job args are correctly formed
   - Test with fresh ceremony creation

3. **Verify worker chain**:
   - Once nominations are created, verify TMDbDetailsWorker is queued
   - Check enrichment workers are triggered
   - Confirm collaboration processing

### Testing Checklist
- [ ] Fix ceremony ID mismatch issue
- [ ] Verify nominations are created correctly
- [ ] Confirm TMDbDetailsWorker jobs are queued for new movies
- [ ] Check OMDbEnrichmentWorker is triggered
- [ ] Verify CollaborationWorker processes credits
- [ ] Dashboard shows correct counts

## ✅ Benefits Already Achieved
1. **Modular Architecture Restored**: Separate workers for each stage
2. **Job Visibility**: Individual tasks appear in Oban dashboard  
3. **Proper Queuing**: Workers queue subsequent workers (TMDbDetailsWorker jobs confirmed)
4. **Error Isolation**: Failed tasks won't stop entire import
5. **Ceremony ID Issue Resolved**: Was from earlier test, now working correctly

## Worker Chain Status
- ✅ OscarImportWorker → Cultural.import_oscar_year
- ✅ Cultural.import_oscar_year → FestivalDiscoveryWorker queued
- ✅ FestivalDiscoveryWorker processes ceremony
- ⚠️ IMDb enhancement only matching 15/120 nominees
- ✅ TMDbDetailsWorker jobs queued for movies without records
- ✅ Nominations created (but only for 15 nominees with IMDb IDs)

## Remaining Issues
1. **IMDb Enhancement**: Fix the scraper to properly match all 120 nominees
2. **Alternative Strategy**: Consider creating nominations even without IMDb IDs and enriching later
3. **Test Full Chain**: Verify OMDbEnrichmentWorker and CollaborationWorker are triggered

## Code Locations
- `lib/cinegraph/workers/festival_discovery_worker.ex` - New discovery worker
- `lib/cinegraph/cultural.ex:383-435` - Updated import_oscar_year
- `lib/cinegraph/workers/oscar_import_worker.ex:28-42` - Handles queued response
- `lib/cinegraph/festivals.ex` - find_or_create_ceremony function (needs review)

## Success Metrics
Once the ID issue is fixed, we expect:
- Multiple worker jobs in queue (not one long task)
- Each movie creation as separate job
- Enrichment workers queued automatically
- Failed tasks can be retried individually
- Data integrity maintained (80 nominations for 2024)