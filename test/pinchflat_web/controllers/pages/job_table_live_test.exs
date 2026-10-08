defmodule PinchflatWeb.Pages.JobTableLiveTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query, warn: false
  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Pages.JobTableLive
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.FastIndexing.FastIndexingWorker

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end

    test "shows records when present", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Subject"
    end

    test "doesn't show records when not in executing state", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job(:scheduled)
      {_source, _media_item, _task, _job} = create_media_item_job(:completed)
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Nothing Here!"
      refute html =~ "Subject"
    end
  end

  describe "job rendering" do
    test "shows worker name", %{conn: conn} do
      {_source, _media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ "Downloading Media"
    end

    test "shows the media item title", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ media_item.title
    end

    test "shows a media item link", %{conn: conn} do
      {_source, media_item, _task, _job} = create_media_item_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{media_item.source_id}/media/#{media_item}"
    end

    test "shows the source custom name", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ source.custom_name
    end

    test "shows a source link", %{conn: conn} do
      {source, _task, _job} = create_source_job()
      {:ok, _view, html} = live_isolated(conn, JobTableLive, session: %{})

      assert html =~ ~p"/sources/#{source.id}"
    end
  end

  describe "job:state events" do
    test "reloads the tasks on the scheduled reload", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, JobTableLive, session: %{})
      assert html =~ "Nothing Here!"

      {_source, media_item, _task, _job} = create_media_item_job()
      for _ <- 1..3, do: PinchflatWeb.Endpoint.broadcast("job:state", "change", nil)

      assert reload_pending?(view)
      refute render(view) =~ media_item.title

      send(view.pid, :reload)

      refute reload_pending?(view)
      assert render(view) =~ media_item.title
    end
  end

  defp create_media_item_job(job_state \\ :executing) do
    source = source_fixture()
    media_item = media_item_fixture(source_id: source.id)
    {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state)])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, media_item, task, job}
  end

  defp create_source_job(job_state \\ :executing) do
    source = source_fixture()
    {:ok, task} = FastIndexingWorker.kickoff_with_task(source)

    Oban.Job
    |> where([j], j.id == ^task.job_id)
    |> Repo.update_all(set: [state: to_string(job_state)])

    job = Repo.get!(Oban.Job, task.job_id)

    {source, task, job}
  end

  defp reload_pending?(view) do
    :sys.get_state(view.pid).socket.assigns.reload_pending
  end
end
