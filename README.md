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

1. Copy the example environment file:

```bash
cp .env.example .env
```

2. Edit `.env` and add your API keys:
   - Get TMDB API key from <https://www.themoviedb.org/settings/api>
   - Get OMDb API key from <http://www.omdbapi.com/apikey.aspx>
   - Use default Supabase values for local development

The `.env` file will contain:

```bash
# Supabase Configuration
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=your_supabase_anon_key_here
SUPABASE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres

# API Keys
TMDB_API_KEY=your_tmdb_api_key_here
OMDB_API_KEY=your_omdb_api_key_here
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

CineGraph uses an **Oban-based background job system** for importing movie data. This provides rate-limited, resumable, and parallelized imports from multiple data sources.

#### Quick Start Import

```bash
# 1. Ensure your .env file has API keys configured (see Environment Setup above)

# 2. Start the Phoenix server with environment variables
./start.sh

# 3. Visit the import dashboard
open http://localhost:4001/imports

# 4. Click "Import Popular Movies" to start with ~2,000 highly-rated films
```

#### Import Options

| Import Type | Movies | Time | Description |
|------------|--------|------|-------------|
| **Popular Movies** | ~2,000 | 20-30 min | Top-rated movies with 100+ votes |
| **Daily Update** | 50-200 | 5-10 min | Movies from last 7 days |
| **By Decade** | 2k-5k | 2-4 hrs | All movies from a decade |
| **Full Catalog** | 900k+ | 5-7 days | Complete TMDb database |

#### 📚 Comprehensive Import Guide

For detailed instructions, troubleshooting, and advanced usage, see our **[Import Guide](IMPORT_GUIDE.md)**.

The guide covers:
- Environment setup and API keys
- All import methods and options
- Import process flow and architecture
- Real-time progress monitoring
- Troubleshooting common issues
- API rate limits and best practices
- Advanced filtering and custom imports
- Example import scenarios

#### Import via IEx Console

##### Option 1: Import Popular Movies (Recommended)

```elixir
# Import top-rated popular movies (about 2,000-5,000 movies)
{:ok, progress} = Cinegraph.Imports.TMDbImporter.start_popular_import(max_pages: 200)
```

##### Option 2: Import by Decade

Import decade by decade to avoid overwhelming the system:

```elixir
# Import each decade separately
{:ok, p1} = Cinegraph.Imports.TMDbImporter.start_decade_import(2020)  # 2020s
{:ok, p2} = Cinegraph.Imports.TMDbImporter.start_decade_import(2010)  # 2010s
{:ok, p3} = Cinegraph.Imports.TMDbImporter.start_decade_import(2000)  # 2000s
{:ok, p4} = Cinegraph.Imports.TMDbImporter.start_decade_import(1990)  # 1990s
# ... continue with earlier decades as needed
```

##### Option 3: Full Import (Use with Caution)

This will attempt to import the entire TMDb database (900,000+ movies):

```elixir
# Full import - will take 5-7 days to complete!
{:ok, progress} = Cinegraph.Imports.TMDbImporter.start_full_import(max_pages: 500)
```

##### Option 4: Via the Dashboard (Easiest)

Just use the web interface:

1. Visit http://localhost:4001/imports
2. Click "Import Popular Movies" to start with the most popular
3. Or use "Import by Decade" section to import specific decades

##### Monitor Progress

Watch the import progress at http://localhost:4001/imports or check in IEx:

```elixir
# Check import status
Cinegraph.Imports.TMDbImporter.get_import_status()

# Get current movie count
Cinegraph.Repo.aggregate(Cinegraph.Movies.Movie, :count)
```

##### Recommendations

1. **Start with Popular Movies** - Gets you 2,000-5,000 highly rated films
2. **Then do Recent Decades** - 2020s, 2010s, 2000s have the most relevant content
3. **Skip Full Import** unless you really need all 900k+ movies

The popular movies import should take about 2-3 hours and give you a solid database to work with. The full import would take 5-7 days and might not be necessary for most use cases.

For development and testing, use the direct import scripts:

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

### Importing Oscar Data

Import Oscar ceremony data and create/update all nominated movies using Oban job queue for reliable, rate-limited processing.

#### Primary Import Functions (Recommended)

```elixir
# Import Oscar ceremony for specific year
Cinegraph.Cultural.import_oscar_year(2024)
# Returns: {:ok, %{ceremony_id: 12, year: 2024, job_id: 1234, status: :queued}}

# Import multiple years (parallel processing via Oban)
Cinegraph.Cultural.import_oscar_years(2020..2024)
# Returns: {:ok, %{years: 2020..2024, job_count: 5, status: :queued}}

# Import all available years (2016-2024)
Cinegraph.Cultural.import_all_oscar_years()

# Sequential processing (slower but immediate feedback)
Cinegraph.Cultural.import_oscar_years(2020..2024, async: false)
```

#### Monitor Import Progress

```elixir
# Check Oscar import job status
Cinegraph.Cultural.get_oscar_import_status()
# Returns: %{running_jobs: 2, queued_jobs: 3, completed_jobs: 5, failed_jobs: 0}

# Monitor via Oban dashboard
# Visit: http://localhost:4001/dev/oban
```

#### Legacy Mix Tasks (Available but not recommended)

```bash
# Import a single year
mix import_oscars --year 2024

# Import a range of years
mix import_oscars --years 2020-2024

