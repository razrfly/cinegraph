# 2024 Academy Awards (96th Oscars) - Database Baseline Analysis

## Issue Summary
This issue documents the expected baseline metrics for the 2024 Academy Awards ceremony to establish what our database should contain when properly populated. This will serve as our validation reference for debugging data import and storage issues.

## 2024 Academy Awards Overview
- **Ceremony Date:** March 10, 2024
- **Venue:** Dolby Theatre, Hollywood, Los Angeles
- **Host:** Jimmy Kimmel
- **Nominations Announced:** January 23, 2024

## Expected Database Metrics

### Core Statistics
- **Total Categories:** 23
- **Total Unique Films Nominated:** ~40-50 films (estimated based on overlap)
- **Total Individual Nominations:** ~115-120 (5 nominees × 23 categories, with some variation)
- **Total Winners:** 23 (one per category)

### Category Breakdown

#### People-Based Categories (11 categories, 44 total nominations)
These categories recognize individuals for their contributions:

**Acting (4 categories, 20 nominations total)**
- Best Actor in a Leading Role: 5 nominees
- Best Actress in a Leading Role: 5 nominees  
- Best Actor in a Supporting Role: 5 nominees
- Best Actress in a Supporting Role: 5 nominees

**Direction & Writing (3 categories, 12-15 nominations)**
- Best Director: 5 nominees
- Best Original Screenplay: 5 nominees
- Best Adapted Screenplay: 5 nominees

**Technical Individual Awards (4 categories, ~12-15 nominations)**
- Best Cinematography: 5 nominees
- Best Film Editing: 5 nominees
- Best Original Score: 5 nominees
- Best Original Song: 5 nominees (Note: May have multiple people per nomination)

#### Film-Based Categories (12 categories, ~56-60 nominations)
These categories recognize films as a whole or film-specific achievements:

**Best Picture:** 10 nominees (expanded category)

**Feature Films (3 categories, 15 nominations)**
- Best Animated Feature Film: 5 nominees
- Best International Feature Film: 5 nominees
- Best Documentary Feature Film: 5 nominees

**Short Films (3 categories, 15 nominations)**
- Best Documentary Short Film: 5 nominees
- Best Live Action Short Film: 5 nominees
- Best Animated Short Film: 5 nominees

**Technical Film Awards (5 categories, 25 nominations)**
- Best Sound: 5 nominees
- Best Production Design: 5 nominees
- Best Makeup and Hairstyling: 5 nominees
- Best Costume Design: 5 nominees
- Best Visual Effects: 5 nominees

### People Nominations Detail
For the 44 people-based nominations across 11 categories:
- **Acting Categories:** 20 unique person nominations (4 categories × 5 nominees)
- **Director:** 5 unique person nominations
- **Writing:** 10 unique person nominations (some films have multiple writers)
- **Technical Individual:** ~15-20 unique person nominations (accounting for collaborations)

**Total Expected People Nominations: 44-50** (accounting for multiple people per nomination in some categories)

### Key Films and Their Nominations
- **Oppenheimer:** 13 nominations (most nominated)
- **Poor Things:** 11 nominations
- **Killers of the Flower Moon:** 10 nominations
- **Barbie:** 8 nominations
- Other films with multiple nominations

## Data Validation Checklist

### Must-Have Data Points
- [ ] 23 categories total
- [ ] 10 Best Picture nominees (not 5)
- [ ] 5 nominees for each acting category (20 total acting nominations)
- [ ] 5 nominees for Director, Original Screenplay, Adapted Screenplay
- [ ] Winners marked for all 23 categories
- [ ] Proper person-to-film associations for individual awards
- [ ] Multiple person associations for collaborative categories (writers, songs, etc.)

### Common Data Issues to Check
1. **Best Picture Count:** Should be 10, not 5
2. **Person vs Film Categories:** Ensure proper differentiation
3. **Multiple People per Nomination:** Some categories have teams (writers, composers)
4. **Winner Flags:** Exactly 23 winners across all categories
5. **Duplicate Prevention:** Same person may be nominated in multiple categories

## Testing Queries

### Basic Validation
```sql
-- Total categories
SELECT COUNT(DISTINCT category_id) FROM nominations WHERE ceremony_year = 2024;
-- Expected: 23

-- Total nominations
SELECT COUNT(*) FROM nominations WHERE ceremony_year = 2024;
-- Expected: ~115-120

-- Winners count
SELECT COUNT(*) FROM nominations WHERE ceremony_year = 2024 AND won = true;
-- Expected: 23

-- Best Picture nominees
SELECT COUNT(*) FROM nominations 
WHERE ceremony_year = 2024 AND category_name = 'Best Picture';
-- Expected: 10

-- People nominations
SELECT COUNT(*) FROM nominations 
WHERE ceremony_year = 2024 AND category_tracks_person = true;
-- Expected: 44-50
```

## References
- [96th Academy Awards - Wikipedia](https://en.wikipedia.org/wiki/96th_Academy_Awards)
- [The 96th Academy Awards | 2024 - Oscars.org](https://www.oscars.org/oscars/ceremonies/2024)
- [2024 Oscar Nominations - Full List](https://www.cbsnews.com/news/oscars-nominations-2024-academy-awards-list/)

## Related Issues
- #197 - Academy Awards data import issues
- Festival data structure normalization
- Person-to-film association tracking

---
*This baseline analysis provides the expected data structure for the 2024 Academy Awards to validate our database import and storage functionality.*
