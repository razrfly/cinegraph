# 🎬 CineGraph

CineGraph is an AI-powered Elixir/Phoenix project to measure the **cultural relevance of films**.

The system aims to build a reproducible, data-driven **Cultural Relevance Index (CRI)** that scores films based on a combination of canonical sources, public discourse, critical acclaim, cultural penetration (memes, quotes), artistic influence, and awards.

Our goal:
✅ Mimic and backtest against expert-curated lists like *1001 Movies You Must See Before You Die*  
✅ Gradually improve accuracy by integrating more external sources  
✅ Offer a dynamic, scalable ranking of films by lasting impact — beyond just popularity or box office.

---

## 🧭 How CRI Works

### Scoring Dimensions

We evaluate cultural relevance across five key dimensions:

| Dimension | What We Measure |
|-----------|-----------------|
| **Timelessness** | How long and consistently a film remains discussed, watched, and relevant |
| **Cultural Penetration** | How deeply the film embeds into culture (memes, references, quotes) |
| **Artistic Impact** | Innovation and influence on the craft and other creators |
| **Institutional Recognition** | Formal acclaim, preservation efforts, retrospective attention |
| **Public Reception** | Audience reception across time, beyond just critics |

### Data Sources

CineGraph combines signals from eight major categories:

1. **Canonical Authorities** - Expert-curated lists (1001 Movies, Sight & Sound, Criterion)
2. **Critical Consensus** - Aggregated reviews (Metacritic, Rotten Tomatoes)
3. **Academic Citations** - Scholarly references (Google Scholar, JSTOR)
4. **Creator Influence** - Director testimonies and homages
5. **Cultural Footprint** - Memes, GIFs, quotes in popular culture
6. **Public Opinion** - IMDb, Letterboxd, Reddit discussions
7. **Awards & Honors** - Oscars, Cannes, preservation status
8. **Influence Networks** - Film-to-film legacy connections

### Backtesting Methodology

To ensure our algorithm captures true cultural relevance:

1. Import the "1001 Movies You Must See Before You Die" list as ground truth
2. Collect comprehensive metrics for each film across all data sources
3. Train scoring weights to maximize overlap with expert consensus
4. Evaluate precision (how many top picks match) and recall (coverage of the list)
5. Continuously refine based on new data and emerging cultural patterns

---

## 🌟 Key Features

- **Elixir Phoenix backend** with PostgreSQL
- **LiveView + Tailwind CSS** frontend
- **TMDb API integration** for baseline film data
- **Oban background jobs** for safe, rate-limited ingestion
- Future integration of:
  - Canonical authority lists (Sight & Sound, Criterion, National Film Registry)
  - Scholarly citations (Google Scholar, JSTOR)
  - Public discourse (Reddit, Letterboxd, Google Trends)
  - Meme and quote tracking (KnowYourMeme, Giphy)
  - Awards and retrospectives (Oscars, Cannes, BFI)

---

## 🛠️ Setup

### Prerequisites

