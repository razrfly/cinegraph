# Movie Page Enhancement Mockups

## 1. Visual Cast & Crew Section

### Current (Text-Only):
```
Cast (45)
─────────────────────────
Tom Hardy               ... Eddie Brock
Chiwetel Ejiofor       ... General Strickland  
Juno Temple            ... Dr. Payne
```

### Proposed (Visual Grid):
```
┌─────────────────────────────────────────────────────────────┐
│ CAST                                              View All → │
├─────────────────────────────────────────────────────────────┤
│  ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐  ┌────┐           │
│  │ 👤 │  │ 👤 │  │ 👤 │  │ 👤 │  │ 👤 │  │ 👤 │  →        │
│  └────┘  └────┘  └────┘  └────┘  └────┘  └────┘           │
│   Tom      Chiwetel  Juno     Rhys     Peggy    Stephen    │
│   Hardy    Ejiofor   Temple   Ifans    Lu       Graham     │
│   Eddie    General   Dr.      Martin   Mrs.     Detective  │
│   Brock    Strick.   Payne    Moon     Chen     Mulligan   │
└─────────────────────────────────────────────────────────────┘
```

## 2. Actor Connection Network Visualization

### Interactive Network Graph:
```
┌─────────────────────────────────────────────────────────────┐
│ COLLABORATION NETWORK                                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│                    [Tom Hardy]                               │
│                   /     |     \                              │
│                  3      5      2                             │
│                 /       |       \                            │
│         [Michelle]  [Woody]  [Riz Ahmed]                    │
│         Williams   Harrelson                                 │
│              \        /                                      │
│               2      4                                       │
│                \    /                                        │
│            [Naomie Harris]                                   │
│                                                              │
│  Legend:                                                     │
│  • Node size = Total films                                  │
│  • Line number = Films together                             │
│  • Click node to explore actor                              │
│  • Click line to see shared films                           │
└─────────────────────────────────────────────────────────────┘
```

## 3. Related Movies by Collaboration

### Grid View:
```
┌─────────────────────────────────────────────────────────────┐
│ RELATED BY COLLABORATION                           See All → │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │          │  │          │  │          │  │          │   │
│  │  POSTER  │  │  POSTER  │  │  POSTER  │  │  POSTER  │   │
│  │          │  │          │  │          │  │          │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
│   Mad Max:      The Dark     Inception     Venom         │
│   Fury Road     Knight                                     │
│                 Rises                                      │
│   🔗 Tom Hardy  🔗 Tom Hardy  🔗 Tom Hardy  🔗 Tom Hardy   │
│   🔗 Same Dir.  🔗 C. Nolan   & 2 actors    & M. Williams  │
│                                                            │
│   Score: 8.1    Score: 8.8    Score: 8.4    Score: 7.3    │
└─────────────────────────────────────────────────────────────┘
```

## 4. Enhanced Collaboration Tab

### Current:
```
Director-Actor Reunions
─────────────────────────
Ruben Fleischer & Tom Hardy - 2nd collaboration
```

### Proposed Timeline View:
```
┌─────────────────────────────────────────────────────────────┐
│ COLLABORATION TIMELINE: Ruben Fleischer & Tom Hardy         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  2018 ──────────────── 2021 ──────────────── 2024          │
│    │                     │                     │            │
│    ●                     ●                     ●            │
│  Venom               Venom: Let            Venom: The      │
│  Score: 7.3          There Be              Last Dance      │
│                      Carnage                Score: 6.5     │
│                      Score: 6.8                             │
│                                                              │
│  Collaboration Strength: ████████░░ (3 films)               │
│  Average Score Together: 6.9                                │
│  Box Office Together: $2.1B                                 │
└─────────────────────────────────────────────────────────────┘
```

## 5. Real Cinegraph Score Display

### Current (Dummy):
```
Cinegraph Score: 8.2
Popular Opinion: 7.5
Critical Acclaim: 8.0
[All movies show same scores]
```

### Proposed (Real Data):
```
┌─────────────────────────────────────────────────────────────┐
│ CINEGRAPH SCORE                                    ⓘ Info  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ██████████████████████████░░░░  7.3 / 10                  │
│                                                              │
│  Popular Opinion        ████████████████░░░░  7.8           │
│  (IMDb 7.5 • TMDb 8.1)                                      │
│                                                              │
│  Critical Acclaim       ███████████░░░░░░░░  5.5            │
│  (Metacritic 42 • RT 57%)                                   │
│                                                              │
│  Industry Recognition   ████░░░░░░░░░░░░░░░  2.0            │
│  (0 Oscar noms • 2 MTV Awards)                              │
│                                                              │
│  Cultural Impact        ██████████████░░░░░  7.0            │
│  (Box office success • Franchise)                           │
│                                                              │
│  People Quality         ████████████████░░░  8.0            │
│  (A-list cast • Proven director)                            │
│                                                              │
│  Collaboration Intel    ███████████████░░░░  7.5            │
│  (Strong repeat collaborations)                             │
│                                                              │
│  Calculated using: Balanced Profile                         │
└─────────────────────────────────────────────────────────────┘
```

## 6. Six Degrees Connection Path

### Interactive Path Finder:
```
┌─────────────────────────────────────────────────────────────┐
│ SIX DEGREES OF CINEMA                                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Find Connection Path:                                       │
│  ┌─────────────────┐           ┌─────────────────┐        │
│  │ Tom Hardy       │  ←────→   │ Search...      │         │
│  └─────────────────┘           └─────────────────┘        │
│                                                              │
│  Example Paths:                                             │
│                                                              │
│  Tom Hardy → Kevin Bacon (2 degrees)                        │
│  ─────────────────────────────────────                      │
│  Tom Hardy → "The Dark Knight Rises" → Gary Oldman →       │
│  "The Professional" → Kevin Bacon                           │
│                                                              │
│  Tom Hardy → Robert Downey Jr. (3 degrees)                  │
│  ─────────────────────────────────────────                  │
│  [Show Path]                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Priority

1. **Phase 1 (Immediate)**
   - Real Cinegraph scores from database
   - Visual cast display with images
   - Remove fake reviews

2. **Phase 2 (Next Sprint)**
   - Related movies by collaboration
   - Enhanced collaboration timeline
   - Six degrees path finder

3. **Phase 3 (Future)**
   - Interactive network visualization
   - Advanced filtering and exploration
   - Social features (if planned)