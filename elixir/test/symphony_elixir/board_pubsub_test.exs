defmodule SymphonyElixir.BoardPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.BoardPubSub

  test "subscribe and broadcast_update deliver board updates" do
    assert :ok = BoardPubSub.subscribe()
    assert :ok = BoardPubSub.broadcast_update()
    assert_receive :board_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(SymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(SymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = BoardPubSub.broadcast_update()
  end
end
