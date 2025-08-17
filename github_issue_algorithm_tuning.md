# GitHub Issue: Fix Algorithm Tuning & Implement Multi-Profile Comparison

## Summary
The "Tune Algorithm" feature in the predictions view is broken and we need a way to compare all 5 weight profiles to determine which performs best overall and per decade.

## Current Problems

### 🐛 Bug: Tune Algorithm Feature Broken
When users try to:
1. Click "Tune Algorithm" 
2. Select a different weight profile from dropdown
3. Click "Recalculate Predictions"

**Result**: Error message "Invalid weight values. Please check your inputs"

**Root Cause**: Form parameter mismatch in `handle_event("update_weights", params, socket)` at `index.ex:154-163`

### 🚫 Missing Feature: Can't Compare Profiles
Currently:
- Only one profile can be tested at a time
- No way to see comparative performance
- Can't identify which profile works best for which decade
- Manual testing of each profile is tedious

## Available Weight Profiles
We have 5 profiles in the database:
1. **Balanced** - Equal weights across all criteria (default)
2. **Award Winner** - Emphasizes festival awards (45% awards)
3. **Critics Choice** - Prioritizes critical acclaim (50% ratings)
4. **Crowd Pleaser** - Focuses on popular opinion (40% ratings)
5. **Cult Classic** - Cultural impact focused (40% cultural)

## Proposed Solution

### Phase 1: Fix Immediate Bugs ✅
- [ ] Fix form parameter naming issue in weight tuner
- [ ] Fix profile dropdown selection handler
- [ ] Add proper error handling and validation
- [ ] Ensure weights sum to 100% validation

### Phase 2: Implement Profile Comparison 📊
- [ ] Add new section in Historical Validation view
- [ ] Pre-calculate validation for all 5 profiles
- [ ] Cache results for 1 hour (validation is more stable)
- [ ] Create comparison table showing:
  - Overall accuracy per profile
  - Per-decade performance
  - Best profile for each decade
  - Visual indicators (charts/colors)

### Phase 3: Enhanced Analysis 📈
- [ ] Statistical significance testing
- [ ] Identify profile strengths by era
- [ ] Recommendation engine for profile selection
- [ ] Export comparison data

## Technical Implementation

### Fix for Tune Algorithm (Priority 1)
```elixir
# Problem in index.ex:154-163
# Form sends params like {"popular_opinion" => "20", "critical_acclaim" => "20", ...}
# But might be missing or wrong format

# Fix: Add proper parameter extraction and validation
def handle_event("update_weights", params, socket) do
  # Add logging to debug actual params structure
  # Validate all required keys exist
  # Handle string to float conversion safely
  # Ensure sum equals 100%
end
```

### Caching Strategy
```elixir
# Cache key structure for all profiles
"validation:all_profiles:#{Date.utc_today()}"

# Cache individual profile validations
"validation:#{profile_name}:#{profile_hash}"

# TTL: 1 hour for validations (stable)
# TTL: 15 minutes for predictions (more dynamic)
```

### UI Mockup
```
Historical Validation
├── Overall Comparison Tab
│   ├── Table: Profile | Overall % | 1920s | 1930s | ... | 2020s
│   ├── Best Overall: [Profile Name] - XX%
│   └── Chart: Line graph showing each profile across decades
├── Decade Analysis Tab
│   ├── Dropdown: Select Decade
│   └── Table: Shows all 5 profiles for selected decade
└── Recommendations Tab
    ├── Best for Modern Films (2000s+): [Profile]
    ├── Best for Classic Films (pre-1980): [Profile]
    └── Most Consistent: [Profile]
```

## Acceptance Criteria

### Bug Fixes
- [ ] Can successfully change algorithm weights via UI
- [ ] Can switch between profiles without errors
- [ ] Proper validation messages shown
- [ ] Loading states work correctly

### New Features
- [ ] All 5 profiles shown in comparison view
- [ ] Results cached and load in <3 seconds
- [ ] Clear visual indicators of best performers
- [ ] Can identify best profile per decade
- [ ] Export functionality for analysis

### Performance
- [ ] Initial load from cache: <1 second
- [ ] Full recalculation: <10 seconds with progress indicator
- [ ] Memory usage stays under reasonable limits

## Benefits

1. **Data-Driven Decisions**: Choose the best algorithm based on evidence
2. **Historical Insights**: Understand how film selection criteria have evolved
3. **Better Predictions**: Use the most accurate profile for 2020s predictions
4. **Research Value**: Valuable data about film canon formation

## Testing Plan

1. **Unit Tests**
   - Parameter validation in update_weights
   - Cache key generation
   - Profile comparison calculations

2. **Integration Tests**
   - Profile switching flow
   - Cache invalidation
   - Comparison view rendering

3. **Performance Tests**
   - Load time with all profiles
   - Memory usage monitoring
   - Database query optimization

## Priority
**HIGH** - This directly impacts the accuracy and trustworthiness of our main feature

## Estimated Effort
- Bug fixes: 2-3 hours
- Comparison view: 4-6 hours
- Full implementation with testing: 8-10 hours

## Labels
- `bug` (for tune algorithm fix)
- `enhancement` (for comparison feature)
- `performance` (for caching improvements)
- `high-priority`
- `predictions`

## Related Issues
- Related to core prediction algorithm implementation
- Impacts 2020s movie predictions accuracy

## Screenshots/Evidence
Current error when trying to tune algorithm:
- Error message: "Invalid weight values. Please check your inputs"
- Location: `/predictions` page, after clicking "Tune Algorithm"

## Additional Context
The prediction algorithm is the core feature of the application. Having the ability to compare and optimize different weight profiles is crucial for:
1. Building trust in predictions
2. Understanding historical patterns
3. Improving future predictions
4. Academic/research applications