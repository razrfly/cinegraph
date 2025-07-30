defmodule Cinegraph.Collaborations.Collaboration do
  use Ecto.Schema
  import Ecto.Changeset

  schema "collaborations" do
    field :person_a_id, :id
    field :person_b_id, :id
    field :collaboration_count, :integer, default: 0
    field :first_collaboration_date, :date
    field :latest_collaboration_date, :date
    field :avg_movie_rating, :decimal
    field :total_revenue, :integer
    field :years_active, {:array, :integer}, default: []
    field :peak_year, :integer
    field :genre_diversity_score, :decimal
    field :role_diversity_score, :decimal
    
    belongs_to :person_a, Cinegraph.Movies.Person, foreign_key: :person_a_id, define_field: false
    belongs_to :person_b, Cinegraph.Movies.Person, foreign_key: :person_b_id, define_field: false
    has_many :details, Cinegraph.Collaborations.CollaborationDetail, foreign_key: :collaboration_id
    
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(collaboration, attrs) do
    collaboration
    |> cast(attrs, [:person_a_id, :person_b_id, :collaboration_count, 
                    :first_collaboration_date, :latest_collaboration_date,
                    :avg_movie_rating, :total_revenue, :years_active, :peak_year,
                    :genre_diversity_score, :role_diversity_score])
    |> validate_required([:person_a_id, :person_b_id, :collaboration_count])
    |> validate_number(:collaboration_count, greater_than_or_equal_to: 0)
    |> validate_person_order()
    |> unique_constraint([:person_a_id, :person_b_id])
  end
  
  defp validate_person_order(changeset) do
    person_a_id = get_field(changeset, :person_a_id)
    person_b_id = get_field(changeset, :person_b_id)
    
    if person_a_id && person_b_id && person_a_id >= person_b_id do
      add_error(changeset, :person_a_id, "must be less than person_b_id")
    else
      changeset
    end
  end
end