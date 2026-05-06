defmodule Cinegraph.Images.R2 do
  @moduledoc """
  Cloudflare R2 client (#890). S3-compatible API via `ExAws.S3`.

  Used by the festival admin to host human-curated logos and hero images.
  Keys are content-addressed (`{category}/{slug}/{kind}-{sha256_first_8}.{ext}`)
  so replacing an image changes the URL — no cache-invalidation step needed.
  PUTs set `Cache-Control: public, max-age=31536000, immutable`.

  Dev silently no-ops when any required env var is unset (`configured?/0`
  returns false; uploads return `{:error, :not_configured}`). Production
  raises at boot if any of the four required vars is missing — see
  `config/runtime.exs`.

  ## Required env

  - `CLOUDFLARE_ACCOUNT_ID`
  - `CLOUDFLARE_ACCESS_KEY_ID`
  - `CLOUDFLARE_SECRET_ACCESS_KEY`
  - `R2_CDN_URL`
  - `R2_BUCKET` (defaults to `"cinegraph"`)
  """

  @behaviour Cinegraph.Images.R2.Behaviour

  require Logger

  @cache_control "public, max-age=31536000, immutable"

  @doc """
  High-level entry point for the festival admin (#890).

  Builds a content-addressed key, downloads the source if needed, uploads
  to R2. Returns `{:ok, cdn_url}` or `{:error, reason}`.

      iex> R2.put_curated_image("festivals", "cannes", "logo", {:url, "https://example/logo.png"})
      {:ok, "https://cdn.../festivals/cannes/logo-abcd1234.png"}

      iex> R2.put_curated_image("festivals", "cannes", "logo", {:upload, "logo.svg", svg_binary})
      {:ok, "https://cdn.../festivals/cannes/logo-1f2e3d4c.svg"}

  Returns `{:error, :not_configured}` when R2 env vars are missing.
  """
  @impl true
  def put_curated_image(category, identifier, kind, source)
      when is_binary(category) and is_binary(identifier) and is_binary(kind) do
    if configured?() do
      with {:ok, body, content_type, ext_hint} <- fetch_source(source) do
        key = build_key(category, identifier, kind, body, ext: ext_hint)
        upload_binary(key, body, content_type: content_type)
      end
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Upload a binary to R2 at `key` and return `{:ok, cdn_url}`.

  Options:
    * `:content_type` — overrides the inferred MIME type

  Public for backfill tasks and tests; the LiveView path goes through
  `put_curated_image/4` instead.
  """
  def upload_binary(key, binary, opts \\ []) when is_binary(key) and is_binary(binary) do
    content_type = Keyword.get(opts, :content_type) || guess_content_type(key)

    with {:ok, aws_config} <- aws_config(),
         {:ok, _resp} <-
           ExAws.S3.put_object(bucket(), key, binary,
             content_type: content_type,
             cache_control: @cache_control,
             acl: "public-read"
           )
           |> ExAws.request(aws_config) do
      Logger.info("R2: uploaded #{byte_size(binary)} bytes to #{key}")
      {:ok, cdn_url(key)}
    else
      {:error, :not_configured} = err ->
        err

      {:error, reason} ->
        Logger.error("R2: upload failed for #{key} — #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Download `source_url` and upload to R2 at `key`. Returns `{:ok, cdn_url}`.

  Options:
    * `:content_type` — overrides what's inferred from response/key
    * `:max_bytes` — reject if response body exceeds this size (default 10MB)
    * `:timeout_ms` — HTTP timeout in ms (default 30_000)

  Public for backfill tasks; the LiveView path uses `put_curated_image/4`.
  """
  def upload_from_url(key, source_url, opts \\ [])
      when is_binary(key) and is_binary(source_url) do
    max_bytes = Keyword.get(opts, :max_bytes, 10 * 1024 * 1024)
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    headers = [{"User-Agent", "cinegraph/1.0 (+admin upload)"}, {"Accept", "image/*"}]

    http_opts = [
      timeout: timeout,
      recv_timeout: timeout,
      follow_redirect: true,
      max_redirect: 5
    ]

    with {:ok, %HTTPoison.Response{status_code: status, body: body, headers: resp_headers}}
         when status in 200..299 <-
           HTTPoison.get(source_url, headers, http_opts),
         :ok <- validate_size(body, max_bytes),
         content_type <-
           Keyword.get(opts, :content_type) || header_content_type(resp_headers, key) do
      upload_binary(key, body, content_type: content_type)
    else
      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:download_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete an object at `key` from R2. Returns `:ok` or `{:error, reason}`."
  def delete(key) when is_binary(key) do
    with {:ok, aws_config} <- aws_config(),
         {:ok, _} <- ExAws.S3.delete_object(bucket(), key) |> ExAws.request(aws_config) do
      :ok
    end
  end

  @doc """
  Return the public CDN URL for `key`. Used by the LiveView form when
  resolving uploaded objects.

  When the configured `cdn_url` is empty (e.g. dev with R2 disabled),
  returns `nil`. Callers must guard.
  """
  def cdn_url(key) when is_binary(key) do
    case cdn_base() do
      "" -> nil
      base -> "#{base}/#{key}"
    end
  end

  @doc "True when all required R2 env vars are populated."
  @impl true
  def configured? do
    cfg = config()

    cfg[:account_id] != "" and cfg[:access_key_id] != "" and cfg[:secret_access_key] != "" and
      cfg[:cdn_url] not in [nil, ""]
  end

  @doc """
  Build a content-addressed key.

      iex> R2.build_key("festivals", "cannes", "logo", "<svg>...</svg>")
      "festivals/cannes/logo-3f2a9b81.svg"

  Hash is the first 8 hex chars of SHA-256(content). Extension is inferred
  from `:ext` opt, otherwise from a `:filename` opt, otherwise defaults to
  `bin`.
  """
  def build_key(category, identifier, kind, content, opts \\ [])
      when is_binary(category) and is_binary(identifier) and is_binary(kind) and
             is_binary(content) do
    hash =
      :crypto.hash(:sha256, content)
      |> binary_part(0, 4)
      |> Base.encode16(case: :lower)

    ext =
      cond do
        ext = Keyword.get(opts, :ext) -> normalize_ext(ext)
        filename = Keyword.get(opts, :filename) -> ext_from_filename(filename)
        true -> "bin"
      end

    "#{category}/#{identifier}/#{kind}-#{hash}.#{ext}"
  end

  @doc """
  Guess a MIME type from a key/filename. Public for testing.
  """
  def guess_content_type(filename) when is_binary(filename) do
    cond do
      String.ends_with?(filename, ".jpg") or String.ends_with?(filename, ".jpeg") -> "image/jpeg"
      String.ends_with?(filename, ".png") -> "image/png"
      String.ends_with?(filename, ".gif") -> "image/gif"
      String.ends_with?(filename, ".webp") -> "image/webp"
      String.ends_with?(filename, ".avif") -> "image/avif"
      String.ends_with?(filename, ".svg") -> "image/svg+xml"
      true -> "application/octet-stream"
    end
  end

  # ----- internals -----

  # Returns {:ok, body, content_type, ext_hint} | {:error, reason}
  defp fetch_source({:upload, filename, binary}) when is_binary(filename) and is_binary(binary) do
    {:ok, binary, guess_content_type(filename), ext_from_filename(filename)}
  end

  defp fetch_source({:url, source_url}) when is_binary(source_url) do
    headers = [{"User-Agent", "cinegraph/1.0 (+admin upload)"}, {"Accept", "image/*"}]

    http_opts = [
      timeout: 30_000,
      recv_timeout: 30_000,
      follow_redirect: true,
      max_redirect: 5
    ]

    case HTTPoison.get(source_url, headers, http_opts) do
      {:ok, %HTTPoison.Response{status_code: status, body: body, headers: resp_headers}}
      when status in 200..299 ->
        if byte_size(body) > 10 * 1024 * 1024 do
          {:error, :file_too_large}
        else
          content_type = header_content_type(resp_headers, source_url)

          ext =
            ext_from_content_type(content_type) ||
              ext_from_filename(URI.parse(source_url).path || "")

          {:ok, body, content_type, ext}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, {:download_failed, reason}}
    end
  end

  defp ext_from_content_type("image/png"), do: "png"
  defp ext_from_content_type("image/jpeg"), do: "jpg"
  defp ext_from_content_type("image/gif"), do: "gif"
  defp ext_from_content_type("image/webp"), do: "webp"
  defp ext_from_content_type("image/avif"), do: "avif"
  defp ext_from_content_type("image/svg+xml"), do: "svg"
  defp ext_from_content_type(_), do: nil

  defp aws_config do
    cfg = config()

    cond do
      cfg[:account_id] == "" ->
        {:error, :not_configured}

      cfg[:access_key_id] == "" ->
        {:error, :not_configured}

      cfg[:secret_access_key] == "" ->
        {:error, :not_configured}

      true ->
        {:ok,
         %{
           access_key_id: cfg[:access_key_id],
           secret_access_key: cfg[:secret_access_key],
           region: "auto",
           scheme: "https://",
           host: "#{cfg[:account_id]}.r2.cloudflarestorage.com",
           port: 443
         }}
    end
  end

  defp config, do: Application.get_env(:cinegraph, :r2, [])

  defp bucket, do: config()[:bucket] || "cinegraph"

  defp cdn_base do
    case config()[:cdn_url] do
      nil -> ""
      url -> String.trim_trailing(url, "/")
    end
  end

  defp validate_size(body, max_bytes) do
    if byte_size(body) <= max_bytes, do: :ok, else: {:error, :file_too_large}
  end

  defp header_content_type(headers, fallback) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, v} -> v |> String.split(";") |> List.first() |> String.trim()
      nil -> guess_content_type(fallback)
    end
  end

  defp ext_from_filename(filename) do
    case Path.extname(filename) do
      "" -> "bin"
      "." <> _ = ext -> ext |> String.trim_leading(".") |> normalize_ext()
    end
  end

  defp normalize_ext(ext) when is_binary(ext) do
    ext |> String.downcase() |> String.trim_leading(".")
  end
end
