defmodule CinegraphWeb.Router do
  use CinegraphWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CinegraphWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # SEO: 301 redirects from numeric IDs to canonical slugs
    plug CinegraphWeb.Plugs.SEORedirectPlug
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin do
    plug :admin_auth
  end

  scope "/", CinegraphWeb do
    pipe_through :browser

    get "/", PageController, :coming_soon

    # Sitemap routes (no authentication required)
    get "/sitemap.xml", SitemapController, :index
    get "/sitemaps/:filename", SitemapController, :show

    # ========================================================================
    # MOVIE VIEWING ROUTES
    # ========================================================================
    #
    # Multiple entry points for viewing movies:
    #
    # 1. /movies/:slug (PRIMARY - SEO-friendly canonical URLs)
    #    Example: /movies/fight-club-1999
    #    Purpose: Direct display, optimized for search engines
    #
    # 2. /movies/tmdb/:tmdb_id (SECONDARY - Programmatic access)
    #    Example: /movies/tmdb/550
    #    Purpose: External project integration (eventasaurus, APIs)
    #    Behavior: Lookup by TMDb ID → Auto-fetch if missing → Redirect to slug
    #
    # 3. /movies/imdb/:imdb_id (SECONDARY - Cross-platform compatibility)
    #    Example: /movies/imdb/tt0137523
    #    Purpose: Industry-standard IMDb ID linking
    #    Behavior: Lookup by IMDb ID → TMDb Find → Auto-fetch → Redirect to slug
    #
    # All secondary routes redirect to the canonical slug URL to maintain SEO.
    # ========================================================================

    live "/movies", MovieLive.Index, :index
    live "/movies/discover", MovieLive.DiscoveryTuner, :index

    # TMDb ID lookup route - for external project linking
    live "/movies/tmdb/:tmdb_id", MovieLive.Show, :show_by_tmdb

    # IMDb ID lookup route - for cross-platform compatibility
    live "/movies/imdb/:imdb_id", MovieLive.Show, :show_by_imdb

    # Support both ID and slug for backward compatibility
    live "/movies/:id_or_slug", MovieLive.Show, :show
    live "/movies/:id_or_slug/legacy", MovieLive.ShowLegacy, :show
    live "/movies/:id_or_slug/metrics", MovieMetricsLive.Show, :show

    # ========================================================================
    # PEOPLE VIEWING ROUTES
    # ========================================================================
    #
    # Multiple entry points for viewing people (actors, directors, crew):
    #
    # 1. /people/:slug (PRIMARY - SEO-friendly canonical URLs)
    #    Example: /people/tom-hanks
    #    Purpose: Direct display, optimized for search engines
    #
    # 2. /people/tmdb/:tmdb_id (SECONDARY - Programmatic access)
    #    Example: /people/tmdb/31
    #    Purpose: External project integration
    #    Behavior: Lookup by TMDb ID → Redirect to slug
    #
    # All secondary routes redirect to the canonical slug URL to maintain SEO.
    # ========================================================================

    live "/people", PersonLive.Index, :index

    # TMDb ID lookup route - for external project linking
    live "/people/tmdb/:tmdb_id", PersonLive.Show, :show_by_tmdb

    # Support both ID and slug for backward compatibility
    live "/people/:id_or_slug", PersonLive.Show, :show

    # Collaboration routes
    live "/collaborations", CollaborationLive.Index, :index
    live "/six-degrees", SixDegreesLive.Index, :index
    live "/directors/:id", DirectorLive.Show, :show

    # ========================================================================
    # CLEAN URL ROUTES - Curated Lists & Awards
    # ========================================================================
    #
    # These routes provide clean, shareable URLs that map to MovieLive.Index
    # with pre-configured filters. Query params still work for additional filtering.
    #
    # Lists:
    #   /lists                    - Browse all curated lists
    #   /lists/:slug              - View movies from a specific list
    #
    # Awards:
    #   /awards                   - Browse all festivals/awards
    #   /awards/:slug             - View movies from a specific festival
    #   /awards/:slug/winners     - Winners only
    #   /awards/:slug/nominees    - Nominees only
    #   /awards/:year             - All awards from a specific year
    # ========================================================================

    # Curated Lists routes
    live "/lists", ListLive.Index, :index
    live "/lists/:slug", ListLive.Show, :show

    # Awards/Festivals routes
    live "/awards", AwardsLive.Index, :index
    live "/awards/:slug", AwardsLive.Show, :show
    live "/awards/:slug/winners", AwardsLive.Show, :winners
    live "/awards/:slug/nominees", AwardsLive.Show, :nominees
  end

  # Other scopes may use custom stacks.
  # scope "/api", CinegraphWeb do
  #   pipe_through :api
  # end

  # Admin dashboard - protected with basic auth
  import Oban.Web.Router

  scope "/admin", CinegraphWeb do
    pipe_through [:browser, :admin]

    # Import dashboard
    live "/imports", ImportDashboardLive, :index
    # Year-by-year TMDb import management
    live "/year-imports", YearImportsLive, :index

    # Metrics dashboard
    live "/metrics", MetricsLive.Index, :index
    live "/metrics/profile/:name", MetricsLive.Index, :profile

    # Movie Predictions for 1001 Movies list
    live "/predictions", PredictionsLive.Index, :index

    # Festival Events management
    live "/festival-events", FestivalEventLive.Index, :index

    # Oban job dashboard
    oban_dashboard("/oban")
  end

  # Basic auth for admin routes
  defp admin_auth(conn, _opts) do
    if Application.get_env(:cinegraph, :admin_auth_disabled, false) do
      conn
    else
      username = System.get_env("ADMIN_USERNAME") || "admin"
      password = System.get_env("ADMIN_PASSWORD") || raise "ADMIN_PASSWORD must be set"

      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cinegraph, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CinegraphWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
