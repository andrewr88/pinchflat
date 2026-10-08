defmodule Pinchflat.Profiles.MediaProfileDeletionWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfileDeletionWorker
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> :ok end)

    {:ok, %{profile: media_profile_fixture()}}
  end

  describe "kickoff/3" do
    test "starts the worker", %{profile: profile} do
      assert [] = all_enqueued(worker: MediaProfileDeletionWorker)
      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile)
      assert [_] = all_enqueued(worker: MediaProfileDeletionWorker)
    end

    test "can be called with additional job arguments", %{profile: profile} do
      job_args = %{"delete_files" => true}

      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile, job_args)

      assert_enqueued(worker: MediaProfileDeletionWorker, args: %{"id" => profile.id, "delete_files" => true})
    end

    test "does not enqueue the same deletion twice", %{profile: profile} do
      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile, %{"delete_files" => true})
      assert {:ok, _} = MediaProfileDeletionWorker.kickoff(profile, %{"delete_files" => true})

      assert [_] = all_enqueued(worker: MediaProfileDeletionWorker)
    end
  end

  describe "perform/1" do
    test "deletes the profile, sources, and media but leaves the files", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_with_attachments(%{source_id: source.id})

      perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
      assert File.exists?(media_item.media_filepath)
    end

    test "deletes the profile, sources, and media and files if specified", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item = media_item_with_attachments(%{source_id: source.id})

      perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(source) end
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(media_item) end
      refute File.exists?(media_item.media_filepath)
    end

    # eg: the deletion was submitted twice
    test "does nothing if the profile has already been deleted", %{profile: profile} do
      assert {:ok, _} = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})
      assert :ok = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})
    end

    test "does nothing if another job deletes the profile while this one is deleting it", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item_with_attachments(%{source_id: source.id})

      expect(UserScriptRunnerMock, :run, fn :media_deleted, media_item ->
        Repo.delete!(media_item)
        Repo.delete!(source)
        Repo.delete!(profile)
      end)

      assert :ok = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})
    end

    # eg: one of its sources is being deleted by itself too
    test "fails so it's retried if another job deletes some of its records first", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item_with_attachments(%{source_id: source.id})
      expect(UserScriptRunnerMock, :run, fn :media_deleted, media_item -> Repo.delete!(media_item) end)

      assert_raise Ecto.StaleEntryError, fn ->
        perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})
      end

      assert Repo.reload!(profile)
    end

    # Deleting the source would cancel it, which kills it partway through moving the files
    test "waits for a directory update that's running for one of its sources", %{profile: profile} do
      source_fixture(%{media_profile_id: profile.id})
      source = source_fixture(%{media_profile_id: profile.id})
      {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)
      Repo.update_all(where(Oban.Job, id: ^task.job_id), set: [state: "executing"])

      assert {:snooze, _} = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})

      assert Repo.reload!(profile)
      assert [_, _] = Repo.all(where(Source, media_profile_id: ^profile.id))
      assert Repo.get!(Oban.Job, task.job_id).state == "executing"
    end

    # It hasn't moved anything yet
    test "cancels a queued directory update", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)

      assert {:ok, _} = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id})

      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert Repo.get!(Oban.Job, task.job_id).state == "cancelled"
    end

    test "fails so it's retried if a source is added to the profile while it's being deleted", %{profile: profile} do
      source = source_fixture(%{media_profile_id: profile.id})
      media_item_with_attachments(%{source_id: source.id})
      # Runs while the existing source's media is being deleted
      expect(UserScriptRunnerMock, :run, fn :media_deleted, _ -> source_fixture(%{media_profile_id: profile.id}) end)

      assert {:error, _} = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})
      assert Repo.reload!(profile)

      assert {:ok, _} = perform_job(MediaProfileDeletionWorker, %{"id" => profile.id, "delete_files" => true})
      assert_raise Ecto.NoResultsError, fn -> Repo.reload!(profile) end
      assert [] = Repo.all(where(Source, media_profile_id: ^profile.id))
    end
  end
end