# Import all available years (2016-2024)
mix import_oscars --all
```

#### Oscar Import Process

The Oscar import system uses a comprehensive job pipeline:

1. **OscarDiscoveryWorker**: Processes ceremony data and queues movie creation jobs
2. **TMDbDetailsWorker**: Handles IMDb→TMDb lookup and comprehensive movie import
3. **OMDbEnrichmentWorker**: Adds external ratings and metadata
4. **CollaborationWorker**: Builds cast/crew collaboration networks

**Features**:
- **Race condition handling**: Prevents duplicate movie creation during concurrent processing
- **Automatic retry logic**: Failed API calls are retried with exponential backoff
- **Rate limiting**: Respects TMDb and OMDb API rate limits
- **Progress monitoring**: Real-time job status via Oban dashboard
- **Data integrity**: All foreign key relationships properly maintained

**Integration with Existing Data**:
- Oscar import safely checks for existing movies before creating
- Updates are additive (only adds award data)
- Uses same TMDb data structure as regular imports
- Can be run alongside other import processes

**Time Estimates**:
- Single year: 3-5 minutes (queued processing)
- All years (2016-2024): 30-45 minutes (parallel processing)
- Zero job failures after comprehensive race condition fixes

### Start Server

```bash
# Start Phoenix server with environment variables loaded from .env
./start.sh

# Or manually:
source .env && mix phx.server
```

Now you can visit [`localhost:4001`](http://localhost:4001) from your browser.

**Note**: The application runs on port 4001 by default to avoid conflicts with other Phoenix apps.

### Running Commands with Environment Variables

**Important**: The API keys from `.env` must be loaded for most operations. Use these methods:

```bash
# Method 1: Use the helper scripts (recommended)
./start.sh                                    # Start server
./scripts/import_with_env.sh --pages 10      # Import movies
./scripts/run_with_env.sh mix run test_import.exs  # Run test import

# Method 2: Source .env manually
source .env && mix phx.server
source .env && mix run test_import.exs

# Method 3: For one-off commands
export $(cat .env | xargs) && mix some_command
```

### Admin Dashboards

After starting the server, you have access to several dashboards:

#### Import Dashboard
Visit [`localhost:4001/imports`](http://localhost:4001/imports) to:
- **Start Imports**: Popular movies, daily updates, or by decade
- **Monitor Progress**: Real-time updates on import status
- **View Statistics**: Total movies, TMDb coverage, OMDb enrichment
- **Queue Status**: See pending, running, and completed jobs
- **Import History**: Review past import sessions

#### Oban Web Dashboard
Visit [`localhost:4001/dev/oban`](http://localhost:4001/dev/oban) to:
- View all queued, executing, and completed jobs in real-time
- Monitor job performance across all queues
- Retry or cancel jobs with one click
- View detailed job arguments and stack traces
- Filter jobs by state, queue, or worker
- See job execution timeline and metrics
- Monitor queue throughput and latency

#### Phoenix LiveDashboard
Visit [`localhost:4001/dev/dashboard`](http://localhost:4001/dev/dashboard) to:
- Monitor application performance
- View system metrics and resources
- Debug live processes

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

## 🔧 Troubleshooting

### Common Issues

#### Import Not Increasing Movie Count
If imports are running but the movie count isn't increasing:

1. **Check for duplicates**: The system skips movies that already exist
   ```elixir
   # See what movies are being processed
   Oban.Job
   |> where([j], j.worker == "Cinegraph.Workers.TMDbDetailsWorker")
   |> where([j], j.state == "completed")
   |> limit(10)
   |> Cinegraph.Repo.all()
   |> Enum.map(& &1.args["tmdb_id"])
   ```

2. **Try importing different movies**:
   ```elixir
   # Import older movies that likely don't exist yet
   Cinegraph.Imports.TMDbImporter.start_decade_import(1980)
   ```

3. **Check the import dashboard** at http://localhost:4001/imports for real-time status

#### Resetting Oban Queues
To reset all Oban queues and delete all jobs:

```elixir
# In IEx console (iex -S mix)
Cinegraph.Repo.delete_all(Oban.Job)
```

This will remove all jobs from all queues, including completed, failed, and pending jobs.

#### "missing_api_key" Error in Oban Jobs
If you see errors like `Cinegraph.Workers.TMDbDiscoveryWorker failed with {:error, :missing_api_key}`:

1. **Ensure `.env` file exists** with your API keys:
   ```bash
   TMDB_API_KEY=your_actual_tmdb_key
   OMDB_API_KEY=your_actual_omdb_key
   ```

2. **Always start the server with `./start.sh`** (not `mix phx.server` directly):
   ```bash
   ./start.sh  # This loads .env variables
   ```

3. **For import scripts**, use the helper scripts:
   ```bash
   ./scripts/run_with_env.sh mix run scripts/import_tmdb.exs
   # OR
   ./scripts/import_with_env.sh --pages 10
   ```

4. **Verify keys are loaded** by running:
   ```bash
   source .env && iex -S mix
   iex> Application.get_env(:cinegraph, Cinegraph.Services.TMDb.Client)[:api_key]
   # Should show your API key, not nil
   ```

#### Rate Limiting
- TMDb allows 40 requests per 10 seconds
- OMDb free tier allows 1,000 requests per day
- The application automatically handles rate limiting, but imports may be slow

#### Database Connection Issues
If using Supabase local development:
```bash
# Start Supabase
supabase start
# Check status
supabase status
```

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