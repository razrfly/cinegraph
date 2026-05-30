defmodule Cinegraph.Auth.Clerk.Client do
  @moduledoc """
  HTTP client for the Clerk Backend API.

  Provides functions to interact with Clerk's Backend API for user management,
  session verification, and other administrative operations.

  ## Configuration

  Requires the following configuration (set in `config/runtime.exs`):

      config :cinegraph, :clerk,
        secret_key: "sk_test_...",
        domain: "your-app.clerk.accounts.dev"

  ## Usage

      # Get a user by Clerk ID
      {:ok, user} = Client.get_user("user_abc123")

      # Get a user by external ID (our users.id)
      {:ok, user} = Client.get_user_by_external_id("19")

      # List all users
      {:ok, users} = Client.list_users()
  """

  require Logger

  @base_url "https://api.clerk.com/v1"
  @timeout 30_000

  # ============================================================================
  # User Operations
  # ============================================================================

  @doc """
  Get a user by their Clerk user ID.

  ## Examples

      {:ok, user} = Client.get_user("user_abc123")
      {:error, :not_found} = Client.get_user("user_nonexistent")
  """
  def get_user(user_id) do
    request(:get, "/users/#{user_id}")
  end

  @doc """
  Get a user by their external ID (our `users.id`).

  ## Examples

      {:ok, user} = Client.get_user_by_external_id("19")
  """
  def get_user_by_external_id(external_id) do
    case list_users(external_id: external_id) do
      {:ok, [user | _]} -> {:ok, user}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  List users with optional filters.

  ## Options

    * `:limit` - Maximum number of users to return (default: 10, max: 500)
    * `:offset` - Number of users to skip (for pagination)
    * `:email_address` - Filter by email address
    * `:external_id` - Filter by external ID
    * `:phone_number` - Filter by phone number
    * `:order_by` - Sort order (e.g., "+created_at", "-created_at")

  ## Examples

      {:ok, users} = Client.list_users(limit: 100)
      {:ok, users} = Client.list_users(email_address: "user@example.com")
      {:ok, users} = Client.list_users(external_id: "19")
  """
  @spec list_users(Keyword.t()) :: {:ok, list(map())} | {:error, term()}
  def list_users(opts \\ []) do
    if Keyword.get(opts, :email_address) == [] do
      {:ok, []}
    else
      do_list_users(opts)
    end
  end

  defp do_list_users(opts) do
    query_parts =
      opts
      |> Enum.filter(fn {_k, v} -> v != nil end)
      |> Enum.flat_map(fn
        {:email_address, v} when is_list(v) ->
          Enum.map(v, fn e -> {"email_address", to_string(e)} end)

        {:email_address, v} ->
          [{"email_address", to_string(v)}]

        {:external_id, v} ->
          [{"external_id", to_string(v)}]

        {:phone_number, v} ->
          [{"phone_number", to_string(v)}]

        {:limit, v} ->
          [{"limit", to_string(v)}]

        {:offset, v} ->
          [{"offset", to_string(v)}]

        {:order_by, v} ->
          [{"order_by", v}]
      end)

    query_string = URI.encode_query(query_parts)
    path = if query_string == "", do: "/users", else: "/users?#{query_string}"
    request(:get, path)
  end

  @doc """
  Update a user's attributes.

  ## Examples

      {:ok, user} = Client.update_user("user_abc123", %{
        first_name: "John",
        last_name: "Doe"
      })
  """
  def update_user(user_id, attrs) do
    request(:patch, "/users/#{user_id}", attrs)
  end

  @doc """
  Delete a user.

  ## Examples

      {:ok, _} = Client.delete_user("user_abc123")
  """
  def delete_user(user_id) do
    request(:delete, "/users/#{user_id}")
  end

  @doc """
  Create a new user in Clerk.

  ## Examples

      {:ok, user} = Client.create_user(%{
        email_addresses: ["user@example.com"],
        first_name: "Jane",
        skip_password_checks: true,
        skip_password_requirement: true
      })
  """
  @spec create_user(map()) :: {:ok, map()} | {:error, any()}
  def create_user(attrs) do
    request(:post, "/users", attrs)
  end

  @doc """
  Find an existing Clerk user by email or create a new one.

  ## Examples

      {:ok, clerk_user} = Client.find_or_create_clerk_user("user@example.com", "Jane")
  """
  @spec find_or_create_clerk_user(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def find_or_create_clerk_user(email, name) do
    case list_users(email_address: email) do
      {:ok, [clerk_user | _]} ->
        {:ok, clerk_user}

      {:ok, []} ->
        {first_name, last_name} = split_name(name)

        create_user(%{
          email_address: [email],
          first_name: first_name,
          last_name: last_name,
          skip_password_checks: true,
          skip_password_requirement: true
        })

      error ->
        error
    end
  end

  # ============================================================================
  # Session Operations
  # ============================================================================

  @doc """
  Get a session by its ID.

  ## Examples

      {:ok, session} = Client.get_session("sess_abc123")
  """
  def get_session(session_id) do
    request(:get, "/sessions/#{session_id}")
  end

  @doc """
  Revoke a session.

  ## Examples

      {:ok, session} = Client.revoke_session("sess_abc123")
  """
  def revoke_session(session_id) do
    request(:post, "/sessions/#{session_id}/revoke")
  end

  @doc """
  Verify a client session token.

  This is an alternative to JWT verification when you need to verify
  a session token against Clerk's servers.

  ## Examples

      {:ok, client} = Client.verify_client(session_token)
  """
  def verify_client(token) do
    request(:get, "/clients/verify?token=#{URI.encode_www_form(token)}")
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp request(method, path, body \\ nil) do
    url = @base_url <> path
    headers = build_headers()

    options = [
      recv_timeout: @timeout
    ]

    result =
      case method do
        :get ->
          HTTPoison.get(url, headers, options)

        :post ->
          json_body = if body, do: Jason.encode!(body), else: ""
          HTTPoison.post(url, json_body, headers, options)

        :patch ->
          json_body = if body, do: Jason.encode!(body), else: ""
          HTTPoison.patch(url, json_body, headers, options)

        :delete ->
          HTTPoison.delete(url, headers, options)
      end

    handle_response(result)
  end

  defp build_headers do
    secret_key = get_config(:secret_key)

    if is_nil(secret_key) do
      raise "Clerk secret_key is not configured. Set CLERK_SECRET_KEY environment variable."
    end

    [
      {"Authorization", "Bearer #{secret_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: status, body: body}})
       when status in 200..299 do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:ok, body}
    end
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 404}}) do
    {:error, :not_found}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 401}}) do
    {:error, :unauthorized}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 403}}) do
    {:error, :forbidden}
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: 422, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"errors" => errors}} -> {:error, {:validation_error, errors}}
      _ -> {:error, :validation_error}
    end
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: status, body: body}}) do
    Logger.error("Clerk API error: status=#{status}, body=#{body}")
    {:error, {:api_error, status, body}}
  end

  defp handle_response({:error, %HTTPoison.Error{reason: reason}}) do
    Logger.error("Clerk API request failed: #{inspect(reason)}")
    {:error, {:request_failed, reason}}
  end

  defp get_config(key) do
    Application.get_env(:cinegraph, :clerk, [])
    |> Keyword.get(key)
  end

  defp split_name(name) when is_binary(name) do
    case String.split(String.trim(name), ~r/\s+/, parts: 2) do
      [first, last] -> {first, last}
      [first] -> {first, ""}
      [] -> {"", ""}
    end
  end

  defp split_name(_), do: {"", ""}
end
