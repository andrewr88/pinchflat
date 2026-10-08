defmodule PinchflatWeb.MediaProfiles.MediaProfileController do
  use PinchflatWeb, :controller
  use Pinchflat.Sources.SourcesQuery
  use Pinchflat.Profiles.ProfilesQuery

  alias Pinchflat.Repo
  alias Pinchflat.Profiles
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Profiles.MediaProfileDeletionWorker

  # Only the profile form's fields are taken from the request. The app sets the others itself,
  # eg: marked_for_deletion_at, which hides the profile and keeps sources off it until it's deleted
  @form_fields ~w(
    name
    output_path_template
    download_subs
    embed_subs
    download_auto_subs
    sub_langs
    audio_track
    download_thumbnail
    embed_thumbnail
    download_metadata
    embed_metadata
    shorts_behaviour
    livestream_behaviour
    preferred_resolution
    media_container
    redownload_delay_days
    download_nfo
    download_source_images
    sponsorblock_behaviour
    sponsorblock_categories
  )

  def index(conn, _params) do
    media_profiles_query =
      from mp in MediaProfile,
        as: :media_profile,
        where: is_nil(mp.marked_for_deletion_at),
        order_by: [asc: mp.name],
        select: map(mp, ^MediaProfile.__schema__(:fields)),
        select_merge: %{
          source_count:
            subquery(
              from s in Source,
                where: s.media_profile_id == parent_as(:media_profile).id,
                where: is_nil(s.marked_for_deletion_at),
                select: count(s.id)
            )
        }

    render(conn, :index, media_profiles: Repo.all(media_profiles_query))
  end

  def new(conn, params) do
    # Preload an existing media profile for faster creation
    %MediaProfile{} =
      cs_struct =
      case to_string(params["template_id"]) do
        "" -> %MediaProfile{}
        template_id -> Repo.get(MediaProfile, template_id) || %MediaProfile{}
      end

    render(conn, :new,
      layout: get_onboarding_layout(),
      changeset:
        Profiles.change_media_profile(%MediaProfile{
          cs_struct
          | id: nil,
            name: nil,
            marked_for_deletion_at: nil
        })
    )
  end

  def create(conn, %{"media_profile" => media_profile_params}) do
    case Profiles.create_media_profile(Map.take(media_profile_params, @form_fields)) do
      {:ok, media_profile} ->
        redirect_location =
          if Settings.get!(:onboarding), do: ~p"/?onboarding=1", else: ~p"/media_profiles/#{media_profile}"

        conn
        |> put_flash(:info, "Media profile created successfully.")
        |> redirect(to: redirect_location)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset, layout: get_onboarding_layout())
    end
  end

  def show(conn, %{"id" => id}) do
    media_profile = Profiles.get_media_profile!(id)

    # Sources that are being deleted are hidden, like on the sources page
    sources =
      SourcesQuery.new()
      |> where(^SourcesQuery.for_media_profile(media_profile))
      |> where([s], is_nil(s.marked_for_deletion_at))
      |> order_by(asc: :custom_name)
      |> Repo.all()

    render(conn, :show, media_profile: media_profile, sources: sources)
  end

  def edit(conn, %{"id" => id}) do
    media_profile = Profiles.get_media_profile!(id)
    changeset = Profiles.change_media_profile(media_profile)

    render(conn, :edit, media_profile: media_profile, changeset: changeset)
  end

  def update(conn, %{"id" => id, "media_profile" => media_profile_params}) do
    media_profile = Profiles.get_media_profile!(id)

    case Profiles.update_media_profile(media_profile, Map.take(media_profile_params, @form_fields)) do
      {:ok, media_profile} ->
        conn
        |> put_flash(:info, "Media profile updated successfully.")
        |> redirect(to: ~p"/media_profiles/#{media_profile}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, media_profile: media_profile, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    # This awkward comparison converts the string to a boolean
    delete_files = Map.get(params, "delete_files", "") == "true"
    media_profile = Profiles.get_media_profile!(id)

    {:ok, _} = Profiles.update_media_profile(media_profile, %{marked_for_deletion_at: DateTime.utc_now()})
    MediaProfileDeletionWorker.kickoff(media_profile, %{delete_files: delete_files})

    conn
    |> put_flash(:info, "Media Profile deletion started. This may take a while to complete.")
    |> redirect(to: ~p"/media_profiles")
  end

  defp get_onboarding_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end
end
