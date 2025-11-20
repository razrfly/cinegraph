# Cinegraph Filtering System Analysis

## Current State Summary

The filtering system has been analyzed and documented in [GitHub Issue #314](https://github.com/razrfly/cinegraph/issues/314). 

## Key Problems Identified

### 1. **Fragmented Active Filter Display**
- **Basic filters**: Show in one "Active Filters" section
- **Advanced filters**: Show in separate "Active Advanced Filters" section  
- **People search**: Not shown in any active filters display
- **Result**: Users cannot see all active filters in one unified view

### 2. **State Synchronization Issues**
- URL correctly contains all filter parameters
- UI only shows subset of active filters
- People search component maintains internal state but doesn't sync with main filter display
- When combining multiple filter types, only some appear as "active" in the UI

### 3. **Inconsistent Filter Removal**
- Basic filters: Removable via "Active Filters" badges
- Advanced filters: Removable via separate "Active Advanced Filters" badges
- People search: Only removable within the component itself
- No unified "clear all" functionality

### 4. **URL Parameter Format Inconsistencies**
- Basic filters: Simple format (`?genres=1,2&countries=3`)
- People search: Nested format (`?people_search[people_ids]=1,2,3`)
- Advanced filters: Mixed formats depending on type

## Implementation Details

### Current Filter Flow

1. **User applies filter** → 
2. **`handle_event("apply_filters")` or specific handlers** →
3. **`build_filter_params(socket)`** →
4. **`push_patch` with new URL** →
5. **`handle_params`** →
6. **`assign_filter_params`** →
7. **`load_paginated_movies`**

### Filter State Structure

```elixir
# socket.assigns.filters structure:
%{
  # Basic filters
  genres: ["1", "2"],
  countries: ["3", "4"],
  languages: ["en", "es"],
  # ... other basic filters
  
  # People search (special nested format)
  people_search: %{
    "people_ids" => "1,2,3",
    "role_filter" => "any"  # optional
  },
  
  # Advanced filters
  award_status: "won",
  festival_id: "1",
  # ... other advanced filters
}
```

### Current Active Filter Functions

**Basic Filters (`index.ex`):**
```elixir
def has_active_basic_filters(filters)
def get_active_basic_filters(filters) 
def format_basic_filter_label(key)
def format_basic_filter_value(key, value, assigns)
```

**Advanced Filters (`advanced_filters.ex`):**
```elixir  
def has_active_advanced_filters(filters)
def get_active_advanced_filters(filters)
def format_filter_label(key)
def format_filter_value(key, value)
```

## Proposed Solution Architecture

### 1. Unified Filter Detection
```elixir
def has_any_active_filters(filters) do
  has_active_basic_filters(filters) || 
  AdvancedFilters.has_active_advanced_filters(filters) ||
  has_active_people_search(filters)
end
```

### 2. Normalized Filter Structure
```elixir
def get_all_active_filters(filters) do
  # Returns list of %{key, type, label, display_value, removable}
end
```

### 3. Unified Removal System
```elixir
def handle_event("remove_filter", %{"filter" => key, "filter_type" => type}, socket)
def handle_event("clear_all_filters", _params, socket)
```

### 4. Single Active Filters Display
Replace both existing displays with one unified component that shows all active filters with consistent styling and removal functionality.

## Files Requiring Changes

### Core Logic
- `lib/cinegraph_web/live/movie_live/index.ex` - Main filtering logic
- `lib/cinegraph_web/live/movie_live/advanced_filters.ex` - Advanced filter helpers

### Templates  
- `lib/cinegraph_web/live/movie_live/index.html.heex` - Unified active filters display

### Components
- `lib/cinegraph_web/components/person_autocomplete.ex` - Better integration

## Implementation Priority

1. **High Priority**: Unified active filter display (fixes main UX issue)
2. **Medium Priority**: Unified filter removal (improves consistency)  
3. **Low Priority**: URL parameter standardization (internal cleanup)

## Success Criteria

- [ ] Single "Active Filters" section shows ALL active filters
- [ ] People search selections appear in active filters
- [ ] All filters can be removed via consistent badge interface
- [ ] URL state matches UI state in all scenarios
- [ ] "Clear All" button works for all filter types
- [ ] Backwards compatibility with existing URLs maintained

---

**Next Steps**: Implement the unified active filter system as outlined in GitHub Issue #314.