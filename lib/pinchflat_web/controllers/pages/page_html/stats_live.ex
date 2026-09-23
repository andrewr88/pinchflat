defmodule Pinchflat.Pages.StatsLive do
  use PinchflatWeb, :live_view
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile

  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-4 md:grid-cols-4">
      <div class="flex flex-col justify-center rounded-sm border px-7.5 py-6 shadow-default border-strokedark bg-boxdark">
        <a href={~p"/media_profiles"} class="flex flex-col items-center py-2">
          <span class="text-md font-medium">
            Media <.pluralize count={@media_profile_count} word="Profile" />
          </span>
          <h4 class="text-title-md font-bold text-white">
            <.localized_number number={@media_profile_count} />
          </h4>
        </a>
      </div>
      <div class="flex flex-col justify-center rounded-sm border px-7.5 py-6 shadow-default border-strokedark bg-boxdark">
        <a href={~p"/sources"} class="flex flex-col items-center py-2">
          <span class="text-md font-medium">
            <.pluralize count={@source_count} word="Source" />
          </span>
          <h4 class="text-title-md font-bold text-white">
            <.localized_number number={@source_count} />
          </h4>
        </a>
      </div>
      <div class="flex flex-col justify-center rounded-sm border px-7.5 py-6 shadow-default border-strokedark bg-boxdark">
        <span class="flex flex-col items-center py-2">
          <span class="text-md font-medium">
            <.pluralize count={@media_item_count} word="Download" />
          </span>
          <h4 class="text-title-md font-bold text-white">
            <.localized_number number={@media_item_count} />
          </h4>
        </span>
      </div>
      <div class="flex flex-col justify-center rounded-sm border px-7.5 py-6 shadow-default border-strokedark bg-boxdark">
        <span class="flex flex-col items-center py-2">
          <span class="text-md font-medium">Library Size</span>
          <h4 class="text-title-md font-bold text-white">
            <.readable_filesize byte_size={@media_item_size} />
          </h4>
        </span>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: PinchflatWeb.Endpoint.subscribe("job:state")

    {:ok, assign(socket, Map.put(fetch_stats(), :reload_pending, false))}
  end

  def handle_info(%{topic: "job:state", event: "change"}, %{assigns: %{reload_pending: true}} = socket) do
    {:noreply, socket}
  end

  # Jobs change state in bursts, so coalesce them into at most one reload per second
  def handle_info(%{topic: "job:state", event: "change"}, socket) do
    Process.send_after(self(), :reload, 1_000)

    {:noreply, assign(socket, reload_pending: true)}
  end

  def handle_info(:reload, socket) do
    {:noreply, assign(socket, Map.put(fetch_stats(), :reload_pending, false))}
  end

  defp fetch_stats do
    downloaded_media_items = where(MediaQuery.new(), ^MediaQuery.downloaded())

    %{
      media_profile_count: Repo.aggregate(MediaProfile, :count, :id),
      source_count: Repo.aggregate(Source, :count, :id),
      media_item_size: Repo.aggregate(downloaded_media_items, :sum, :media_size_bytes),
      media_item_count: Repo.aggregate(downloaded_media_items, :count, :id)
    }
  end
end
