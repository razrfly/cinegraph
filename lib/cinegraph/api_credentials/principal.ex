defmodule Cinegraph.ApiCredentials.Principal do
  @moduledoc "Non-secret application identity attached to an authenticated request."

  @enforce_keys [:client_id, :key_id, :client_slug, :scopes, :kind]
  defstruct [:client_id, :key_id, :client_slug, :scopes, :kind]
end
