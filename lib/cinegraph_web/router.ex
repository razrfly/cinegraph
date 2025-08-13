defmodule CinegraphWeb.Router do
  use CinegraphWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CinegraphWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CinegraphWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Movie routes
    live "/movies", MovieLive.Index, :index
    live "/movies/discover", MovieLive.DiscoveryTuner, :index
    live "/movies/:id", MovieLive.Show, :show

    # People routes
    live "/people", PersonLive.Index, :index
    live "/people/:id", PersonLive.Show, :show

    # Collaboration routes
    live "/collaborations", CollaborationLive.Index, :index
    live "/six-degrees", SixDegreesLive.Index, :index
    live "/directors/:id", DirectorLive.Show, :show

    # Import dashboard
    live "/imports", ImportDashboardLive, :index
    
    # CRI Dashboard
    live "/cri", CRIDashboardLive, :index

    # Festival Events management
    live "/festival-events", FestivalEventLive.Index, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", CinegraphWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cinegraph, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router
    import Oban.Web.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CinegraphWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview

      # Oban Web dashboard
      oban_dashboard("/oban")
    end
  end
end
