defmodule PinchflatWeb.Sources.SourceController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  # Only the source form's fields are taken from the request. The app sets the others itself,
  # eg: the paths of the files it writes, which it serves and later moves or deletes
  @form_fields ~w(
    original_url
    custom_name
    media_profile_id
    index_frequency_minutes
    fast_index
    index_videos
    index_shorts
    index_livestreams
    download_media
    cookie_behaviour
    min_duration_seconds
    max_duration_seconds
    download_cutoff_date
    retention_period_days
    title_filter_regex
    output_path_template_override
  )

  def index(conn, _params) do
    render(conn, :index)
  end

  def new(conn, params) do
    # This lets me preload the settings from another source for more efficient creation
    %Source{} =
      cs_struct =
      case to_string(params["template_id"]) do
        "" -> %Source{}
        template_id -> Repo.get(Source, template_id) || %Source{}
      end

    render(conn, :new,
      media_profiles: media_profiles(),
      layout: get_onboarding_layout(),
      # Most of these don't actually _need_ to be nullified at this point,
      # but if I don't do it now I know it'll bite me
      changeset:
        Sources.change_source(%Source{
          cs_struct
          | id: nil,
            uuid: nil,
            custom_name: nil,
            description: nil,
            collection_name: nil,
            collection_id: nil,
            collection_type: nil,
            original_url: nil,
            marked_for_deletion_at: nil
        })
    )
  end

  def create(conn, %{"source" => source_params}) do
    case Sources.create_source(Map.take(source_params, @form_fields)) do
      {:ok, source} ->
        redirect_location =
          if Settings.get!(:onboarding), do: ~p"/?onboarding=1", else: ~p"/sources/#{source}"

        conn
        |> put_flash(:info, "Source created successfully.")
        |> redirect(to: redirect_location)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new,
          changeset: changeset,
          media_profiles: media_profiles(),
          layout: get_onboarding_layout()
        )
    end
  end

  def show(conn, %{"id" => id}) do
    source = Repo.preload(Sources.get_source_not_being_deleted!(id), :media_profile)

    pending_tasks =
      source
      |> Tasks.list_tasks_for(nil, [:executing, :available, :scheduled, :retryable])
      |> Repo.preload(:job)

    render(conn, :show,
      source: source,
      pending_tasks: pending_tasks,
      latest_directory_update_job: SourceDirectoryUpdateWorker.latest_job_for(source)
    )
  end

  def edit(conn, %{"id" => id}) do
    source = Sources.get_source_not_being_deleted!(id)
    changeset = Sources.change_source(source)

    render(conn, :edit, source: source, changeset: changeset, media_profiles: media_profiles())
  end

  def update(conn, %{"id" => id, "source" => source_params}) do
    source = Sources.get_source_not_being_deleted!(id)

    case Sources.update_source(source, Map.take(source_params, @form_fields)) do
      {:ok, source} ->
        conn
        |> put_flash(:info, "Source updated successfully.")
        |> redirect(to: ~p"/sources/#{source}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit,
          source: source,
          changeset: changeset,
          media_profiles: media_profiles()
        )
    end
  end

  # Unlike the other actions, this works for a source that's already being deleted, eg: to retry a
  # deletion that failed. The same deletion isn't queued again while it's still queued or running
  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    source = Sources.get_source!(id)

    {:ok, _} = Sources.update_source(source, %{marked_for_deletion_at: DateTime.utc_now()})
    SourceDeletionWorker.kickoff(source, %{delete_files: delete_files})

    conn
    |> put_flash(:info, "Source deletion started. This may take a while to complete.")
    |> redirect(to: ~p"/sources")
  end

  def force_download_pending(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing download of pending media items.",
      &DownloadingHelpers.enqueue_pending_download_tasks/1
    )
  end

  def force_redownload(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Forcing re-download of downloaded media items.",
      &DownloadingHelpers.kickoff_redownload_for_existing_media/1
    )
  end

  # A disabled source isn't indexed (see `MediaCollectionIndexingWorker`) so don't say it's been enqueued
  def force_index(conn, %{"source_id" => id}) do
    case Sources.get_source_not_being_deleted!(id) do
      %Source{enabled: true} = source ->
        wrap_forced_action(
          conn,
          source,
          "Index enqueued.",
          &SlowIndexingHelpers.kickoff_indexing_task(&1, %{force: true})
        )

      source ->
        conn
        |> put_flash(:error, "Enable this source to index it.")
        |> redirect(to: ~p"/sources/#{source}")
    end
  end

  def force_metadata_refresh(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Metadata refresh enqueued.",
      &SourceMetadataStorageWorker.kickoff_with_task/1
    )
  end

  def sync_files_on_disk(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "File sync enqueued.",
      &FileSyncingWorker.kickoff_with_task/1
    )
  end

  def update_directory(conn, %{"source_id" => id}) do
    wrap_forced_action(
      conn,
      id,
      "Directory update enqueued. Files will be moved in the background.",
      &SourceDirectoryUpdateWorker.kickoff_with_task/1
    )
  end

  defp wrap_forced_action(conn, %Source{} = source, message, fun) do
    fun.(source)

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/sources/#{source}")
  end

  # A source that's being deleted 404s like one that's gone. Eg: a directory update would make its deletion wait
  defp wrap_forced_action(conn, source_id, message, fun) do
    wrap_forced_action(conn, Sources.get_source_not_being_deleted!(source_id), message, fun)
  end

  # Profiles marked for deletion are left out since moving a source onto one would get it deleted too
  defp media_profiles do
    MediaProfile
    |> where([mp], is_nil(mp.marked_for_deletion_at))
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp get_onboarding_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end
end