- Elixir & Erlang
- PostgreSQL (we use Supabase local development)
- Node.js
- TMDb API key (free at https://www.themoviedb.org/settings/api)
- OMDb API key (free at http://www.omdbapi.com/apikey.aspx)

### Environment Setup

Create a `.env` file in the project root:

```bash
# Required API keys
TMDB_API_KEY=your_tmdb_api_key_here
OMDB_API_KEY=your_omdb_api_key_here

# Database URL (for Supabase local development)
SUPABASE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
```

### Install

```bash
# Clone and set up
git clone https://github.com/yourname/cinegraph.git
cd cinegraph

# Install Elixir deps
mix deps.get

# Install JS deps
cd assets && npm install && cd ..

# Create database
mix ecto.create

# Run migrations
mix ecto.migrate
```

### Database Population

CineGraph requires movie data to function properly. We use a modular import system that allows you to drop and re-import data multiple times during development as we iterate on the data model.

#### Quick Start (40 movies)
```bash
# Import 2 pages (40 movies) with all associations
./scripts/import_with_env.sh --pages 2
```

#### Standard Import (200 movies)
```bash
# Import 10 pages (200 movies) - recommended for development
./scripts/import_with_env.sh --pages 10
```

#### Complete Reset and Import
```bash
# Drop database, recreate, and import 200 movies
./scripts/import_with_env.sh --reset --pages 10

# The --reset flag performs:
# 1. mix ecto.drop (removes the database)
# 2. mix ecto.create (creates fresh database)
# 3. mix ecto.migrate (runs all migrations)
# 4. Imports the specified number of pages
```

#### Import Specific Movies
```bash
# Import specific movies by TMDb ID
./scripts/import_with_env.sh --ids 550,278,238

# Import specific movies with selected APIs only
./scripts/import_with_env.sh --ids 550,278,238 --apis tmdb
```

#### Modular API Import (when Oban is available)
```bash
# Import using only TMDb data
./scripts/import_with_env.sh --pages 5 --apis tmdb

# Import using both TMDb and OMDb
./scripts/import_with_env.sh --pages 5 --apis tmdb,omdb

# Queue imports as background jobs instead of immediate processing
./scripts/import_with_env.sh --pages 5 --queue

# Combine options for maximum control
./scripts/import_with_env.sh --reset --pages 10 --apis tmdb,omdb --queue --verbose
```

#### Enrich Existing Data
```bash
# Add OMDb ratings to existing movies
./scripts/enrich_with_omdb.sh

# Or use the mix task directly for specific enrichment
mix import_movies --enrich --api omdb
mix import_movies --enrich --api tmdb --queue
```

#### Additional Options
```bash
# Fresh start - clear all data first (without dropping database)
./scripts/import_with_env.sh --fresh --pages 10

# Show detailed progress during import
./scripts/import_with_env.sh --pages 10 --verbose
```

### Import Process Details

The import process uses a comprehensive, modular approach:

1. **Data Sources**:
   - **TMDb Data**: Movies, cast, crew, keywords, videos, release dates, production companies
   - **OMDb Data**: IMDb ratings, Rotten Tomatoes scores, Metacritic scores, box office data

2. **Modular System Features**:
   - Selective API usage (import from specific sources)
   - Queue-based processing with Oban (when available)
   - Progress tracking with `--verbose` flag
   - Automatic retry logic for failed imports

3. **Database Reset Strategy**:
   - We frequently drop and re-import during development
   - The `--reset` flag handles the complete cycle
   - Data is cleared in proper order respecting foreign keys
   - All associations are properly maintained

**Time Estimates**:
- 2 pages (40 movies): ~2-3 minutes
- 10 pages (200 movies): ~10-15 minutes
- 25 pages (500 movies): ~25-35 minutes
- With `--queue`: Initial queueing takes seconds, processing happens in background

**Important Notes**:
- OMDb has a free tier limit of 1,000 requests/day
- The import includes a 1-second delay between OMDb requests
- TMDb allows 40 requests/10 seconds
- When using `--queue`, jobs are processed by Oban workers with rate limiting

### Start Server

```bash
# Start Phoenix server with environment variables
./start.sh
```

Now you can visit [`localhost:4001`](http://localhost:4001) from your browser.

**Note**: The application runs on port 4001 by default to avoid conflicts with other Phoenix apps.

---

## 📚 External Data Sources & Documentation

### Primary Film Database APIs

#### TMDb (The Movie Database)
- **API Documentation**: [https://developer.themoviedb.org/docs/getting-started](https://developer.themoviedb.org/docs/getting-started)
- **API Reference**: [https://developer.themoviedb.org/reference/intro/getting-started](https://developer.themoviedb.org/reference/intro/getting-started)
- **Features**: Comprehensive movie/TV data, images, cast/crew, ratings
- **Access**: Free tier available, API key required
- **Rate Limits**: 40 requests/10 seconds

#### Letterboxd
- **API Documentation**: [https://api-docs.letterboxd.com/](https://api-docs.letterboxd.com/)
- **API Beta Info**: [https://letterboxd.com/api-beta/](https://letterboxd.com/api-beta/)
- **Access**: By request only (email: api@letterboxd.com)
- **Note**: Currently not granting access for data analysis or recommendation projects
- **Authentication**: OAuth2 (Client Credentials or Authorization Code flows)

#### IMDb
- **Official API**: Available via AWS Data Exchange (starting at $150,000/year)
- **Dataset Files**: [https://datasets.imdbws.com/](https://datasets.imdbws.com/) (free for non-commercial use)
- **Alternatives**:
  - **OMDb API**: [https://www.omdbapi.com/](https://www.omdbapi.com/) (includes IMDb data)
  - TMDb also provides IMDb IDs for cross-referencing

#### Rotten Tomatoes
- **Access**: Private API, enterprise only (starting at $60,000/year)
- **Business Inquiries**: Submit via their Business Proposal Form
- **Alternative**: OMDb API includes Rotten Tomatoes ratings

### Canonical Authority Sources

#### Sight & Sound Greatest Films Poll
- **Official Results**: [https://www.bfi.org.uk/sight-and-sound/greatest-films-all-time](https://www.bfi.org.uk/sight-and-sound/greatest-films-all-time)
- **2022 Poll Data**: [https://github.com/serve-and-volley/sight-and-sound-poll-data](https://github.com/serve-and-volley/sight-and-sound-poll-data)
- **Structured Data**: [Google Sheets](https://docs.google.com/spreadsheets/d/1tZPZEd-ZxjzKlBy7DxLfV6goIquxl-r8oGOj_xIWZ5A/edit?usp=sharing)
- **Updates**: Every 10 years (latest: 2022)

#### Criterion Collection
- **Website**: [https://www.criterion.com/](https://www.criterion.com/)
- **Note**: No official API; web scraping may be required

#### National Film Registry (Library of Congress)
- **Official List**: [https://www.loc.gov/programs/national-film-preservation-board/film-registry/](https://www.loc.gov/programs/national-film-preservation-board/film-registry/)
- **Data Format**: Available as structured lists

### Academic & Research Sources

#### Google Scholar
- **No Official API**: Google Scholar doesn't offer public API access
- **Third-party Options**:
  - **SerpApi**: [https://serpapi.com/google-scholar-api](https://serpapi.com/google-scholar-api) (paid with free tier)
  - **Scholarly (Python)**: [https://pypi.org/project/scholarly/](https://pypi.org/project/scholarly/) (free but rate-limited)
- **Film Metrics**: [https://scholar.google.com/citations?hl=en&view_op=top_venues&vq=hum_film](https://scholar.google.com/citations?hl=en&view_op=top_venues&vq=hum_film)

#### JSTOR
- **API Info**: [https://www.jstor.org/platform/jstor/about/jstor-api](https://www.jstor.org/platform/jstor/about/jstor-api)
- **Access**: Institutional or individual subscription required

### Social & Cultural Data

#### Reddit
- **API Documentation**: [https://www.reddit.com/dev/api/](https://www.reddit.com/dev/api/)
- **Python Wrapper (PRAW)**: [https://praw.readthedocs.io/](https://praw.readthedocs.io/)

#### Google Trends
- **Unofficial API (pytrends)**: [https://pypi.org/project/pytrends/](https://pypi.org/project/pytrends/)
- **Official Interface**: [https://trends.google.com/](https://trends.google.com/)

#### Know Your Meme
- **Website**: [https://knowyourmeme.com/](https://knowyourmeme.com/)
- **Note**: No official API; consider web scraping

#### Giphy
- **API Documentation**: [https://developers.giphy.com/docs/api/](https://developers.giphy.com/docs/api/)
- **Access**: Free with API key

### Awards & Festival Data

#### Academy Awards (Oscars)
- **Official Database**: [https://awardsdatabase.oscars.org/](https://awardsdatabase.oscars.org/)
- **Note**: No API; structured data available for scraping

#### Cannes Film Festival
- **Official Archive**: [https://www.festival-cannes.com/en/archives](https://www.festival-cannes.com/en/archives)

#### Other Major Awards
- **Golden Globes**: [https://www.goldenglobes.com/](https://www.goldenglobes.com/)
- **BAFTA**: [https://www.bafta.org/](https://www.bafta.org/)
- **Venice Film Festival**: [https://www.labiennale.org/en/cinema](https://www.labiennale.org/en/cinema)

---

## 🚀 Development Roadmap

### Phase 1: Foundation & Data Ingestion
- Set up Phoenix/Elixir application with PostgreSQL
- Design and implement movies schema with JSONB storage
- TMDb API integration with Oban for rate-limited ingestion
- Import initial 5,000+ movies dataset

### Phase 2: Canonical Sources & Backtesting
- Import "1001 Movies You Must See Before You Die" list
- Ingest Sight & Sound, Criterion Collection, National Film Registry
- Build initial CRI scoring algorithm
- Implement backtesting framework to validate against expert lists

### Phase 3: Extended Data Sources
- Add critical aggregators (Metacritic, Rotten Tomatoes via OMDb)
- Integrate academic citations (Google Scholar alternatives)
- Implement social signals (Reddit, Letterboxd when available)
- Add awards and retrospectives data

### Phase 4: Cultural Impact Metrics
- Meme and GIF tracking (Giphy, Know Your Meme)
- Quote and reference analysis
- Build influence graph between films
- YouTube and social media discourse analysis

### Phase 5: Production & Refinement
- Machine learning optimization of scoring weights
- Build public API for CRI scores
- Create visualization dashboards
- Implement continuous score updates and monitoring

---

## 💡 What Makes CineGraph Unique

Unlike traditional film rating systems that focus on immediate popularity or box office success, CineGraph:

- **Measures lasting impact** rather than momentary success
- **Combines objective data** from multiple sources rather than relying on single metrics
- **Validates against expert consensus** through rigorous backtesting
- **Captures cultural penetration** through memes, quotes, and references
- **Tracks artistic influence** through creator testimonies and film-to-film connections
- **Evolves continuously** as new cultural patterns emerge

The result is a living, data-driven understanding of which films truly matter across generations.

---

## 📄 License

[Add your license information here]

---

## 🤝 Contributing

[Add contribution guidelines here]