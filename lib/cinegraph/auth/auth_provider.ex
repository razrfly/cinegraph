defmodule Cinegraph.Auth.AuthProvider do
  @moduledoc """
  Authentication provider configuration for Clerk.

  Clerk is Cinegraph's user-authentication provider. (Admin routes still use
  basic auth; the GraphQL API still accepts a shared read-only API key — both
  are independent of this module.)

  ## Configuration

  Set via environment variables (resolved in `config/runtime.exs`):
  - CLERK_SECRET_KEY=sk_...
  - CLERK_PUBLISHABLE_KEY=pk_...
  """

  @doc """
  Returns the Clerk configuration keyword list.
  """
  def clerk_config do
    Application.get_env(:cinegraph, :clerk, [])
  end

  @doc """
  Checks whether Clerk authentication is enabled (both keys present).
  """
  def clerk_enabled? do
    Keyword.get(clerk_config(), :enabled, false)
  end

  @doc """
  Returns the Clerk publishable key for frontend use.
  """
  def clerk_publishable_key do
    Keyword.get(clerk_config(), :publishable_key)
  end

  @doc """
  Returns the Clerk frontend API domain.
  """
  def clerk_domain do
    Keyword.get(clerk_config(), :domain)
  end

  @doc """
  Frontend auth configuration passed to JavaScript/templates.
  """
  def frontend_config do
    %{
      provider: "clerk",
      publishable_key: clerk_publishable_key(),
      domain: clerk_domain()
    }
  end
end
