defmodule Cinegraph.Images.R2.Behaviour do
  @moduledoc """
  Behaviour for the R2 client (#890). Lets tests substitute a stub via
  `Application.get_env(:cinegraph, :r2_client)`.

  The high-level API is `put_curated_image/4`. Sources are tagged tuples
  so a single callback handles both paste-URL and file-upload paths:

    * `{:url, source_url}` — fetch via HTTPoison then upload
    * `{:upload, filename, binary}` — already in memory, upload directly

  Both paths build a content-addressed key
  (`{category}/{identifier}/{kind}-{hash8}.{ext}`) so callers don't need
  to manage keys themselves.
  """

  @type image_source ::
          {:url, source_url :: String.t()}
          | {:upload, filename :: String.t(), binary :: binary()}

  @callback put_curated_image(
              category :: String.t(),
              identifier :: String.t(),
              kind :: String.t(),
              image_source
            ) ::
              {:ok, cdn_url :: String.t()} | {:error, term()}

  @callback upload_binary(key :: String.t(), binary(), opts :: keyword()) ::
              {:ok, cdn_url :: String.t()} | {:error, term()}

  @callback upload_from_url(key :: String.t(), source_url :: String.t(), opts :: keyword()) ::
              {:ok, cdn_url :: String.t()} | {:error, term()}

  @callback configured?() :: boolean()
end
