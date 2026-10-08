defmodule PinchflatWeb.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PinchflatWeb.Telemetry

  describe "job_state_change_broadcast/4" do
    test "tells subscribers that a job's state changed" do
      PinchflatWeb.Endpoint.subscribe("job:state")

      Telemetry.job_state_change_broadcast([:oban, :job, :stop], %{}, %{}, [])

      assert_receive %Phoenix.Socket.Broadcast{topic: "job:state", event: "change"}
    end

    # `:telemetry` permanently detaches a handler that raises, and then the UI would never hear about job changes
    test "stays attached and logs the reason if it can't broadcast (eg: the PubSub hasn't started yet)" do
      # The test env only logs critical messages so let this module's logging through
      Logger.put_module_level(Telemetry, :all)
      event = [:pinchflat, :test, :job_state_change]
      handler_id = "job-state-change-broadcast-test"

      :ok =
        :telemetry.attach(handler_id, event, &Telemetry.job_state_change_broadcast/4, pubsub_server: NotStarted.PubSub)

      on_exit(fn ->
        Logger.delete_module_level(Telemetry)
        :telemetry.detach(handler_id)
      end)

      log = capture_log(fn -> :telemetry.execute(event, %{}, %{}) end)

      assert [%{id: ^handler_id}] = :telemetry.list_handlers(event)
      assert log =~ "NotStarted.PubSub"
    end
  end
end
