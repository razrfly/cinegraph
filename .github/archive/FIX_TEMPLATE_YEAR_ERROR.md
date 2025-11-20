# Fix: Template Year Field Error

## Problem
The predictions page was throwing a KeyError when trying to access `prediction.year`:
```
** (KeyError) key :year not found in: %{
  id: 22823,
  status: :future_prediction,
  title: "Family Time",
  release_date: "2023-11-10",
  prediction: %{likelihood_percentage: 0, score: 10.4}
}
```

## Root Cause
The cached prediction data structure uses `release_date` field, but the template was trying to access `prediction.year`.

## Solution
Updated the template to use the existing `extract_year` helper function:

```heex
<!-- Before -->
<%= prediction.year %>

<!-- After -->
<%= extract_year(prediction.release_date) %>
```

## File Modified
- `lib/cinegraph_web/live/predictions_live/index.html.heex` line 441

## Note
The template correctly uses `pattern.year` in the selected movie details section (line 896) because that data comes from a different source (`find_similar_historical_patterns`) which does include a `year` field.

## Verification
The app now compiles without errors and the predictions page should load without the KeyError.