defmodule PinchflatWeb.MediaItems.MediaItemController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.MediaDownloadWorker

  def show(conn, %{"id" => id}) do
    media_item =
      id
      |> Media.get_media_item!()
      |> Repo.preload([:source, tasks: [:job]])

    render(conn, :show, media_item: media_item)
  end

  def edit(conn, %{"id" => id}) do
    media_item = Media.get_media_item!(id)
    changeset = Media.change_media_item(media_item)

    render(conn, :edit, media_item: media_item, changeset: changeset)
  end

  def update(conn, %{"id" => id, "media_item" => params}) do
    media_item = Media.get_media_item!(id)

    case Media.update_media_item(media_item, params) do
      {:ok, media_item} ->
        conn
        |> put_flash(:info, "Media Item updated successfully.")
        |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, media_item: media_item, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id} = params) do
    prevent_download = Map.get(params, "prevent_download", false)
    media_item = Media.get_media_item!(id)
    {:ok, _} = Media.delete_media_files(media_item, %{prevent_download: prevent_download})

    conn
    |> put_flash(:info, "Files deleted successfully.")
    |> redirect(to: ~p"/sources/#{media_item.source_id}")
  end

  def force_download(conn, %{"media_item_id" => id}) do
    media_item = Media.get_media_item!(id)

    :ok =
      case MediaDownloadWorker.kickoff_with_task(media_item, %{force: true}) do
        {:ok, _} -> :ok
        {:error, :duplicate_job} -> :ok
        err -> err
      end

    conn
    |> put_flash(:info, "Download task enqueued.")
    |> redirect(to: ~p"/sources/#{media_item.source_id}/media/#{media_item}")
  end

  # See here for details on streaming files and range requests:
  # https://www.zeng.dev/post/2023-http-range-and-play-mp4-in-browser/
  #
  # Uses the UUID instead of the ID to avoid enumeration attacks
  # since streaming is a public endpoint (ie: no auth required)
  def stream(conn, %{"uuid" => uuid}) do
    media_item = Repo.get_by!(MediaItem, uuid: uuid)

    # The filepath is nil once the media's files are deleted, but stream URLs live on in podcast feeds
    if media_item.media_filepath && File.exists?(media_item.media_filepath) do
      file_size = File.stat!(media_item.media_filepath).size
      mime_type = MIME.from_path(media_item.media_filepath)

      case parse_range(conn, file_size) do
        {:ok, {start_pos, end_pos}} ->
          Logger.debug("Streaming media item: #{media_item.uuid} from #{start_pos} to #{end_pos}")
          length = end_pos - start_pos + 1

          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{file_size}")
          |> put_resp_header("content-length", to_string(length))
          |> put_resp_header("content-disposition", content_disposition(media_item.title))
          |> send_file(206, media_item.media_filepath, start_pos, length)

        {:error, :unsatisfiable_range} ->
          Logger.debug("Unsatisfiable range request for media item: #{media_item.uuid}")

          conn
          |> put_resp_header("content-range", "bytes */#{file_size}")
          |> send_resp(416, "Range not satisfiable")

        {:error, :invalid_range} ->
          Logger.debug("Invalid range request for media item: #{media_item.uuid} - serving full file")

          conn
          |> put_resp_content_type(mime_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-range", "bytes 0-#{file_size - 1}/#{file_size}")
          |> put_resp_header("content-length", to_string(file_size))
          |> put_resp_header("content-disposition", content_disposition(media_item.title))
          |> send_file(200, media_item.media_filepath)
      end
    else
      send_resp(conn, 404, "File not found")
    end
  end

  # A missing or malformed header is an `:invalid_range` and gets the whole file, whereas a
  # well-formed range that selects no bytes is an `:unsatisfiable_range`. See RFC7233 section 2.1
  defp parse_range(conn, file_size) do
    with [range_header | _] <- get_req_header(conn, "range"),
         ["bytes", range] <- String.split(range_header, "="),
         [start_pos, end_pos] <- String.split(range, "-") do
      validate_range(parse_range_position(start_pos), parse_range_position(end_pos), file_size)
    else
      _ -> {:error, :invalid_range}
    end
  end

  # eg: "bytes=100-" is everything from the offset onwards
  defp validate_range({:ok, start_pos}, nil, file_size) do
    satisfiable_range(start_pos, file_size - 1)
  end

  # eg: "bytes=-500" is the last 500 bytes, or the whole file if it's smaller than that
  defp validate_range(nil, {:ok, suffix_length}, file_size) do
    satisfiable_range(max(file_size - suffix_length, 0), file_size - 1)
  end

  # eg: "bytes=0-499" is allowed to end past the end of the file
  defp validate_range({:ok, start_pos}, {:ok, end_pos}, file_size) do
    satisfiable_range(start_pos, min(end_pos, file_size - 1))
  end

  defp validate_range(_start_pos, _end_pos, _file_size), do: {:error, :invalid_range}

  # Catches ranges that start at or past the end of the file, ranges that end before they
  # start (eg: "bytes=100-50"), "bytes=-0", and any range on an empty file
  defp satisfiable_range(start_pos, end_pos) when start_pos > end_pos, do: {:error, :unsatisfiable_range}
  defp satisfiable_range(start_pos, end_pos), do: {:ok, {start_pos, end_pos}}

  # Requires the whole position to be a number so that eg: "10abc" isn't treated as 10
  defp parse_range_position(""), do: nil

  defp parse_range_position(position) do
    case Integer.parse(position) do
      {position, ""} -> {:ok, position}
      _ -> :error
    end
  end

  # The title comes from the remote source so it can contain anything. Clients that support RFC6266
  # use the exact title from `filename*` and older ones fall back to an ASCII-only `filename` without
  # control characters (which would make `put_resp_header/3` raise), quotes, or backslashes
  defp content_disposition(title) do
    ascii_title =
      title
      |> String.codepoints()
      |> Enum.map_join(fn
        <<char>> when char < 0x20 or char == 0x7F -> ""
        <<char>> when char in 0x20..0x7E and char not in [?", ?\\] -> <<char>>
        _ -> "_"
      end)

    utf8_title = URI.encode(title, &URI.char_unreserved?/1)

    ~s(inline; filename="#{ascii_title}"; filename*=UTF-8''#{utf8_title})
  end
end
