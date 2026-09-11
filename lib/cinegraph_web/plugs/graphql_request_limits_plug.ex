defmodule CinegraphWeb.Plugs.GraphQLRequestLimitsPlug do
  @moduledoc """
  Bounds GraphQL transport batches before Absinthe executes each operation.

  Operation complexity and parser token limits are configured on Absinthe.Plug;
  this plug closes the separate HTTP batching multiplier.
  """

  @behaviour Plug

  import Plug.Conn

  @default_max_batch_size 10

  def init(opts), do: Keyword.put_new(opts, :max_batch_size, @default_max_batch_size)

  def call(conn, opts) do
    # Absinthe accepts batches in merged body/query params, including JSON
    # strings under either key. Inspect that same input before execution.
    conn = fetch_query_params(conn)
    max_batch_size = Keyword.fetch!(opts, :max_batch_size)

    if batch_size(conn.params) > max_batch_size do
      body =
        Jason.encode!(%{
          errors: [%{message: "GraphQL batches are limited to #{max_batch_size} operations"}]
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, body)
      |> halt()
    else
      conn
    end
  end

  defp batch_size(params) do
    # Check both keys so a small decoy cannot conceal an oversized batch.
    max(encoded_batch_size(params["_json"]), encoded_batch_size(params["operations"]))
  end

  defp encoded_batch_size(batch) when is_list(batch), do: length(batch)

  defp encoded_batch_size(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, batch} when is_list(batch) -> length(batch)
      _ -> 0
    end
  end

  defp encoded_batch_size(_), do: 0
end
