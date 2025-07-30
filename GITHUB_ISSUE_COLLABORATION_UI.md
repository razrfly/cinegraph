# Implement Collaboration UI Features

## Overview
With the collaboration backend infrastructure complete (#36, #37, #38), we need to implement UI features to showcase the powerful collaboration analysis capabilities. This issue outlines the UI components needed to expose these features to users.

## Current Backend Capabilities

We have the following functions available in our collaboration system:

### Core Functions
- `find_actor_director_movies/2` - Find all movies where specific actor & director worked together
- `find_similar_collaborations/2` - Find similar actor-director pairs based on metrics
- `find_director_frequent_actors/2` - Get directors' most frequent collaborators
- `find_trending_collaborations/2` - Detect hot collaboration trends
- `get_person_collaboration_trends/1` - Career collaboration patterns over time

### Six Degrees Functions
- `PathFinder.find_shortest_path/2` - Find connection between two people
- `PathFinder.find_path_with_movies/2` - Get path with movie connections

## Proposed UI Features

### 1. Person Profile Enhancements

**Location**: `/people/:id` (PersonLive.Show)

#### A. Collaboration Statistics Widget
```
┌─────────────────────────────────────────────┐
│ Collaboration Network                        │
├─────────────────────────────────────────────┤
│ Total Collaborators: 156                    │
│ Unique Directors: 23                        │
│ Recurring Partners: 12                      │
│ Peak Collaboration Year: 2019               │
└─────────────────────────────────────────────┘
```

#### B. Enhanced Frequent Collaborators Section
Current implementation shows basic collaborators. Enhance with:
- Collaboration strength indicator (1-5 films = weak, 6-10 = strong, 11+ = very strong)
- Filter by role type (actors, directors, producers)
- "View Full Network" link to dedicated page
- Mini sparkline showing collaboration timeline

#### C. Six Degrees Game Widget
```
┌─────────────────────────────────────────────┐
│ Six Degrees Challenge                       │
├─────────────────────────────────────────────┤
│ Connect to: [Search for person...]          │
│ [Find Path] button                          │
│                                             │
│ Recent Connections:                         │
│ • Tom Hanks (3 degrees)                     │
│ • Meryl Streep (2 degrees)                 │
└─────────────────────────────────────────────┘
```

### 2. Movie Profile Enhancements

**Location**: `/movies/:id` (MovieLive.Show)

#### A. Key Collaborations Highlight
Show notable repeat collaborations in this film:
```
┌─────────────────────────────────────────────┐
│ Notable Collaborations                       │
├─────────────────────────────────────────────┤
│ 🎬 Director-Actor Reunions:                 │
│ • Christopher Nolan & Christian Bale        │
│   (3rd collaboration)                       │
│                                             │
│ 🎭 Actor Partnerships:                       │
│ • Brad Pitt & George Clooney               │
│   (4th film together)                       │
└─────────────────────────────────────────────┘
```

### 3. New Dedicated Collaboration Pages

#### A. Collaboration Explorer (`/collaborations`)
A new LiveView page with:

```
┌─────────────────────────────────────────────┐
│ 🔍 Explore Collaborations                   │
├─────────────────────────────────────────────┤
│ Search Collaborations:                      │
│ Actor: [_____] Director: [_____] [Search]   │
│                                             │
│ Trending Collaborations (2024-2025):        │
│ ┌─────────────────────────────────────┐    │
│ │ • Actor & Director (5 films)        │    │
│ │   Avg Rating: 8.2 | $2.3B revenue   │    │
│ │ • Actor & Actor (3 films)           │    │
│ │   Latest: Movie Title (2025)        │    │
│ └─────────────────────────────────────┘    │
│                                             │
│ Discover Similar Collaborations:            │
│ Based on: [Select a collaboration...]       │
└─────────────────────────────────────────────┘
```

#### B. Six Degrees Game (`/six-degrees`)
Full interactive game interface:

```
┌─────────────────────────────────────────────┐
│ 🎮 Six Degrees of Separation                │
├─────────────────────────────────────────────┤
│ From: [Search person...] 🎭                 │
│ To:   [Search person...] 🎯                 │
│                                             │
│ [Find Connection!]                          │
│                                             │
│ ┌─────────────────────────────────────┐    │
│ │ Path Found (3 degrees):              │    │
│ │                                      │    │
│ │ Person A ─[Movie 1]→ Person B       │    │
│ │    ↓                                 │    │
│ │ [Movie 2]                           │    │
│ │    ↓                                 │    │
│ │ Person C ─[Movie 3]→ Person D       │    │
│ └─────────────────────────────────────┘    │
│                                             │
│ Hall of Fame:                               │
│ • Shortest path found: 2 degrees            │
│ • Most connected: Actor Name (avg 2.3)     │
└─────────────────────────────────────────────┘
```

#### C. Director Analysis (`/directors/:id/collaborations`)
Dedicated page for director collaboration patterns:

```
┌─────────────────────────────────────────────┐
│ Director Collaboration Analysis             │
├─────────────────────────────────────────────┤
│ Favorite Actors:                            │
│ ┌─────────────────────────────────────┐    │
│ │ 1. Actor Name (8 films)             │    │
│ │    First: 2010 | Latest: 2024       │    │
│ │    Avg Rating: 7.8 | Total: $3.2B   │    │
│ │ 2. Actor Name (5 films)             │    │
│ └─────────────────────────────────────┘    │
│                                             │
│ Collaboration Timeline:                     │
│ [Interactive chart showing collaborations   │
│  over years with different actors]         │
│                                             │
│ Success Metrics by Collaboration:           │
│ [Bar chart of ratings/revenue by partner]  │
└─────────────────────────────────────────────┘
```

### 4. Search Enhancement

Add collaboration filters to existing movie/person search:
- "Has worked with [person]"
- "Minimum collaborations: [number]"
- "Collaboration type: [actor-actor/actor-director/etc]"

## Implementation Plan

### Phase 1: Person Profile Enhancements (Week 1)
1. Add collaboration statistics to person show page
2. Enhance frequent collaborators section
3. Add basic six degrees widget

### Phase 2: Movie Profile Enhancements (Week 1)
1. Add key collaborations highlight box
2. Show collaboration counts for cast/crew

### Phase 3: New Collaboration Explorer (Week 2)
1. Create new LiveView at `/collaborations`
2. Implement search functionality
3. Add trending collaborations
4. Build similar collaborations feature

### Phase 4: Six Degrees Game (Week 2)
1. Create dedicated game page
2. Implement path visualization
3. Add game statistics/leaderboard

### Phase 5: Director Analysis Page (Week 3)
1. Create director collaboration analysis page
2. Add timeline visualization
3. Implement success metrics charts

## Technical Implementation Details

### LiveView Components Needed

1. **CollaborationStats** - Reusable component for stats display
2. **CollaboratorList** - Enhanced list with filters and sorting
3. **PathVisualization** - For six degrees path display
4. **CollaborationSearch** - Dual person search component
5. **TrendingCollaborations** - Auto-updating trending list

### New Routes
```elixir
# In router.ex
live "/collaborations", CollaborationLive.Index, :index
live "/six-degrees", SixDegreesLive.Index, :index
live "/directors/:id/collaborations", DirectorLive.Collaborations, :show
```

### LiveView Modules
```elixir
# New files needed:
- lib/cinegraph_web/live/collaboration_live/index.ex
- lib/cinegraph_web/live/collaboration_live/index.html.heex
- lib/cinegraph_web/live/six_degrees_live/index.ex
- lib/cinegraph_web/live/six_degrees_live/index.html.heex
- lib/cinegraph_web/live/director_live/collaborations.ex
- lib/cinegraph_web/live/director_live/collaborations.html.heex
```

### Components to Create
```elixir
# In lib/cinegraph_web/components/
- collaboration_components.ex
  - collaboration_stats/1
  - collaborator_card/1
  - path_node/1
  - trending_item/1
```

## UI/UX Guidelines

1. **Consistent Design**: Match existing Tailwind CSS patterns
2. **Responsive**: Mobile-first approach
3. **Performance**: Use Phoenix LiveView's real-time updates
4. **Accessibility**: ARIA labels, keyboard navigation
5. **Loading States**: Skeleton screens for data fetching
6. **Error Handling**: Graceful fallbacks for no data

## Success Metrics

1. All collaboration functions exposed through UI
2. Page load times <500ms
3. Mobile responsive on all screens
4. Interactive elements provide immediate feedback
5. Search and filtering work seamlessly

## Testing Requirements

1. Unit tests for new LiveView modules
2. Integration tests for collaboration searches
3. Performance tests for six degrees algorithm
4. UI tests for interactive components
5. Mobile responsiveness tests

## Dependencies

- Backend collaboration system (complete)
- Existing Person and Movie LiveViews
- Phoenix LiveView
- Tailwind CSS
- Optional: Chart.js for visualizations

## Notes

- Start with enhancing existing pages before adding new ones
- Consider adding caching for expensive queries
- The six degrees game could become a viral feature
- Director analysis page could be expanded to other roles later