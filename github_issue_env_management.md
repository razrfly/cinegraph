# Improve Environment Variable Management with .env File Support

## Problem Description

Currently, cinegraph requires developers to manually set environment variables before running the application, which creates several issues:

1. **Developer Experience**: New developers need to manually export multiple environment variables (TMDB_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, etc.) each time they open a new terminal session
2. **Configuration Drift**: No standardized way to document required environment variables for the team
3. **Error-Prone Setup**: Easy to miss required variables or use incorrect values
4. **Inconsistent with Sister Project**: The eventasaurus project has a simple .env loading mechanism in `application.ex`, while cinegraph lacks this convenience

## Current State

### cinegraph's Current Approach:
- Uses `System.get_env/1` in `config/runtime.exs` for production config
- Has some `System.get_env/1` calls in `config/dev.exs` that run at compile time (anti-pattern)
- No .env file support - requires manual environment variable setup
- No .env.example file to document required variables

### eventasaurus's Working Solution:
```elixir
# lib/eventasaurus/application.ex
def start(_type, _args) do
  # Load environment variables from .env file if in dev/test environment
  env = Application.get_env(:eventasaurus, :environment, :prod)
  if env in [:dev, :test] do
    case File.read(Path.expand(".env")) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.each(fn line ->
          if String.contains?(line, "=") do
            [key, value] = String.split(line, "=", parts: 2)
            System.put_env(String.trim(key), String.trim(value))
          end
        end)
      _ -> :ok
    end
  end
  # ... rest of application startup
end
```

## Proposed Solution

Implement a robust environment variable management system using the **Dotenvy** library, which is the recommended approach for modern Elixir/Phoenix applications.

### Implementation Steps:

1. **Add Dotenvy dependency** to `mix.exs`:
```elixir
defp deps do
  [
    # ... existing deps
    {:dotenvy, "~> 0.8.0"}
  ]
end
```

2. **Update config/runtime.exs** to use Dotenvy:
```elixir
import Config
import Dotenvy

# Load .env files only in development
if config_env() == :dev do
  source!([
    ".env",
    ".env.dev",      # Optional: dev-specific overrides
    System.get_env() # System env vars take precedence
  ])
end

# Configure Supabase
config :supabase_potion,
  base_url: env!("SUPABASE_URL", :string!),
  api_key: env!("SUPABASE_ANON_KEY", :string!)

# Configure TMDb
config :cinegraph, Cinegraph.Services.TMDb.Client,
  api_key: env!("TMDB_API_KEY", :string!)

# Configure OMDb (if used)
config :cinegraph, Cinegraph.Services.OMDb.Client,
  api_key: env!("OMDB_API_KEY", :string, "")  # Optional with default

# Database configuration for development
if config_env() == :dev do
  config :cinegraph, Cinegraph.Repo,
    url: env!("SUPABASE_DATABASE_URL", :string, "postgresql://postgres:postgres@127.0.0.1:54332/postgres")
end
```

3. **Remove System.get_env calls from config/dev.exs** (lines 88-93):
```elixir
# Remove these anti-pattern calls:
# config :cinegraph, Cinegraph.Services.TMDb.Client,
#   api_key: System.get_env("TMDB_API_KEY")
# 
# config :cinegraph, Cinegraph.Services.OMDb.Client,
#   api_key: System.get_env("OMDB_API_KEY")
```

4. **Create .env.example** in project root:
```bash
# Supabase Configuration
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=your_supabase_anon_key_here
SUPABASE_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54332/postgres

# API Keys
TMDB_API_KEY=your_tmdb_api_key_here
OMDB_API_KEY=your_omdb_api_key_here

# Phoenix Configuration (optional)
PORT=4001
SECRET_KEY_BASE=generate_with_mix_phx_gen_secret
```

5. **Update .gitignore**:
```gitignore
# Environment files
.env
.env.*
!.env.example
```

6. **Update README.md** with setup instructions:
```markdown
## Setup

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and add your API keys:
   - Get TMDB API key from https://www.themoviedb.org/settings/api
   - Get OMDb API key from http://www.omdbapi.com/apikey.aspx
   - Use default Supabase values for local development

3. Install dependencies and setup database:
   ```bash
   mix setup
   ```

4. Start the Phoenix server:
   ```bash
   mix phx.server
   ```
```

## Benefits

1. **Improved Developer Experience**: 
   - One-time setup with `cp .env.example .env`
   - No need to manually export variables in each terminal session
   - Clear documentation of required variables

2. **Type Safety**: 
   - Dotenvy provides type casting and validation
   - Clear error messages for missing required variables
   - Supports defaults for optional variables

3. **Best Practices Compliance**:
   - Follows 12-factor app principles
   - Compatible with Elixir releases
   - Avoids compile-time configuration anti-patterns

4. **Team Collaboration**:
   - Standardized configuration approach
   - Easy onboarding for new developers
   - Consistent with modern Phoenix conventions

## Alternative: Simple Solution (like eventasaurus)

If adding a dependency is not desired, we could implement a simple solution similar to eventasaurus:

```elixir
# In lib/cinegraph/application.ex
def start(_type, _args) do
  # Load .env in development only
  if Mix.env() in [:dev, :test] do
    load_dot_env()
  end
  
  # ... existing children setup
end

defp load_dot_env do
  case File.read(".env") do
    {:ok, content} ->
      content
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            System.put_env(String.trim(key), String.trim(value, ~s("')))
          _ -> :ok
        end
      end)
    _ -> :ok
  end
end
```

However, the Dotenvy approach is recommended as it provides better error handling, type safety, and follows Phoenix best practices.

## Implementation Priority

**High Priority** - This improvement would significantly enhance developer experience and reduce setup friction for the team. It's a relatively small change with high impact.

## References

- [Dotenvy Documentation](https://hexdocs.pm/dotenvy)
- [Phoenix Configuration Best Practices](https://hexdocs.pm/phoenix/deployment.html#runtime-configuration)
- [12-Factor App Config](https://12factor.net/config)