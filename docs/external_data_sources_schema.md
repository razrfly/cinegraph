# External Data Sources Schema Design

## Overview

This comprehensive schema design addresses the Cultural Relevance Index (CRI) requirements from Issue #3, providing a robust foundation for storing and managing diverse data sources while maintaining clear separation between authoritative and crowd-sourced data.

## Schema Architecture

### 1. Cultural Authority Registry

The `cultural_authorities` table serves as the master registry for all data sources:

```sql
- authority_type: canonical, critical, academic, crowdsourced, algorithmic
- category: official_list, award, collection, user_list, critic_aggregate
- trust_score: 1-10 scale for source reliability
- base_weight: Weight factor for CRI calculations
```

This design allows for:
- Clear categorization of source types
- Flexible weighting based on authority and trust
- Easy addition of new authorities without schema changes

### 2. Curated Lists & Collections

The `curated_lists` and `list_items` tables handle all types of lists:

**Official Lists** (Criterion Collection, AFI Top 100):
- High trust_score (8-10)
- authority_type: 'canonical'
- Strict validation and matching requirements

**Awards** (Oscars, Cannes):
- Separate tables for ceremonies, categories, and nominations
- Temporal tracking (year-based)
- Support for both film and person awards

**Studio/Distributor Collections** (A24, Neon):
- authority_type: 'critical' or 'commercial'
- Can track both curated and complete catalogs

### 3. User-Generated Content

Separate schema (`crowdsourced_data_schema`) for user-generated content:

**External User Profiles**:
- Track user credibility across platforms
- Calculate trust_score based on activity and engagement
- Identify influential curators

**User-Generated Lists**:
- Quality scoring (curation_score, spam_score)
- Engagement metrics for weighting
- Theme and genre detection

### 4. Data Quality & Sanitization

Multiple layers of quality control:

**Matching Confidence**:
- All movie references include match_confidence scores
- Original data preserved for debugging
- Multiple matching methods supported

**Validation Tracking**:
- `data_quality_issues` table for systematic issue tracking
- `content_moderation_flags` for spam/low-quality content
- Automated and manual validation workflows

**Import Jobs**:
- Full audit trail of all imports
- Success/failure metrics
- Ability to replay or rollback imports

### 5. Composite Scoring Support

The schema supports sophisticated CRI calculations:

**Weight Adjustments**:
- `authority_weight_adjustments` for context-specific weights
- Genre, decade, or country-specific authority weights
- Temporal weight decay options

**Quality Scores**:
- `crowdsource_quality_scores` for aggregated metrics
- Normalized scores and percentile rankings
- Multiple metric types per movie

## Key Design Decisions

### 1. Separation of Concerns

**Authoritative vs Crowdsourced**:
- Separate migration files and table structures
- Different validation rules and quality thresholds
- Independent weight calculations

### 2. Flexibility & Extensibility

**JSONB Fields**:
- `metadata`, `raw_data`, `source_data` for platform-specific data
- No schema changes needed for new data fields
- Preserves original data for reprocessing

**Polymorphic Design**:
- Single `list_items` table for all list types
- `external_ratings` supports any rating source
- Unified import job tracking

### 3. Temporal Tracking

**Version History**:
- Annual editions of lists (AFI updates)
- Award ceremony years
- Snapshot-based social metrics

**Trend Analysis**:
- `social_metrics_snapshots` for time-series data
- Distribution windows for availability tracking
- Influence evolution over time

### 4. Performance Optimization

**Indexes**:
- Composite indexes for common queries
- Partial indexes for filtered queries
- Foreign key indexes for joins

**Aggregation Tables**:
- Pre-calculated quality scores
- Daily/weekly social metrics
- Reduces real-time calculation load

## Integration with CRI Algorithm

The schema supports all CRI scoring dimensions:

1. **Timelessness**: Track mentions and references over time
2. **Cultural Penetration**: Social media metrics, meme tracking
3. **Artistic Impact**: Awards, critical scores, influences
4. **Institutional Recognition**: Museum exhibitions, academic citations
5. **Public Reception**: User reviews, list inclusions, engagement

## Data Source Examples

### Canonical Authorities
- 1001 Movies You Must See Before You Die
- Sight & Sound Top 100
- National Film Registry

### Critical Institutions
- Metacritic (metascores)
- Rotten Tomatoes (Tomatometer, Audience Score)
- Film festival awards

### Scholarly Citations
- Academic papers (via DOI)
- University syllabi
- Film theory publications

### Creator Testimonies
- Director interviews (influence_tracking)
- Filmmaker curated lists
- Commentary tracks

### Influence Graph
- Wikipedia legacy sections
- "Influenced by" relationships
- Homages and references

### Crowdsourced Reception
- TMDB user lists
- Letterboxd reviews
- Reddit discussions

### Meme & Internet Culture
- KnowYourMeme entries
- Viral social media posts
- GIF usage tracking

### Awards & Retrospectives
- Major festival wins
- Museum retrospectives
- Restoration projects

## Future Considerations

1. **Machine Learning Integration**:
   - Schema supports feature extraction
   - Quality scores can train ML models
   - Pattern detection in user behavior

2. **Real-time Updates**:
   - Webhook support via import_jobs
   - Incremental sync capabilities
   - Change detection mechanisms

3. **Multi-language Support**:
   - Translation tables already included
   - Language-specific authority weights possible
   - Cultural context preservation

4. **API Integration**:
   - External source configuration stored
   - Rate limiting and quota tracking
   - Fallback strategies for failed sources