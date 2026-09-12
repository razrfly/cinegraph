defmodule Cinegraph.Configuration do
  @moduledoc false

  @doc "Returns a configured secret or raises when it is blank."
  def require_non_blank!(name, value) when is_binary(value) do
    if String.trim(value) == "" do
      raise ArgumentError, "#{name} must not be blank"
    end

    value
  end

  def require_non_blank!(name, _value) do
    raise ArgumentError, "#{name} must not be blank"
  end

  @doc "Parses the explicit local API-auth bypass and forbids it in production."
  def api_auth_local_bypass!(environment, value) do
    enabled =
      case value do
        nil -> false
        value when is_binary(value) and value in ["1", "true", "TRUE", "yes", "YES"] -> true
        value when is_binary(value) and value in ["0", "false", "FALSE", "no", "NO"] -> false
        _ -> raise ArgumentError, "CINEGRAPH_API_AUTH_LOCAL_BYPASS must be true or false"
      end

    if environment == :prod and enabled do
      raise ArgumentError, "CINEGRAPH_API_AUTH_LOCAL_BYPASS is forbidden in production"
    end

    enabled
  end
end
