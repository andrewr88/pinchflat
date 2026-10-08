defmodule Pinchflat.Repo.Migrations.AddIncompleteFirstIndexCountToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :incomplete_first_index_count, :integer, default: 0, null: false
    end
  end
end
