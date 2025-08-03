# Modernize Oscar Import System to Use Standard Worker Architecture

## Problem

The Oscar import system currently operates independently from our modular Oban-based import architecture. While functional, it bypasses our established patterns for quality filtering, worker pipelines, and data processing.

## Current Behavior

- Oscar import directly creates movies via `OscarImporter` instead of using worker pipeline
- No integration with `QualityFilter` or `ImportState` tracking
- Custom `EnrichMovieWorker` instead of standard `OMDbEnrichmentWorker`
- No Person records created despite having actor/director data
- Missing keyword/genre extraction from Oscar categories

## Expected Behavior

Oscar imports should follow the same architecture as TMDb imports:
```
Discovery → Details Worker → Quality Filter → Movie Creation → Enrichment → Media Processing
```

## Technical Details

### Current Flow
```
OscarCeremony → OscarImporter → Direct Movie Creation → EnrichMovieWorker
```

### Standard TMDb Flow
```
Discovery → TMDbDetailsWorker → QualityFilter → Movie Creation → OMDbEnrichmentWorker → MediaProcessingWorker
```

### Missing Components
1. No `OscarDiscoveryWorker` to queue individual movie jobs
2. Bypasses `TMDbDetailsWorker` for movie creation
3. No `PersonWorker` for creating Person records
4. No integration with `SkippedImports` for failed lookups
5. No collaboration tracking between co-nominees

## Proposed Solution

### Phase 1: Core Architecture Alignment
- [ ] Create `OscarDiscoveryWorker` that processes ceremonies and queues movie jobs
- [ ] Use existing `TMDbDetailsWorker` for all movie creation
- [ ] Create Person records for actor/director categories
- [ ] Switch from `EnrichMovieWorker` to `OMDbEnrichmentWorker`
- [ ] Update documentation to explain integration

### Phase 2: Data Enhancement
- [ ] Extract genres/keywords from Oscar categories (e.g., "Best Animated Feature" → Animation genre)
- [ ] Integrate with `QualityFilter` (Oscar nomination = quality boost)
- [ ] Track skipped movies in `SkippedImports` table
- [ ] Add collaboration tracking for multi-person nominations
- [ ] Include in import dashboard statistics

### Phase 3: Advanced Features
- [ ] Implement fuzzy title matching for movies without IMDb IDs
- [ ] Extract production company data from winner information
- [ ] Add ceremony metadata (host, venue, broadcast date)
- [ ] Create Oscar-specific quality metrics

## Benefits

1. **Consistency**: Single architecture for all import sources
2. **Maintainability**: Reuse battle-tested components
3. **Data Completeness**: Capture all available metadata
4. **Quality Control**: Apply same standards across sources
5. **Monitoring**: Unified tracking and dashboards

## Implementation Notes

- Keep existing system running during migration
- Test with single year before full rollout
- Preserve all existing Oscar data
- Maintain backward compatibility with Mix task

## Acceptance Criteria

- [ ] All Oscar movies created via standard worker pipeline
- [ ] Person records exist for all actor/director awards
- [ ] Oscar imports visible in import dashboard
- [ ] No duplicate movies created
- [ ] Quality filters applied consistently
- [ ] Documentation updated with new architecture

## Related Issues

- #72 - Oscar Data Storage
- #73 - Awards Data Ingestion System
- #75 - Minimal Oscar Database Schema
- #76 - Oscar Import Mix Task

## Priority

High - This aligns core functionality with established patterns and enables future enhancements

## Labels

`refactoring`, `import-system`, `oscar-data`, `architecture`, `data-quality`