defmodule Pinchflat.Lifecycle.Notifications.SourceNotifications do
  @moduledoc """
  Contains utilities for sending notifications about sources
  """

  require Logger

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo

  # SQLite limits how many parameters a query can have
  @media_item_ids_per_query 1_000

  @doc """
  Sends a notification about media items that were just created for a source (eg: by indexing it),
  counting the ones that are pending download or already downloaded. Nothing is sent if that's none
  of them or the source is set to not download media.

  Returns :ok
  """
  def send_new_media_notification_for_media_items(servers, source, media_items) do
    send_new_media_notification(servers, source, relevant_media_item_count(source, media_items))
  end

  @doc """
  Sends a notification if the count of new media items has changed

  Returns :ok
  """
  def send_new_media_notification(_, _, count) when count <= 0, do: :ok

  def send_new_media_notification(servers, source, changed_count) do
    media_items = if changed_count == 1, do: "media item", else: "media items"

    opts = [
      title: "[Pinchflat] New media found",
      body: "Found #{changed_count} new #{media_items} for #{source.custom_name}. Downloading them now"
    ]

    case backend_runner().run(servers, opts) do
      {:ok, _} ->
        Logger.info("Sent new media notification for source #{source.id}")

      {:error, :no_servers} ->
        Logger.info("No notification servers provided for source #{source.id}")

      # The command's output has already been logged when it failed
      {:error, _} ->
        Logger.error("Failed to send new media notification for source #{source.id}")
    end

    :ok
  end

  # A source's first index can create thousands of media items so they're counted in batches
  defp relevant_media_item_count(source, media_items) do
    if source.download_media do
      media_items
      |> Enum.map(& &1.id)
      |> Enum.chunk_every(@media_item_ids_per_query)
      |> Enum.map(&relevant_media_item_count_for_ids(source, &1))
      |> Enum.sum()
    else
      0
    end
  end

  defp relevant_media_item_count_for_ids(source, media_item_ids) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(
      ^dynamic(
        [mi],
        ^MediaQuery.for_source(source) and mi.id in ^media_item_ids and
          (^MediaQuery.pending() or ^MediaQuery.downloaded())
      )
    )
    |> Repo.aggregate(:count)
  end

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
