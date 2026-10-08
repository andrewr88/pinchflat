defmodule Pinchflat.Repo.Migrations.AddChannelTabSettingsToSources do
  use Ecto.Migration

  def change do
    alter table(:sources) do
      add :index_videos, :boolean, default: true, null: false
      add :index_shorts, :boolean, default: true, null: false
      add :index_livestreams, :boolean, default: true, null: false
    end
  end
end
