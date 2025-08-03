# Oscar Import System Audit & Modernization Strategy

## Executive Summary

The Oscar import system is functional but not integrated with our modern, modular Oban-based import architecture. While it successfully fetches and stores Oscar data, it operates as a separate system rather than leveraging our existing worker patterns, quality filters, and import flows.

## Current State Analysis

### What's Working Well ✅

1. **Data Collection Pipeline**
   - Successfully fetches Oscar ceremony data from Oscars.org via Zyte API
   - Enhances data with IMDb IDs for accurate movie matching
   - Stores comprehensive nomination data in both JSONB and relational tables

2. **Database Design**
   - Minimal, efficient schema with `oscar_categories` and `oscar_nominations` tables
   - Smart person tracking (only for actor/director categories)
   - Database views for quick stat queries
   - Integration with existing movies table

3. **Mix Task Interface**
   - Clean command-line interface for year/range/all imports
   - Parallel job processing for multiple years
   - Status monitoring capabilities

4. **Core Functionality**
   - Creates/updates movies with Oscar data
   - Handles missing movies by creating from TMDb
   - Queues enrichment jobs for new movies

### What's Missing/Inconsistent ❌

1. **Not Using Standard Import Architecture**
   - Oscar import directly creates movies instead of using `TMDbDetailsWorker`
   - Doesn't leverage `QualityFilter` for import decisions
   - No integration with `ImportState` tracking
   - Bypasses our modular worker pipeline

2. **Inconsistent Worker Patterns**
   - `OscarImportWorker` only handles year-level orchestration
   - Movie creation happens inline rather than via dedicated workers
   - No separation between discovery and details phases
   - Enrichment uses custom `EnrichMovieWorker` instead of standard `OMDbEnrichmentWorker`

3. **Missing Data Processing**
   - No automatic creation of Person records from credits
   - No keyword/genre extraction from Oscar categories
   - No production company data capture
   - No integration with collaboration tracking

4. **Quality & Filtering Issues**
   - All Oscar nominees imported regardless of quality criteria
   - No vote count or popularity thresholds
   - Could create many low-quality movie records
   - No `SkippedImports` tracking for failed lookups

5. **Documentation Gaps**
   - README mentions Oscar import but doesn't explain architecture
   - No mention of modular design or worker pipeline
   - Missing explanation of data flow and integration points

## Current Data Flow vs. Ideal Data Flow

### Current Oscar Import Flow
```
OscarCeremony → OscarImporter → Direct Movie Creation → EnrichMovieWorker
                                         ↓
                                 OscarNomination records
```

### Standard TMDb Import Flow
```
Discovery → TMDbDetailsWorker → QualityFilter → Movie Creation → OMDbEnrichmentWorker
                                       ↓                              ↓
                                 ImportState               MediaProcessingWorker
                                       ↓                              ↓
                                 SkippedImports            CollaborationWorker
```

### Ideal Oscar Import Flow
```
OscarCeremony → OscarDiscoveryWorker → TMDbDetailsWorker → QualityFilter
                         ↓                      ↓                ↓
                OscarNomination         Movie Creation    SkippedImports
                         ↓                      ↓
                 PersonWorker          OMDbEnrichmentWorker
                                               ↓
                                      MediaProcessingWorker
                                               ↓
                                      CollaborationWorker
```

## Proposed Modernization Strategy

### Phase 1: Align with Existing Architecture

1. **Create OscarDiscoveryWorker**
   - Similar to `TMDbDiscoveryWorker`
   - Processes ceremony data and queues individual movie jobs
   - Creates nomination records
   - Queues `TMDbDetailsWorker` for each movie

2. **Integrate with Standard Pipeline**
   - Use `TMDbDetailsWorker` for movie creation
   - Apply `QualityFilter` (with Oscar nomination as quality boost)
   - Track skipped movies in `SkippedImports`
   - Use standard `OMDbEnrichmentWorker`

3. **Add Person Processing**
   - Create `PersonWorker` for actor/director records
   - Link to nominations for single-person categories
   - Update collaboration tracking

### Phase 2: Enhance Data Capture

1. **Extract Additional Metadata**
   - Map Oscar categories to genres/keywords
   - Extract production companies from winner data
   - Capture ceremony metadata (host, venue, date)

2. **Improve Matching Logic**
   - Use fuzzy matching for titles without IMDb IDs
   - Cross-reference with release years
   - Handle title variations and translations

3. **Add Import Tracking**
   - Integrate with `ImportState` system
   - Track Oscar-specific metrics
   - Add to import dashboard

### Phase 3: Quality & Performance

1. **Implement Smart Filtering**
   - Oscar nomination = automatic quality pass
   - But still apply basic sanity checks
   - Track why movies were imported

2. **Optimize API Usage**
   - Batch TMDb lookups where possible
   - Cache ceremony data to avoid re-fetching
   - Use conditional imports for existing movies

3. **Add Monitoring**
   - Oscar-specific import stats
   - Success/failure rates by year
   - Data quality metrics

## Implementation Priorities

### High Priority (Do First)
1. Create `OscarDiscoveryWorker` to align with standard architecture
2. Switch to using `TMDbDetailsWorker` for movie creation
3. Fix person tracking to create Person records
4. Update documentation to explain integration

### Medium Priority (Do Next)
1. Integrate with `QualityFilter` and `ImportState`
2. Add genre/keyword extraction from categories
3. Implement better matching for movies without IMDb IDs
4. Add to import dashboard UI

### Low Priority (Future)
1. Extract ceremony metadata
2. Add production company tracking
3. Implement smart caching strategies
4. Create Oscar-specific quality metrics

## Benefits of Modernization

1. **Consistency**: Single architecture for all imports
2. **Maintainability**: Reuse existing, tested components
3. **Completeness**: Capture all available data
4. **Quality**: Apply same standards across sources
5. **Monitoring**: Unified tracking and dashboards
6. **Scalability**: Leverage existing job infrastructure

## Migration Path

1. Keep existing system running (don't break imports)
2. Implement new workers alongside old system
3. Test with single year imports
4. Gradually switch over once verified
5. Remove old code after full migration

## Success Metrics

- All Oscar movies created via standard pipeline
- Person records created for all actor/director awards
- Import stats visible in dashboard
- No duplicate movie creation
- Consistent data quality across sources

## Conclusion

The Oscar import system works but exists as an island. By integrating it with our modular architecture, we'll have a more maintainable, consistent, and powerful system that leverages all our existing infrastructure while capturing richer data about these culturally significant films.