defmodule PinchflatWeb.MediaProfileControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Profiles.MediaProfileDeletionWorker

  @create_attrs %{name: "some name", output_path_template: "output_template.{{ ext }}"}
  @update_attrs %{
    name: "some updated name",
    output_path_template: "new_output_template.{{ ext }}"
  }
  @invalid_attrs %{name: nil, output_path_template: nil}

  setup do
    Settings.set(onboarding: false)

    :ok
  end

  describe "index" do
    test "lists all media_profiles", %{conn: conn} do
      profile = media_profile_fixture()
      conn = get(conn, ~p"/media_profiles")

      assert html_response(conn, 200) =~ "Media Profiles"
      assert html_response(conn, 200) =~ profile.name
    end

    test "omits profiles that have marked_for_deletion_at set", %{conn: conn} do
      profile = media_profile_fixture(marked_for_deletion_at: DateTime.utc_now())
      conn = get(conn, ~p"/media_profiles")
      refute html_response(conn, 200) =~ profile.name
    end

    test "doesn't count sources that are marked for deletion", %{conn: conn} do
      profile = media_profile_fixture()
      source_fixture(media_profile_id: profile.id)
      source_fixture(media_profile_id: profile.id, marked_for_deletion_at: now())

      html = conn |> get(~p"/media_profiles") |> html_response(200)

      assert [source_count] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s(a[href="/media_profiles/#{profile.id}/#tab-sources"]))

      assert String.trim(Floki.text(source_count)) == "1"
    end
  end

  describe "show media_profile" do
    test "lists the profile's sources, except those marked for deletion", %{conn: conn} do
      profile = media_profile_fixture()
      source = source_fixture(media_profile_id: profile.id, custom_name: "Source in use")
      source_fixture(media_profile_id: profile.id, custom_name: "Source being deleted", marked_for_deletion_at: now())

      html = conn |> get(~p"/media_profiles/#{profile}") |> html_response(200)

      assert html =~ ~s(href="/sources/#{source.id}")
      assert html =~ "Source in use"
      refute html =~ "Source being deleted"
    end

    # The name can be anything, so it mustn't be able to break out of the copy button's JavaScript
    test "copies the profile's JSON without putting it in the click handler", %{conn: conn} do
      profile = media_profile_fixture(name: ~s|x`${alert(1)}` '"<>|)

      html = conn |> get(~p"/media_profiles/#{profile}") |> html_response(200)
      [copy_json] = html |> Floki.parse_document!() |> Floki.find("[data-json]")
      [click_handler] = Floki.attribute(copy_json, "x-on:click")

      assert click_handler =~ "$el.dataset.json"
      refute click_handler =~ "alert"
      assert Floki.attribute(copy_json, "data-json") == [pretty_json(Repo.reload!(profile))]
      assert html =~ ~s|x`${alert(1)}` &#39;\\&quot;&lt;&gt;|
    end
  end

  describe "new media_profile" do
    test "renders form", %{conn: conn} do
      conn = get(conn, ~p"/media_profiles/new")
      assert html_response(conn, 200) =~ "New Media Profile"
    end

    test "renders correct layout when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = get(conn, ~p"/media_profiles/new")

      refute html_response(conn, 200) =~ "<span>MENU</span>"
    end
  end

  describe "create media_profile" do
    test "redirects to show when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/media_profiles", media_profile: @create_attrs)

      assert %{id: id} = redirected_params(conn)
      assert redirected_to(conn) == ~p"/media_profiles/#{id}"

      conn = get(conn, ~p"/media_profiles/#{id}")
      assert html_response(conn, 200) =~ "Media Profile"
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/media_profiles", media_profile: @invalid_attrs)
      assert html_response(conn, 200) =~ "New Media Profile"
    end

    test "redirects to onboarding when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/media_profiles", media_profile: @create_attrs)

      assert redirected_to(conn) == ~p"/?onboarding=1"
    end

    test "renders correct layout on error when onboarding", %{conn: conn} do
      Settings.set(onboarding: true)
      conn = post(conn, ~p"/media_profiles", media_profile: @invalid_attrs)

      refute html_response(conn, 200) =~ "MENU"
    end

    # A profile marked for deletion is hidden and can't be given sources
    test "doesn't set marked_for_deletion_at from the request", %{conn: conn} do
      params = Map.put(@create_attrs, :marked_for_deletion_at, "2024-01-01T00:00:00Z")
      conn = post(conn, ~p"/media_profiles", media_profile: params)

      assert %{id: id} = redirected_params(conn)
      assert Repo.get!(MediaProfile, id).marked_for_deletion_at == nil
    end

    test "preloads some attributes when using a template", %{conn: conn} do
      profile = media_profile_fixture(name: "My first profile", download_subs: true, sub_langs: "de")

      conn = get(conn, ~p"/media_profiles/new", %{"template_id" => profile.id})
      assert html_response(conn, 200) =~ "New Media Profile"
      assert html_response(conn, 200) =~ profile.sub_langs
      refute html_response(conn, 200) =~ profile.name
    end
  end

  describe "edit media_profile" do
    setup [:create_media_profile]

    test "renders form for editing chosen media_profile", %{
      conn: conn,
      media_profile: media_profile
    } do
      conn = get(conn, ~p"/media_profiles/#{media_profile}/edit")
      assert html_response(conn, 200) =~ "Editing \"#{media_profile.name}\""
    end

    # Unchecked checkboxes aren't submitted, so without it unchecking every category would keep the old ones
    test "submits a blank SponsorBlock category alongside the checkboxes", %{conn: conn, media_profile: media_profile} do
      html = conn |> get(~p"/media_profiles/#{media_profile}/edit") |> html_response(200)

      assert [hidden_input] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s(input[type="hidden"][name="media_profile[sponsorblock_categories][]"]))

      assert Floki.attribute(hidden_input, "value") == [""]
    end

    # JS-only: the categories are shown based on the `sponsorblockBehaviour` variable, so a preset has to
    # set it rather than the select's value (which doesn't update the variable)
    test "has SponsorBlock presets set the variable the categories' visibility depends on", %{
      conn: conn,
      media_profile: media_profile
    } do
      html = conn |> get(~p"/media_profiles/#{media_profile}/edit") |> html_response(200)

      assert [x_init] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s(select[name="media_profile[sponsorblock_behaviour]"]))
               |> Floki.attribute("x-init")

      assert x_init =~ "$watch('selectedPreset', p => p && (sponsorblockBehaviour = presets[p]))"
      refute x_init =~ "$el.value = presets[p]"
    end
  end

  describe "update media_profile" do
    setup [:create_media_profile]

    test "redirects when data is valid", %{conn: conn, media_profile: media_profile} do
      conn = put(conn, ~p"/media_profiles/#{media_profile}", media_profile: @update_attrs)
      assert redirected_to(conn) == ~p"/media_profiles/#{media_profile}"

      conn = get(conn, ~p"/media_profiles/#{media_profile}")
      assert html_response(conn, 200) =~ "some updated name"
    end

    test "renders errors when data is invalid", %{conn: conn, media_profile: media_profile} do
      conn = put(conn, ~p"/media_profiles/#{media_profile}", media_profile: @invalid_attrs)
      assert html_response(conn, 200) =~ "Editing \"#{media_profile.name}\""
    end

    test "saves each field on the form", %{conn: conn, media_profile: media_profile} do
      form_params = %{
        "name" => "New name",
        "output_path_template" => "/{{ title }}.{{ ext }}",
        "download_subs" => "true",
        "download_auto_subs" => "true",
        "embed_subs" => "true",
        "sub_langs" => "de",
        "download_thumbnail" => "true",
        "embed_thumbnail" => "true",
        "download_source_images" => "true",
        "download_metadata" => "true",
        "embed_metadata" => "true",
        "download_nfo" => "true",
        "sponsorblock_behaviour" => "remove",
        "sponsorblock_categories" => ["sponsor", "intro"],
        "shorts_behaviour" => "exclude",
        "livestream_behaviour" => "only",
        "audio_track" => "de",
        "preferred_resolution" => "720p",
        "media_container" => "mkv",
        "redownload_delay_days" => "7"
      }

      # Fails when a field is added to the form, as a reminder to make sure it can be saved
      edit_html = conn |> get(~p"/media_profiles/#{media_profile}/edit") |> html_response(200)
      assert form_field_names(edit_html, "media_profile") == Enum.sort(Map.keys(form_params))

      put(conn, ~p"/media_profiles/#{media_profile}", media_profile: form_params)

      assert %MediaProfile{
               name: "New name",
               output_path_template: "/{{ title }}.{{ ext }}",
               download_subs: true,
               download_auto_subs: true,
               embed_subs: true,
               sub_langs: "de",
               download_thumbnail: true,
               embed_thumbnail: true,
               download_source_images: true,
               download_metadata: true,
               embed_metadata: true,
               download_nfo: true,
               sponsorblock_behaviour: :remove,
               sponsorblock_categories: ["sponsor", "intro"],
               shorts_behaviour: :exclude,
               livestream_behaviour: :only,
               audio_track: "de",
               preferred_resolution: :"720p",
               media_container: "mkv",
               redownload_delay_days: 7
             } = Repo.reload!(media_profile)
    end

    # A profile marked for deletion is hidden and can't be given sources
    test "doesn't set marked_for_deletion_at from the request", %{conn: conn, media_profile: media_profile} do
      params = Map.put(@update_attrs, :marked_for_deletion_at, "2024-01-01T00:00:00Z")
      put(conn, ~p"/media_profiles/#{media_profile}", media_profile: params)

      updated_media_profile = Repo.reload!(media_profile)

      assert updated_media_profile.name == "some updated name"
      assert updated_media_profile.marked_for_deletion_at == nil
    end

    # The form submits a blank category alongside the checkboxes, so this is what unchecking them all sends
    test "clears the SponsorBlock categories when none are checked", %{conn: conn} do
      media_profile = media_profile_fixture(sponsorblock_categories: ["sponsor", "intro"])

      put(conn, ~p"/media_profiles/#{media_profile}", media_profile: %{"sponsorblock_categories" => [""]})

      assert Repo.reload!(media_profile).sponsorblock_categories == []
    end
  end

  describe "delete media_profile in all cases" do
    setup [:create_media_profile]

    test "redirects to the media_profiles page", %{conn: conn, media_profile: media_profile} do
      conn = delete(conn, ~p"/media_profiles/#{media_profile}")

      assert redirected_to(conn) == ~p"/media_profiles"
    end

    test "sets marked_for_deletion_at", %{conn: conn, media_profile: media_profile} do
      delete(conn, ~p"/media_profiles/#{media_profile}")
      assert Repo.reload!(media_profile).marked_for_deletion_at
    end
  end

  describe "delete media_profile when just deleting the records" do
    setup [:create_media_profile]

    test "enqueues a job without the delete_files arg", %{conn: conn, media_profile: media_profile} do
      delete(conn, ~p"/media_profiles/#{media_profile}")

      assert [%{args: %{"delete_files" => false}}] = all_enqueued(worker: MediaProfileDeletionWorker)
    end
  end

  describe "delete media_profile when deleting the records and files" do
    setup [:create_media_profile]

    setup do
      stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

      :ok
    end

    test "enqueues a job with the delete_files arg", %{conn: conn, media_profile: media_profile} do
      delete(conn, ~p"/media_profiles/#{media_profile}?delete_files=true")

      assert [%{args: %{"delete_files" => true}}] = all_enqueued(worker: MediaProfileDeletionWorker)
    end
  end

  # A profile that's being deleted is hidden everywhere, so it's treated like one that's already gone
  describe "when the media profile is being deleted" do
    setup do
      %{media_profile: media_profile_fixture(marked_for_deletion_at: now())}
    end

    test "show, edit and update return 404", %{conn: conn, media_profile: media_profile} do
      assert_error_sent 404, fn -> get(conn, ~p"/media_profiles/#{media_profile}") end
      assert_error_sent 404, fn -> get(conn, ~p"/media_profiles/#{media_profile}/edit") end
      assert_error_sent 404, fn -> put(conn, ~p"/media_profiles/#{media_profile}", media_profile: @update_attrs) end

      assert Repo.reload!(media_profile).name == media_profile.name
    end

    # Eg: to retry a deletion that failed
    test "can be deleted again, which doesn't queue a second deletion", %{conn: conn, media_profile: media_profile} do
      conn = delete(conn, ~p"/media_profiles/#{media_profile}")
      delete(conn, ~p"/media_profiles/#{media_profile}")

      assert redirected_to(conn) == ~p"/media_profiles"
      assert [_] = all_enqueued(worker: MediaProfileDeletionWorker)
    end
  end

  defp create_media_profile(_) do
    media_profile = media_profile_fixture()

    %{media_profile: media_profile}
  end

  # The fields of a form's inputs, eg: "name" for `name="media_profile[name]"` and
  # "sponsorblock_categories" for `name="media_profile[sponsorblock_categories][]"`
  defp form_field_names(html, param_name) do
    ~r/name="#{param_name}\[(\w+)\](?:\[\])?"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # What the actions dropdown's "Copy JSON" copies
  defp pretty_json(record) do
    record
    |> Phoenix.json_library().encode!()
    |> Jason.Formatter.pretty_print()
  end
end
