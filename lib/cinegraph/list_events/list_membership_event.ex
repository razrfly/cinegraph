defmodule Cinegraph.ListEvents.ListMembershipEvent do
  @moduledoc """
  One addition/removal event for a film against a canonical list edition (#1115).

  Records the ground truth the prediction product needs: *when* a film was added
  to (or removed from) a list edition — not just current-union membership. See
  `Cinegraph.ListEvents.ListMembershipEvents` for the context API.

  Append-only by convention. `movie_id` is NULLABLE: an unmatched scrape lives in
  `match_state == "pending"` carrying its raw identity (`raw_title`/`raw_year`/
  `raw_imdb_id`) until a later pass resolves it. The two `unique_constraint`s map
  to the partial unique indexes that give matched and pending rows separate
  idempotency keys.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(added removed)
  @match_states ~w(matched pending)

  schema "list_membership_events" do
    field :source_key, :string
    field :event_type, :string
    field :event_edition, :string
    field :event_date, :date
    field :match_state, :string, default: "pending"
    field :raw_title, :string
    field :raw_year, :integer
    field :raw_imdb_id, :string
    field :source_url, :string
    field :provenance, :map, default: %{}

    belongs_to :movie, Cinegraph.Movies.Movie

    timestamps(type: :utc_datetime)
  end

  @required_fields [:source_key, :event_type, :event_edition, :match_state]
  @optional_fields [
    :movie_id,
    :event_date,
    :raw_title,
    :raw_year,
    :raw_imdb_id,
    :source_url,
    :provenance
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:match_state, @match_states)
    |> validate_match_state_consistency()
    |> foreign_key_constraint(:movie_id)
    |> unique_constraint([:source_key, :movie_id, :event_type, :event_edition],
      name: :lme_matched_unique_idx
    )
    |> unique_constraint(
      [:source_key, :event_type, :event_edition, :raw_imdb_id, :raw_title, :raw_year],
      name: :lme_pending_unique_idx
    )
  end

  # A matched row must point at a movie; a pending row must keep at least one raw
  # identity field so it can be re-matched and is never identity-less.
  defp validate_match_state_consistency(changeset) do
    case get_field(changeset, :match_state) do
      "matched" ->
        if get_field(changeset, :movie_id) do
          changeset
        else
          add_error(changeset, :movie_id, "is required when match_state is matched")
        end

      "pending" ->
        if get_field(changeset, :raw_imdb_id) || get_field(changeset, :raw_title) do
          changeset
        else
          add_error(changeset, :raw_title, "raw identity is required when match_state is pending")
        end

      _ ->
        changeset
    end
  end

  def event_types, do: @event_types
  def match_states, do: @match_states
end
