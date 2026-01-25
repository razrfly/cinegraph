defmodule Cinegraph.Calibration.ReferenceList do
  @moduledoc """
  Schema for calibration reference lists (e.g., IMDb Top 250, 1001 Movies, AFI 100).

  These lists serve as "ground truth" for calibrating the Cinegraph scoring system.
  By comparing our scores against these authoritative rankings, we can tune weights
  and normalization to achieve better correlation with established film quality metrics.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cinegraph.Slugs.SlugUtils

  @list_types ~w(ranked unranked scored)

  schema "calibration_reference_lists" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :source_url, :string
    field :list_type, :string, default: "ranked"
    field :total_items, :integer
    field :last_synced_at, :utc_datetime

    has_many :references, Cinegraph.Calibration.Reference, foreign_key: :reference_list_id

    timestamps()
  end

  @required_fields ~w(name slug)a
  @optional_fields ~w(description source_url list_type total_items last_synced_at)a

  def changeset(reference_list, attrs) do
    reference_list
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:list_type, @list_types)
    |> unique_constraint(:slug)
    |> generate_slug()
  end

  defp generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, SlugUtils.slugify(name))
        end

      _ ->
        changeset
    end
  end

  @doc """
  Known reference list definitions with metadata.
  """
  def known_lists do
    %{
      "imdb-top-250" => %{
        name: "IMDb Top 250",
        description: "IMDb's top 250 movies based on user ratings with Bayesian average",
        source_url: "https://www.imdb.com/chart/top/",
        list_type: "ranked",
        total_items: 250
      },
      "1001-movies" => %{
        name: "1001 Movies You Must See Before You Die",
        description: "Curated list from the book series, updated annually",
        source_url: "https://en.wikipedia.org/wiki/1001_Movies_You_Must_See_Before_You_Die",
        list_type: "unranked",
        # total_items set dynamically during import from canonical_sources
        total_items: nil
      },
      "afi-100" => %{
        name: "AFI's 100 Years...100 Movies",
        description: "American Film Institute's list of greatest American films",
        source_url: "https://www.afi.com/afis-100-years-100-movies/",
        list_type: "ranked",
        total_items: 100
      },
      "sight-and-sound-2022" => %{
        name: "Sight & Sound Greatest Films 2022",
        description: "BFI's decennial critics' poll of the greatest films",
        source_url: "https://www.bfi.org.uk/sight-and-sound/greatest-films-all-time",
        list_type: "ranked",
        total_items: 100
      },
      "letterboxd-top-250" => %{
        name: "Letterboxd Top 250",
        description: "Community-driven ranking based on Letterboxd ratings",
        source_url: "https://letterboxd.com/dave/list/official-top-250-narrative-feature-films/",
        list_type: "ranked",
        # total_items set to nil - no import function exists yet
        total_items: nil
      },
      "criterion-collection" => %{
        name: "Criterion Collection",
        description: "Films selected by Criterion for their artistic importance",
        source_url: "https://www.criterion.com/shop/browse/list",
        list_type: "unranked",
        total_items: nil
      }
    }
  end
end
