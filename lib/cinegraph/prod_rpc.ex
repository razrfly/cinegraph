defmodule Cinegraph.ProdRpc do
  @moduledoc """
  Helpers for `mix cinegraph.prod.*` tasks (#739 Phase C). Wraps the
  `ssh + bin/cinegraph eval` recipe and returns parsed JSON results so dev
  terminals can read live prod numbers without a DB pull.

  ## Configuration

    * `REMOTE_SSH_HOST` — host to ssh into. Default `"192.168.1.205"` (matches
      `mix db.pull_production`). Override for staging or a different prod box.
    * `REMOTE_APP_BIN` — full path to the release binary on the remote host,
      e.g. `"/home/cinegraph/cinegraph/bin/cinegraph"`. **Required** — no
      default, because the path depends on deploy layout. Set in your shell
      rc / `.env`.

  ## Example

      iex> Cinegraph.ProdRpc.eval_json(~s|IO.puts(Jason.encode!(%{ok: 1}))|)
      {:ok, %{"ok" => 1}}

  See `MAINTENANCE.md` for end-to-end recipes.
  """

  @ssh_opts ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes"]

  @typedoc "Reasons `eval_json/1` and `eval_raw/1` may fail."
  @type error_reason ::
          :app_bin_not_set
          | {:ssh_failed, exit_code :: integer(), output :: binary()}
          | {:eval_failed, output :: binary()}
          | {:json_parse_failed, raw_output :: binary(), error :: term()}

  @doc """
  Run `expression` on the prod node, expect it to write a JSON document to
  stdout (typically via `IO.puts(Jason.encode!(...))`), and return the parsed
  Elixir term.

  Returns `{:ok, decoded}` on success; `{:error, reason}` on any failure.
  """
  @spec eval_json(binary()) :: {:ok, term()} | {:error, error_reason()}
  def eval_json(expression) when is_binary(expression) do
    with {:ok, raw} <- eval_raw(expression) do
      decode_json(raw)
    end
  end

  @doc """
  Run `expression` on the prod node and return raw stdout. Use `eval_json/1`
  unless you need the unparsed output.
  """
  @spec eval_raw(binary()) :: {:ok, binary()} | {:error, error_reason()}
  def eval_raw(expression) when is_binary(expression) do
    with {:ok, bin} <- app_bin(),
         {:ok, args} <- build_args(bin, expression) do
      run_ssh(args)
    end
  end

  @doc """
  Pretty-print a result returned by `eval_json/1`. Honors `--json` opt for
  raw passthrough (single-line JSON, no header).
  """
  @spec print(term(), keyword()) :: :ok
  def print(result, opts \\ []) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(result))
    else
      IO.puts(Jason.encode!(result, pretty: true))
    end

    :ok
  end

  @doc """
  Format and print an error from `eval_json/1` / `eval_raw/1` to stderr-
  equivalent (Mix.shell().error). Exits non-zero so CI/scripts can detect.
  """
  @spec print_error(error_reason()) :: no_return()
  def print_error(reason) do
    Mix.shell().error(format_error(reason))
    System.halt(1)
  end

  # ===== private =====

  @doc false
  def app_bin do
    case System.get_env("REMOTE_APP_BIN") do
      nil -> {:error, :app_bin_not_set}
      "" -> {:error, :app_bin_not_set}
      path -> {:ok, path}
    end
  end

  @doc false
  def build_args(app_bin, expression) when is_binary(app_bin) and is_binary(expression) do
    # The release binary expects: <bin> eval "<expression>"
    # We pass it as a single shell-string to ssh because ssh joins remote args
    # with spaces. Wrapping the expression in single quotes is unsafe (single
    # quotes in the expression would break it); instead, we'll let the user's
    # expressions use double-quote-safe syntax (sigils, escaped strings) and
    # wrap with double quotes here.
    remote_command = ~s|#{app_bin} eval #{quote_expression(expression)}|
    {:ok, @ssh_opts ++ [host(), remote_command]}
  end

  @doc false
  def decode_json(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Jason.decode(trimmed) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, error} ->
        {:error, {:json_parse_failed, raw, error}}
    end
  end

  defp host, do: System.get_env("REMOTE_SSH_HOST", "192.168.1.205")

  # Wrap the eval expression as a double-quoted shell string. The expression
  # will pass through ssh → remote shell → `cinegraph eval "..."`. Escape
  # double quotes and backslashes so the remote shell sees the original.
  defp quote_expression(expression) do
    escaped =
      expression
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    ~s|"#{escaped}"|
  end

  defp run_ssh(args) do
    case System.cmd("ssh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> classify_failure(output, code)
    end
  end

  # SSH itself returned non-zero. Distinguish ssh-layer errors from
  # eval-runtime errors by sniffing output.
  defp classify_failure(output, exit_code) do
    cond do
      String.contains?(output, "Permission denied") or
        String.contains?(output, "Could not resolve hostname") or
          String.contains?(output, "Connection refused") or
            String.contains?(output, "Connection timed out") ->
        {:error, {:ssh_failed, exit_code, output}}

      true ->
        {:error, {:eval_failed, output}}
    end
  end

  defp format_error(:app_bin_not_set) do
    """
    REMOTE_APP_BIN is not set. This is the path to the cinegraph release binary on the prod host, e.g.:

        export REMOTE_APP_BIN=/home/cinegraph/cinegraph/bin/cinegraph

    Set it in your shell rc or .env. See MAINTENANCE.md for details.
    """
  end

  defp format_error({:ssh_failed, code, output}) do
    "SSH to #{host()} failed (exit #{code}):\n#{String.trim(output)}"
  end

  defp format_error({:eval_failed, output}) do
    "Eval on #{host()} failed:\n#{String.trim(output)}"
  end

  defp format_error({:json_parse_failed, raw, _err}) do
    """
    Got non-JSON output from prod (your expression must call IO.puts(Jason.encode!(...))):

    #{String.trim(raw)}
    """
  end
end
