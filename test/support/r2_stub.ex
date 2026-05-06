defmodule Cinegraph.Images.R2Stub do
  @moduledoc """
  In-memory stub for `Cinegraph.Images.R2.Behaviour` (#890).

  Backed by an ETS table so the LiveView process and the test process
  share state. Safe because tests using this stub run with
  `async: false`. Reset between tests via `reset!/0` in `setup`.

  Configured globally in `config/test.exs` as
  `config :cinegraph, :r2_client, Cinegraph.Images.R2Stub`. Per-test
  overrides:

      R2Stub.put_response({:error, :file_too_large})
      R2Stub.disable!()  # makes configured?/0 return false
      R2Stub.calls()     # list of recorded calls in insertion order
      R2Stub.reset!()    # clear state
  """

  @behaviour Cinegraph.Images.R2.Behaviour

  @table :cinegraph_r2_stub
  @cdn_base "https://test-cdn.example"

  @doc "Initialize the ETS table. Call once from test_helper.exs."
  def start! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        reset!()
        :ok

      _ref ->
        :ok
    end
  end

  @impl true
  def put_curated_image(category, identifier, kind, source) do
    record_call(:put_curated_image, %{
      category: category,
      identifier: identifier,
      kind: kind,
      source: source_summary(source)
    })

    case lookup(:response) do
      nil ->
        key = "#{category}/#{identifier}/#{kind}-#{fake_hash(source)}.#{fake_ext(source)}"
        {:ok, "#{@cdn_base}/#{key}"}

      response ->
        response
    end
  end

  @impl true
  def configured? do
    case lookup(:configured) do
      nil -> true
      v -> v
    end
  end

  def put_response(response) do
    insert(:response, response)
    :ok
  end

  def disable! do
    insert(:configured, false)
    :ok
  end

  def calls do
    case :ets.lookup(@table, :calls) do
      [{:calls, list}] -> Enum.reverse(list)
      [] -> []
    end
  end

  def reset! do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp record_call(fun, args) do
    existing =
      case :ets.lookup(@table, :calls) do
        [{:calls, list}] -> list
        [] -> []
      end

    :ets.insert(@table, {:calls, [{fun, args} | existing]})
  end

  defp insert(key, value), do: :ets.insert(@table, {key, value})

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, v}] -> v
      [] -> nil
    end
  end

  defp source_summary({:url, url}), do: {:url, url}
  defp source_summary({:upload, filename, binary}), do: {:upload, filename, byte_size(binary)}

  defp fake_hash({:url, url}),
    do: url |> :erlang.phash2() |> Integer.to_string(16) |> String.pad_leading(8, "0")

  defp fake_hash({:upload, _, binary}),
    do: binary |> :erlang.phash2() |> Integer.to_string(16) |> String.pad_leading(8, "0")

  defp fake_ext({:url, url}) do
    case Path.extname(url) do
      "." <> rest when rest != "" ->
        rest |> String.split("?") |> List.first() |> String.downcase()

      _ ->
        "png"
    end
  end

  defp fake_ext({:upload, filename, _}) do
    case Path.extname(filename) do
      "." <> rest when rest != "" -> String.downcase(rest)
      _ -> "bin"
    end
  end
end
