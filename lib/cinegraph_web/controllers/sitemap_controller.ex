defmodule CinegraphWeb.SitemapController do
  @moduledoc """
  Controller for serving sitemap files.

  Sitemaps are generated daily by the SitemapWorker and stored in
  priv/static/sitemaps/. This controller serves the generated XML files.

  Routes:
  - GET /sitemap.xml - Main sitemap index
  - GET /sitemaps/:filename - Individual sitemap chunks
  """

  use CinegraphWeb, :controller

  @sitemap_dir Path.join([:code.priv_dir(:cinegraph), "static", "sitemaps"])

  @doc """
  Serves the main sitemap index file.
  Redirects to /sitemaps/sitemap.xml
  """
  def index(conn, _params) do
    sitemap_path = Path.join(@sitemap_dir, "sitemap.xml")

    if File.exists?(sitemap_path) do
      conn
      |> put_resp_content_type("application/xml")
      |> send_file(200, sitemap_path)
    else
      conn
      |> put_status(:not_found)
      |> text("Sitemap not yet generated. Please wait for the next scheduled generation.")
    end
  end

  @doc """
  Serves individual sitemap chunk files.
  Files are named like sitemap-00001.xml, sitemap-00002.xml, etc.
  """
  def show(conn, %{"filename" => filename}) do
    # Sanitize filename to prevent directory traversal
    safe_filename = Path.basename(filename)

    # Only allow .xml files
    unless String.ends_with?(safe_filename, ".xml") do
      conn
      |> put_status(:bad_request)
      |> text("Invalid file type")
      |> halt()
    end

    sitemap_path = Path.join(@sitemap_dir, safe_filename)

    if File.exists?(sitemap_path) do
      conn
      |> put_resp_content_type("application/xml")
      |> send_file(200, sitemap_path)
    else
      conn
      |> put_status(:not_found)
      |> text("Sitemap file not found")
    end
  end
end
