defmodule BiotWeb.Router do
  use BiotWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {BiotWeb.Layouts, :root}
    plug BiotWeb.Plugs.ControlOrigin
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BiotWeb.Plugs.ControlSession
  end

  scope "/", BiotWeb do
    pipe_through :browser

    live "/", LandingLive

    get "/login", LoginController, :start
    get "/login/callback", LoginController, :callback
    get "/preview/authorize", PreviewAuthorizeController, :authorize
    post "/logout", SessionController, :logout
    get "/biots/:id/terminal/socket", TerminalController, :upgrade

    live_session :authenticated, on_mount: {BiotWeb.LiveAuth, :authenticated} do
      live "/biots", Live.BiotsLive
      live "/biots/new", Live.NewBiotLive
      live "/biots/:id", Live.BiotLive
      live "/biots/:id/publications", Live.BiotLive, :publications
      live "/biots/:id/access", Live.BiotLive, :access
      live "/biots/:id/secrets", Live.BiotLive, :secrets
      live "/biots/:id/logs", Live.BiotLive, :logs
      live "/biots/:id/terminal", Live.TerminalLive
      live "/nodes", Live.NodesLive
      live "/account", Live.AccountLive
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug BiotWeb.Api.Bearer
  end

  pipeline :api_fallback do
    plug BiotWeb.Api.Bearer
  end

  scope "/api", BiotWeb.Api do
    pipe_through :api

    get "/me", MeController, :show
    get "/deployment", DeploymentController, :show
    get "/nodes", NodeController, :index
    get "/principals", PrincipalController, :resolve

    get "/biots", BiotController, :index
    put "/biots/:id", BiotController, :create
    get "/biots/:id", BiotController, :show
    delete "/biots/:id", BiotController, :delete
    post "/biots/:id/start", BiotController, :start
    post "/biots/:id/stop", BiotController, :stop
    post "/biots/:id/environment", BiotController, :update_environment

    get "/biots/:id/publications", PublicationController, :index
    put "/biots/:id/publications/:port", PublicationController, :publish
    delete "/biots/:id/publications/:port", PublicationController, :unpublish

    get "/biots/:id/grants", GrantController, :index
    put "/biots/:id/grants/shell/:principal_id", GrantController, :grant_shell
    delete "/biots/:id/grants/shell/:principal_id", GrantController, :revoke_shell
    put "/biots/:id/grants/view/:port/:principal_id", GrantController, :grant_view
    delete "/biots/:id/grants/view/:port/:principal_id", GrantController, :revoke_view

    get "/biots/:id/secrets", SecretController, :index
    put "/biots/:id/secrets/:name", SecretController, :deliver
    delete "/biots/:id/secrets/:name", SecretController, :remove

    put "/biots/:id/fetch-credentials", FetchCredentialController, :deliver
    delete "/biots/:id/fetch-credentials", FetchCredentialController, :remove

    get "/biots/:id/logs", LogController, :show
    get "/operations/:id", OperationController, :show
    get "/diagnostics/:ref", DiagnosticController, :show

    # Only the control account page creates a credential, so this scope has no route for it.
    get "/credentials", CredentialController, :index
    delete "/credentials/:id", CredentialController, :revoke

    get "/ssh-keys", SshKeyController, :index
    post "/ssh-keys", SshKeyController, :add
    delete "/ssh-keys/:id", SshKeyController, :remove
  end

  scope "/api", BiotWeb.Api do
    pipe_through :api_fallback

    match :*, "/", FallbackController, :not_found
    match :*, "/*path", FallbackController, :not_found
  end
end
