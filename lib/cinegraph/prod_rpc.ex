defmodule Cinegraph.ProdRpc do
  @moduledoc """
  Helpers for `mix cinegraph.prod.*` tasks (#739 Phase C). Wraps
  `kamal app exec` so dev terminals can read live prod numbers without
  a DB pull or manual SSH.

  Cinegraph deploys via Kamal (see `config/deploy.yml`); the release binary
  lives at `/app/bin/cinegraph` inside the running Docker container, not on
  the host filesystem. Running maintenance commands therefore goes through
  `kamal app exec` rather than direct `ssh + bin/cinegraph eval`.

  ## Configuration

  Reads the canonical Kamal config (`config/deploy.yml`) — no env vars
  required. Just have the `kamal` CLI on PATH (it's installed via mise in
  this project; see `mix.exs` / `mise.toml`).

  ## Example

      iex> Cinegraph.ProdRpc.eval_json(~s|IO.puts(Jason.encode!(%{ok: 1}))|)
      {:ok, %{"ok" => 1}}

  See `MAINTENANCE.md` for end-to-end recipes.
  """

  @typedoc "Reasons `eval_json/1` and `eval_raw/1` may fail."
  @type error_reason ::
          :kamal_not_found
          | {:kamal_failed, exit_code :: integer(), output :: binary()}
          | {:eval_failed, output :: binary()}
          | {:json_parse_failed, raw_output :: binary(), error :: term()}

  @doc """
  Run `expression` in the prod container, expect it to write a JSON document
  to stdout (typically via `IO.puts(Jason.encode!(...))`), and return the
  parsed Elixir term.

  Returns `{:ok, decoded}` on success; `{:error, reason}` on any failure.
  """
  @spec eval_json(binary()) :: {:ok, term()} | {:error, error_reason()}
  def eval_json(expression) when is_binary(expression) do
    with {:ok, raw} <- eval_raw(expression) do
      decode_json(raw)
    end
  end

  @doc """
  Run `expression` in the prod container and return raw stdout. Use
  `eval_json/1` unless you need the unparsed output.
  """
  @spec eval_raw(binary()) :: {:ok, binary()} | {:error, error_reason()}
  def eval_raw(expression) when is_binary(expression) do
    with {:ok, kamal_path} <- locate_kamal(),
         args = build_kamal_args(expression) do
      run_kamal(kamal_path, args)
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
  Format and print an error to stderr-equivalent and halt non-zero so
  CI/scripts can detect.
  """
  @spec print_error(error_reason()) :: no_return()
  def print_error(reason) do
    Mix.shell().error(format_error(reason))
    System.halt(1)
  end

  # ===== private =====

  @doc false
  def locate_kamal do
    case System.find_executable("kamal") do
      nil -> {:error, :kamal_not_found}
      path -> {:ok, path}
    end
  end

  @doc false
  def build_kamal_args(expression) when is_binary(expression) do
    # Base64-encode the entire wrapped expression so the eval argument contains
    # no semicolons or quotes. The kamal → SSHKit → ssh → docker exec chain
    # applies its own outer quoting; any inner single-quoting we add can break
    # out of that context and turn Elixir preamble semicolons into bare shell
    # commands. Base64 chars [A-Za-z0-9+/=] are safe through every quoting layer.
    #
    # `unset PHX_SERVER`: runtime.exs checks for the var's *presence* — the
    # container starts with PHX_SERVER=true, so we must clear it or the eval
    # BEAM tries to bind port 4000 (already held) and supervision rolls back.
    wrapped = eval_preamble() <> "\n" <> expression
    encoded = Base.encode64(wrapped)
    eval_expr = ~s|Code.eval_string(Base.decode64!("#{encoded}"))|
    quoted = single_quote(eval_expr)
    escaped = escape_for_double_quoted(quoted)
    shell_command = ~s|sh -c "unset PHX_SERVER; bin/cinegraph eval #{escaped}"|

    ["app", "exec", "--reuse", "--quiet", "--primary", shell_command]
  end

  # Preamble run before every eval expression in the prod container:
  # - silence logging so JSON output is not polluted
  # - capture Oban config before disabling queue processing and plugins
  # - prevent the short-lived eval BEAM from processing jobs or firing cron
  # Uses newlines (not semicolons) so the base64 payload contains no `;`.
  defp eval_preamble do
    ":logger.set_primary_config(:level, :critical)\n" <>
      "oban_config = Application.fetch_env!(:cinegraph, Oban)\n" <>
      "Application.put_env(:cinegraph, :known_oban_queues, Keyword.keys(Keyword.get(oban_config, :queues, [])))\n" <>
      "Application.put_env(:cinegraph, :start_background_children, false)\n" <>
      "Application.put_env(:cinegraph, Oban, Keyword.merge(oban_config, queues: [], plugins: []))\n" <>
      "Application.ensure_all_started(:cinegraph)"
  end

  @doc false
  def decode_json(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Jason.decode(trimmed) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:json_parse_failed, raw, error}}
    end
  end

  # POSIX-safe single-quote wrapping: 'foo' or 'foo'\''bar' for embedded quotes.
  defp single_quote(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  # Escape a string for safe interpolation inside a double-quoted POSIX shell
  # context. Inside `"..."`, the chars `\`, `"`, `$`, and `` ` `` retain
  # special meaning; everything else is literal. Order matters — escape `\`
  # first so escapes added for the other chars aren't double-escaped.
  defp escape_for_double_quoted(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("$", "\\$")
    |> String.replace("`", "\\`")
  end

  defp run_kamal(path, args) do
    # `kamal app exec --quiet` still emits some logging on stderr, and
    # infrastructure errors from SSHKit/ssh ("Permission denied", "No such
    # container", ...) only ever go to stderr. We need them in `output` so
    # `classify_failure/2` can match them — otherwise every failure looks
    # like an empty `{:eval_failed, ""}`. `strip_kamal_noise/1` filters
    # banner lines from the merged stream.
    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, strip_kamal_noise(output)}
      {output, code} -> classify_failure(output, code)
    end
  end

  # `kamal app exec` prefixes lines with INFO/console banners even with -q.
  # The eval output is whatever stays after we drop those. Also handle the
  # case where kamal returns the raw output cleanly (which is what `--quiet`
  # is supposed to do — keep the strip logic defensive).
  defp strip_kamal_noise(output) do
    output
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.starts_with?(line, "INFO ") or
        String.starts_with?(line, "Running") or
        String.starts_with?(line, "Finished ") or
        String.starts_with?(line, "Launched ") or
        String.starts_with?(line, "App Host:")
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp classify_failure(output, exit_code) do
    cond do
      String.contains?(output, "Permission denied") or
        String.contains?(output, "Could not resolve hostname") or
        String.contains?(output, "Connection refused") or
        String.contains?(output, "Connection timed out") or
          String.contains?(output, "No such container") ->
        {:error, {:kamal_failed, exit_code, output}}

      true ->
        {:error, {:eval_failed, output}}
    end
  end

  defp format_error(:kamal_not_found) do
    """
    kamal CLI not found on PATH. Cinegraph deploys with Kamal — install it via
    mise (already pinned in this project's mise.toml) or the kamal docs:
    https://kamal-deploy.org/docs/installation/
    """
  end

  defp format_error({:kamal_failed, code, output}) do
    "kamal app exec failed (exit #{code}):\n#{String.trim(output)}"
  end

  defp format_error({:eval_failed, output}) do
    "Eval inside prod container failed:\n#{String.trim(output)}"
  end

  defp format_error({:json_parse_failed, raw, _err}) do
    """
    Got non-JSON output from prod (your expression must call IO.puts(Jason.encode!(...))):

    #{String.trim(raw)}
    """
  end
end
