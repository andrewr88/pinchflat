defmodule PinchflatWeb.Sources.SourceLive.SourceEnableToggle do
  use PinchflatWeb, :live_component

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source

  def render(assigns) do
    ~H"""
    <div>
      <.form :let={f} for={@form} phx-change="update" phx-target={@myself} class="enabled_toggle_form">
        <.input id={"source_#{@source_id}_enabled_input"} field={f[:enabled]} type="toggle" />
      </.form>
    </div>
    """
  end

  def update(assigns, socket) do
    initial_data = %{
      source_id: assigns.source.id,
      form: Sources.change_source(%Source{}, assigns.source)
    }

    socket
    |> assign(initial_data)
    |> then(&{:ok, &1})
  end

  # The toggle only sets `enabled`, so nothing else is taken from the event. Other fields are set
  # elsewhere, and some are the paths of files the app serves and later moves or deletes.
  #
  # A source that's being deleted isn't in the table, but the table can be out of date. Like for a
  # source that's gone, this raises (so the table reloads) rather than enabling it again
  def handle_event("update", %{"source" => source_params}, %{assigns: assigns} = socket) do
    assigns.source_id
    |> Sources.get_source_not_being_deleted!()
    |> Sources.update_source(Map.take(source_params, ["enabled"]))

    {:noreply, socket}
  end
end
