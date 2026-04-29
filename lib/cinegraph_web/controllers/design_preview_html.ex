defmodule CinegraphWeb.DesignPreviewHTML do
  @moduledoc """
  Templates for the Cinegraph Neutral design preview.

  See the `design_preview_html` directory for templates.
  """
  use CinegraphWeb, :html

  alias CinegraphWeb.NeutralComponents
  alias CinegraphWeb.NeutralV2Components

  embed_templates "design_preview_html/*"
end
