defmodule Cinegraph.Cultural.UserList do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  schema "user_lists" do
    field :source_platform, :string
    field :external_list_id, :string
    field :name, :string
    field :creator_name, :string
    field :creator_reputation, :float
    field :follower_count, :integer
    field :like_count, :integer
    field :item_count, :integer
    field :quality_score, :float
    field :spam_score, :float

    timestamps()
  end

  @source_platforms ~w(tmdb letterboxd imdb)

  @doc false
  def changeset(user_list, attrs) do
    user_list
    |> cast(attrs, [
      :source_platform, :external_list_id, :name, :creator_name,
      :creator_reputation, :follower_count, :like_count, :item_count,
      :quality_score, :spam_score
    ])
    |> validate_required([:source_platform])
    |> validate_inclusion(:source_platform, @source_platforms)
    |> validate_number(:creator_reputation, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:quality_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:spam_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:follower_count, greater_than_or_equal_to: 0)
    |> validate_number(:like_count, greater_than_or_equal_to: 0)
    |> validate_number(:item_count, greater_than_or_equal_to: 0)
  end
end