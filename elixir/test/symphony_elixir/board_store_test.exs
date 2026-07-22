defmodule SymphonyElixir.BoardStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BoardStore
  alias SymphonyElixirWeb.BoardPubSub

  defmodule FailingLinearClient do
    def fetch_issues_by_states(_states), do: {:error, :boom}
    def fetch_issues_by_ids(_ids), do: {:error, :boom}
  end

  test "snapshot/0 and refresh_now/0 are no-ops when the store isn't running" do
    refute Process.whereis(BoardStore)
    assert %{issues: [], stale_since: %DateTime{}} = BoardStore.snapshot()
    assert :ok = BoardStore.refresh_now()
  end

  test "init/1 returns :ignore when board.enabled is false" do
    write_workflow_file!(Workflow.workflow_file_path(), board_enabled: false)
    assert :ignore = BoardStore.init([])
    assert :ignore = BoardStore.start_link()
  end

  test "polls the tracker on start, updates the snapshot, and broadcasts once on change" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo", title: "First issue"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      board_enabled: true,
      board_refresh_interval_ms: 60_000
    )

    assert :ok = BoardPubSub.subscribe()
    assert {:ok, _pid} = start_supervised({BoardStore, []})

    assert %{issues: [^issue], stale_since: nil} = BoardStore.snapshot()
    assert_receive :board_updated
  end

  test "refresh_now/0 re-fetches immediately and skips the broadcast when nothing changed" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo", title: "First issue"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      board_enabled: true,
      board_refresh_interval_ms: 60_000
    )

    assert {:ok, _pid} = start_supervised({BoardStore, []})
    assert %{issues: [^issue]} = BoardStore.snapshot()

    assert :ok = BoardPubSub.subscribe()
    assert :ok = BoardStore.refresh_now()
    assert %{issues: [^issue]} = BoardStore.snapshot()
    refute_receive :board_updated, 100

    other_issue = %Issue{id: "issue-2", identifier: "MT-2", state: "Todo", title: "Second issue"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, other_issue])

    assert :ok = BoardStore.refresh_now()
    assert %{issues: [^issue, ^other_issue]} = BoardStore.snapshot()
    assert_receive :board_updated
  end

  test "handle_info(:poll) keeps the last known good snapshot and grows backoff on repeated failures" do
    Application.put_env(:symphony_elixir, :linear_client_module, FailingLinearClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    kept_issue = %Issue{id: "kept-1", identifier: "KT-1", state: "Todo"}
    state = %BoardStore.State{columns: ["Todo"], refresh_interval_ms: 15_000, issues: [kept_issue]}

    assert {:noreply, first_failure} = BoardStore.handle_info(:poll, state)
    assert first_failure.issues == [kept_issue]
    assert %DateTime{} = first_failure.stale_since
    assert first_failure.backoff_ms == 1_000

    assert {:noreply, second_failure} = BoardStore.handle_info(:poll, first_failure)
    assert second_failure.issues == [kept_issue]
    assert second_failure.stale_since == first_failure.stale_since
    assert second_failure.backoff_ms == 2_000
  end

  test "handle_info(:poll) backoff is capped at five minutes" do
    Application.put_env(:symphony_elixir, :linear_client_module, FailingLinearClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    state = %BoardStore.State{columns: ["Todo"], refresh_interval_ms: 15_000, issues: [], backoff_ms: 256_000}

    assert {:noreply, capped} = BoardStore.handle_info(:poll, state)
    assert capped.backoff_ms == 300_000
  end
end
