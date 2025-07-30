defmodule Cinegraph.Collaborations.PersonRelationship do
  use Ecto.Schema
  import Ecto.Changeset

  schema "person_relationships" do
    field :from_person_id, :id
    field :to_person_id, :id
    field :degree, :integer
    field :path_count, :integer, default: 1
    field :shortest_path, {:array, :integer}
    field :strongest_connection_score, :decimal
    field :calculated_at, :utc_datetime
    field :expires_at, :utc_datetime
    
    belongs_to :from_person, Cinegraph.Movies.Person, foreign_key: :from_person_id, define_field: false
    belongs_to :to_person, Cinegraph.Movies.Person, foreign_key: :to_person_id, define_field: false
  end

  @doc false
  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, [:from_person_id, :to_person_id, :degree, :path_count,
                    :shortest_path, :strongest_connection_score, 
                    :calculated_at, :expires_at])
    |> validate_required([:from_person_id, :to_person_id, :degree, :shortest_path])
    |> validate_number(:degree, greater_than_or_equal_to: 1, less_than_or_equal_to: 6)
    |> validate_number(:path_count, greater_than_or_equal_to: 1)
    |> validate_path_includes_endpoints()
    |> foreign_key_constraint(:from_person_id)
    |> foreign_key_constraint(:to_person_id)
    |> unique_constraint([:from_person_id, :to_person_id])
  end
  
  defp validate_path_includes_endpoints(changeset) do
    from_id = get_field(changeset, :from_person_id)
    to_id = get_field(changeset, :to_person_id)
    path = get_field(changeset, :shortest_path) || []
    
    cond do
      length(path) < 2 ->
        add_error(changeset, :shortest_path, "must have at least 2 people")
      from_id && to_id && (List.first(path) != from_id || List.last(path) != to_id) ->
        add_error(changeset, :shortest_path, "must start with from_person and end with to_person")
      true ->
        changeset
    end
  end
end