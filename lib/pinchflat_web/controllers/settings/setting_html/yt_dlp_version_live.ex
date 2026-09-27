defmodule Pinchflat.Settings.YtDlpVersionLive do
  use PinchflatWeb, :live_view

  alias Pinchflat.YtDlp.Updater

  def render(assigns) do
    ~H"""
    <div>
      <p>
        Installed version: <span class="font-mono text-black dark:text-white">{@installed_version || "Unknown"}</span>
      </p>
      <p class="mt-2 flex items-center gap-1">
        <.async_result :let={latest_version} assign={@latest_version}>
          <:loading>Checking…</:loading>
          <:failed>Couldn't check for updates</:failed>
          <%= if update_available?(@installed_version, latest_version) do %>
            <.icon name="hero-arrow-up-circle-solid" class="text-meta-6" />
            <span class="text-black dark:text-white">Update available: {latest_version}</span>
          <% else %>
            <.icon name="hero-check-circle-solid" class="text-meta-3" /> Up to date (latest release: {latest_version})
          <% end %>
        </.async_result>
      </p>

      <.button
        type="button"
        class="mt-4 w-full sm:w-auto"
        rounding="rounded-lg"
        disabled={@updating}
        phx-click="update_yt_dlp"
      >
        <.icon :if={@updating} name="hero-arrow-path" class="mr-2 h-5 w-5 animate-spin" />
        {if @updating, do: "Updating…", else: "Update now"}
      </.button>

      <div :if={@update_result} class="mt-4">
        <%= case @update_result do %>
          <% {:ok, version} -> %>
            <p class="flex items-center gap-1">
              <.icon name="hero-check-circle-solid" class="text-meta-3" /> Update complete. Installed version: {version}
            </p>
          <% {:error, {:version, output}} -> %>
            <.update_failure message="Update ran, but couldn't read the installed version" output={output} />
          <% {:error, output} -> %>
            <.update_failure message="Update failed" output={output} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :message, :string, required: true
  attr :output, :string, required: true

  defp update_failure(assigns) do
    ~H"""
    <p class="flex items-center gap-1">
      <.icon name="hero-exclamation-circle-solid" class="text-red-500" /> {@message}
    </p>
    <pre class="mt-2 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-sm p-4 font-mono text-sm dark:bg-meta-4">{@output}</pre>
    """
  end

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(installed_version: Settings.get!(:yt_dlp_version), updating: false, update_result: nil)
      |> assign_async(:latest_version, &fetch_latest_version/0)

    {:ok, socket}
  end

  # Guards against a double click starting a second update while one is running
  def handle_event("update_yt_dlp", _params, %{assigns: %{updating: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("update_yt_dlp", _params, socket) do
    socket =
      socket
      |> assign(updating: true, update_result: nil)
      |> start_async(:update_yt_dlp, &Updater.update_and_record_version/0)

    {:noreply, socket}
  end

  def handle_async(:update_yt_dlp, {:ok, result}, socket) do
    {:noreply, finish_update(socket, result)}
  end

  def handle_async(:update_yt_dlp, {:exit, reason}, socket) do
    {:noreply, finish_update(socket, {:error, Exception.format_exit(reason)})}
  end

  # The version is recorded even if the update fails, so always re-read it
  defp finish_update(socket, result) do
    assign(socket, updating: false, update_result: result, installed_version: Settings.get!(:yt_dlp_version))
  end

  defp fetch_latest_version do
    with {:ok, latest_version} <- Updater.latest_version() do
      {:ok, %{latest_version: latest_version}}
    end
  end

  # yt-dlp versions are dates (eg: 2025.09.26) so they can be compared as strings
  defp update_available?(nil, _latest_version), do: true
  defp update_available?(installed_version, latest_version), do: latest_version > installed_version
end
