defmodule PinchflatWeb.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Media.FileSyncingWorker
  alias Pinchflat.Sources.SourceDeletionWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Sources.SourceDirectoryUpdateWorker
  alias Pinchflat.Metadata.SourceMetadataStorageWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  @source_path_fields ~w(series_directory nfo_filepath poster_filepath fanart_filepath banner_filepath)a

  setup do
    media_profile = media_profile_fixture()
    Settings.set(onboarding: false)

    {
      :ok,
      %{
        create_attrs: %{
          media_profile_id: media_profile.id,
          collection_type: "channel",
          original_url: "https://www.youtube.com/source/abc123"
        },
        update_attrs: %{
          original_url: "https://www.youtube.com/source/321xyz"
        },
        invalid_attrs: %{original_url: nil, media_profile_id: nil}
      }
    }
  end

  describe "index" do
    # Most of the tests are in `index_table_list_test.exs`
    test "returns 200", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert html_response(conn, 200) =~ "Sources"
    end
  end

  describe "new source" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/sources/new")
      assert html_response(conn, 200) =~ "New Source"
    end

    test "renders correct layout when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = get(conn, ~p"/sources/new")

      refute html_response(conn, 200) =~ "MENU"
    end

    test "preloads some attributes when using a template", %{conn: conn} do
      source = source_fixture(custom_name: "My first source", download_cutoff_date: "2021-01-01")

      conn = get(conn, ~p"/sources/new", %{"template_id" => source.id})
      assert html_response(conn, 200) =~ "New Source"
      assert html_response(conn, 200) =~ "2021-01-01"
      refute html_response(conn, 200) =~ source.custom_name
    end

    test "omits media profiles that are marked for deletion", %{conn: conn} do
      media_profile_fixture(name: "Profile in use")
      media_profile_fixture(name: "Profile being deleted", marked_for_deletion_at: now())

      conn = get(conn, ~p"/sources/new")

      assert html_response(conn, 200) =~ "Profile in use"
      refute html_response(conn, 200) =~ "Profile being deleted"
    end

    # They're in the form's JavaScript, so quotes and backslashes mustn't break out of their strings
    test "puts the media profiles' output templates in the form as a JavaScript object", %{conn: conn} do
      media_profile =
        media_profile_fixture(output_path_template: ~S|/{{ title }} it's "a" \ \' '); alert(1); ('.{{ ext }}|)

      document = conn |> get(~p"/sources/new") |> html_response(200) |> Floki.parse_document!()
      [x_data] = document |> Floki.find("section[x-data*=placeholders]") |> Floki.attribute("x-data")
      [_, placeholders] = Regex.run(~r/placeholders: (.*),\s*inputValue: null/s, x_data)

      assert {:ok, %{} = placeholders} = Phoenix.json_library().decode(placeholders)
      assert placeholders[to_string(media_profile.id)] == media_profile.output_path_template
    end
  end

  describe "create source" do
    test "redirects to show when data is valid", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/sources/#{id}"

      conn = get(conn, ~p"/sources/#{id}")
      assert html_response(conn, 200) =~ "Source"
    end

    test "renders errors when data is invalid", %{conn: conn, invalid_attrs: invalid_attrs} do
      conn = post(conn, ~p"/sources", source: invalid_attrs)
      assert html_response(conn, 200) =~ "New Source"
    end

    test "redirects to onboarding when onboarding", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: create_attrs)

      assert redirected_to(conn) == ~p"/?onboarding=1"
    end

    test "renders correct layout on error when onboarding", %{conn: conn, invalid_attrs: invalid_attrs} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/sources", source: invalid_attrs)

      refute html_response(conn, 200) =~ "MENU"
    end

    test "doesn't set the source's file paths from the request", %{conn: conn, create_attrs: create_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn = post(conn, ~p"/sources", source: Map.merge(create_attrs, file_path_params()))

      assert %{id: id} = redirected_params(conn)
      source = Repo.get!(Source, id)

      assert Map.take(source, @source_path_fields) == Map.new(@source_path_fields, &{&1, nil})
    end
  end

  describe "show source" do
    test "shows no directory update failure when the source has no directory updates", %{conn: conn} do
      source = source_fixture()

      conn = get(conn, ~p"/sources/#{source}")
      refute html_response(conn, 200) =~ "Last directory update failed"
    end

    test "shows the last error when the latest directory update failed", %{conn: conn} do
      source = source_fixture()

      discarded_directory_update_job_fixture(source, [
        "an older error",
        "series_directory: could not determine the new series directory"
      ])

      conn = get(conn, ~p"/sources/#{source}")
      html = html_response(conn, 200)

      assert html =~ "Last directory update failed"
      assert html =~ "series_directory: could not determine the new series directory"
      refute html =~ "an older error"
    end

    test "escapes the error", %{conn: conn} do
      source = source_fixture()
      discarded_directory_update_job_fixture(source, ["<script>alert(1)</script>"])

      conn = get(conn, ~p"/sources/#{source}")
      html = html_response(conn, 200)

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)</script>"
    end

    test "shows no directory update failure when a newer directory update completed", %{conn: conn} do
      source = source_fixture()
      discarded_directory_update_job_fixture(source, ["some error"])
      directory_update_job_fixture(source, state: "completed", completed_at: now())

      conn = get(conn, ~p"/sources/#{source}")
      refute html_response(conn, 200) =~ "Last directory update failed"
    end

    test "shows no directory update failure when a newer directory update is queued", %{conn: conn} do
      source = source_fixture()
      discarded_directory_update_job_fixture(source, ["some error"])
      {:ok, _} = SourceDirectoryUpdateWorker.kickoff_with_task(source)

      conn = get(conn, ~p"/sources/#{source}")
      refute html_response(conn, 200) =~ "Last directory update failed"
    end

    # The source's details come from the remote source, so they mustn't be able to break out of the
    # copy button's JavaScript
    test "copies the source's JSON without putting it in the click handler", %{conn: conn} do
      source = source_fixture(custom_name: ~s|x`${alert(1)}` '"<>|)

      html = conn |> get(~p"/sources/#{source}") |> html_response(200)
      [copy_json] = html |> Floki.parse_document!() |> Floki.find("[data-json]")
      [click_handler] = Floki.attribute(copy_json, "x-on:click")

      assert click_handler =~ "$el.dataset.json"
      refute click_handler =~ source.collection_id
      refute click_handler =~ "alert"
      assert Floki.attribute(copy_json, "data-json") == [pretty_json(Repo.reload!(source))]
      assert html =~ ~s|x`${alert(1)}` &#39;\\&quot;&lt;&gt;|
    end
  end

  describe "edit source" do
    setup [:create_source]

    test "renders form for editing chosen source", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/edit")
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end

    test "omits media profiles that are marked for deletion", %{conn: conn, source: source} do
      media_profile_fixture(name: "Profile in use")
      media_profile_fixture(name: "Profile being deleted", marked_for_deletion_at: now())

      conn = get(conn, ~p"/sources/#{source}/edit")

      assert html_response(conn, 200) =~ "Profile in use"
      refute html_response(conn, 200) =~ "Profile being deleted"
    end

    test "puts the download cutoff date in the form's JavaScript as a string", %{conn: conn} do
      source = source_fixture(download_cutoff_date: "2021-01-01")

      html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)

      assert cutoff_date_scripts(html) ==
               {~s({ cutoffDate: "2021-01-01" }), ~s(cutoffDate = $event.target.value || "2021-01-01")}
    end
  end

  describe "update source" do
    setup [:create_source]

    test "redirects when data is valid", %{conn: conn, source: source, update_attrs: update_attrs} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)

      conn = put(conn, ~p"/sources/#{source}", source: update_attrs)
      assert redirected_to(conn) == ~p"/sources/#{source}"

      conn = get(conn, ~p"/sources/#{source}")
      assert html_response(conn, 200) =~ "https://www.youtube.com/source/321xyz"
    end

    test "renders errors when data is invalid", %{
      conn: conn,
      source: source,
      invalid_attrs: invalid_attrs
    } do
      conn = put(conn, ~p"/sources/#{source}", source: invalid_attrs)
      assert html_response(conn, 200) =~ "Editing \"#{source.custom_name}\""
    end

    test "saves each field on the form", %{conn: conn} do
      expect(YtDlpRunnerMock, :run, 1, &runner_function_mock/5)
      source = source_fixture(fast_index: true)
      %{id: media_profile_id} = media_profile_fixture()

      form_params = %{
        "original_url" => "https://www.youtube.com/source/321xyz",
        "custom_name" => "New name",
        "media_profile_id" => to_string(media_profile_id),
        "index_frequency_minutes" => "120",
        "fast_index" => "false",
        "download_media" => "false",
        "cookie_behaviour" => "all_operations",
        "min_duration_seconds" => "10",
        "max_duration_seconds" => "1000",
        "download_cutoff_date" => "2024-01-01",
        "retention_period_days" => "7",
        "title_filter_regex" => "(?i)^How to Bike$",
        "output_path_template_override" => "/{{ title }}.{{ ext }}"
      }

      # Fails when a field is added to the form, as a reminder to make sure it can be saved
      edit_html = conn |> get(~p"/sources/#{source}/edit") |> html_response(200)
      assert form_field_names(edit_html, "source") == Enum.sort(Map.keys(form_params))

      put(conn, ~p"/sources/#{source}", source: form_params)

      assert %Source{
               original_url: "https://www.youtube.com/source/321xyz",
               custom_name: "New name",
               media_profile_id: ^media_profile_id,
               index_frequency_minutes: 120,
               fast_index: false,
               download_media: false,
               cookie_behaviour: :all_operations,
               min_duration_seconds: 10,
               max_duration_seconds: 1000,
               download_cutoff_date: ~D[2024-01-01],
               retention_period_days: 7,
               title_filter_regex: "(?i)^How to Bike$",
               output_path_template_override: "/{{ title }}.{{ ext }}"
             } = Repo.reload!(source)
    end

    # An invalid date is shown again as it was entered, so it mustn't be able to break out of the form's JavaScript
    test "keeps an invalid download cutoff date inside the form's JavaScript strings", %{conn: conn, source: source} do
      cutoff_date = ~S|x' + alert(1) + '" \ end|
      js_string = Phoenix.json_library().encode!(cutoff_date)

      conn = put(conn, ~p"/sources/#{source}", source: %{download_cutoff_date: cutoff_date})

      assert cutoff_date_scripts(html_response(conn, 200)) ==
               {"{ cutoffDate: #{js_string} }", "cutoffDate = $event.target.value || #{js_string}"}
    end

    # The app serves the files at these paths, and moves or deletes them along with the source
    test "doesn't set the source's file paths from the request", %{conn: conn, source: source} do
      put(conn, ~p"/sources/#{source}", source: Map.put(file_path_params(), "custom_name", "New name"))

      updated_source = Repo.reload!(source)

      assert updated_source.custom_name == "New name"
      assert Map.take(updated_source, @source_path_fields) == Map.take(source, @source_path_fields)
    end
  end

  describe "delete source in all cases" do
    setup [:create_source]

    test "redirects to the sources page", %{conn: conn, source: source} do
      conn = delete(conn, ~p"/sources/#{source}")
      assert redirected_to(conn) == ~p"/sources"
    end

    test "sets marked_for_deletion_at", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")
      assert Repo.reload!(source).marked_for_deletion_at
    end
  end

  describe "delete source when just deleting the records" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "delete source when deleting the records and files" do
    setup [:create_source]

    test "enqueues a job without the delete_files arg", %{conn: conn, source: source} do
      delete(conn, ~p"/sources/#{source}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: SourceDeletionWorker)
    end
  end

  describe "force_download_pending" do
    test "enqueues pending download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, media_filepath: nil})

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_download_pending")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_redownload" do
    test "enqueues re-download tasks", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id, media_downloaded_at: now())

      assert [] = all_enqueued(worker: MediaDownloadWorker)
      post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert [_] = all_enqueued(worker: MediaDownloadWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_redownload")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "force_index" do
    test "forces an index", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [_] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end

    test "forces an index even if one wouldn't normally run", %{conn: conn} do
      source = source_fixture(index_frequency_minutes: 0, last_indexed_at: DateTime.utc_now())

      post(conn, ~p"/sources/#{source.id}/force_index")
      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "deletes pending indexing tasks", %{conn: conn} do
      source = source_fixture()
      {:ok, task} = MediaCollectionIndexingWorker.kickoff_with_task(source)
      job = Repo.preload(task, :job).job

      assert job.state == "available"
      post(conn, ~p"/sources/#{source.id}/force_index")
      assert Repo.reload!(job).state == "cancelled"
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_index")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end

    test "doesn't index a disabled source and asks for it to be enabled", %{conn: conn} do
      source = source_fixture(enabled: false)

      conn = post(conn, ~p"/sources/#{source.id}/force_index")

      refute_enqueued(worker: MediaCollectionIndexingWorker)
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Enable this source to index it."
    end
  end

  describe "force_metadata_refresh" do
    test "forces a metadata refresh", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
      post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert [_] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/force_metadata_refresh")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "sync_files_on_disk" do
    test "forces a file sync", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: FileSyncingWorker)
      post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert [_] = all_enqueued(worker: FileSyncingWorker)
    end

    test "redirects to the source page", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/sync_files_on_disk")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"
    end
  end

  describe "update_directory" do
    # No yt-dlp mock is set up, so this also checks the update itself doesn't run during the request
    test "enqueues a directory update", %{conn: conn} do
      source = source_fixture()

      assert [] = all_enqueued(worker: SourceDirectoryUpdateWorker)
      post(conn, ~p"/sources/#{source.id}/update_directory")
      assert [_] = all_enqueued(worker: SourceDirectoryUpdateWorker, args: %{"id" => source.id})
    end

    test "redirects to the source page with a flash message", %{conn: conn} do
      source = source_fixture()

      conn = post(conn, ~p"/sources/#{source.id}/update_directory")
      assert redirected_to(conn) == ~p"/sources/#{source.id}"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Directory update enqueued. Files will be moved in the background."
    end
  end

  defp create_source(_) do
    source = source_fixture()
    media_item = media_item_with_attachments(%{source_id: source.id})

    %{source: source, media_item: media_item}
  end

  # Points the source's file paths at a file outside the media directory
  defp file_path_params do
    filepath = FilesystemUtils.generate_metadata_tmpfile(:txt)

    @source_path_fields
    |> Map.new(&{to_string(&1), filepath})
    |> Map.put("series_directory", Path.dirname(filepath))
  end

  # The Alpine scripts that hold the download cutoff date: {the x-data, the preset's x-on:change}
  defp cutoff_date_scripts(html) do
    document = Floki.parse_document!(html)
    [x_data] = document |> Floki.find("section[x-data*=cutoffDate]") |> Floki.attribute("x-data")
    preset_select = Floki.find(document, ~s(select[name="download_cutoff_date_preset"]))
    [x_on_change] = Floki.attribute(preset_select, "x-on:change")

    {x_data, x_on_change}
  end

  # What the actions dropdown's "Copy JSON" copies
  defp pretty_json(record) do
    record
    |> Phoenix.json_library().encode!()
    |> Jason.Formatter.pretty_print()
  end

  # The fields of a form's inputs, eg: "custom_name" for `name="source[custom_name]"`
  defp form_field_names(html, param_name) do
    ~r/name="#{param_name}\[(\w+)\]"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp runner_function_mock(_url, :get_source_details, _opts, _ot, _addl) do
    {
      :ok,
      Phoenix.json_library().encode!(%{
        channel: "some channel name",
        channel_id: "some_channel_id_#{:rand.uniform(1_000_000)}",
        playlist_id: "some_playlist_id_#{:rand.uniform(1_000_000)}",
        playlist_title: "some playlist name"
      })
    }
  end

  # Directory updates don't run in these tests, so this queues one and sets its outcome directly
  defp directory_update_job_fixture(source, attrs) do
    {:ok, task} = SourceDirectoryUpdateWorker.kickoff_with_task(source)

    Oban.Job
    |> Repo.get!(task.job_id)
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp discarded_directory_update_job_fixture(source, error_messages) do
    errors = Enum.map(error_messages, &%{attempt: 1, at: now(), error: &1})

    directory_update_job_fixture(source, state: "discarded", discarded_at: now(), errors: errors)
  end
end
