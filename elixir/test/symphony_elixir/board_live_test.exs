defmodule SymphonyElixir.BoardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.BoardStore

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule FailingLinearClient do
    def fetch_issues_by_states(_states), do: {:error, :boom}
    def fetch_issues_by_ids(_ids), do: {:error, :boom}
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      restart_board_store!(enabled: false)
    end)

    :ok
  end

  test "GET /board returns 404 when board.enabled is false" do
    write_workflow_file!(Workflow.workflow_file_path(), board_enabled: false)
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :UnusedOrchestrator))

    assert response(get(build_conn(), "/board"), 404) == "Not Found"
  end

  test "renders columns, cards, and runtime badges from the tracker and orchestrator" do
    running_issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Todo", title: "Wire up the board", priority: 2}
    idle_issue = %Issue{id: "issue-2", identifier: "MT-2", state: "Done", title: "Ship the docs", priority: nil}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running_issue, idle_issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      board_enabled: true,
      board_refresh_interval_ms: 60_000
    )

    restart_board_store!(enabled: true)

    orchestrator_name = Module.concat(__MODULE__, :RunningOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: %{
          running: [
            %{
              issue_id: "issue-1",
              identifier: "MT-1",
              issue_url: nil,
              state: "In Progress",
              session_id: "thread-1",
              turn_count: 3,
              last_codex_event: :notification,
              last_codex_message: nil,
              last_codex_timestamp: nil,
              codex_input_tokens: 1,
              codex_output_tokens: 1,
              codex_total_tokens: 2,
              started_at: DateTime.add(DateTime.utc_now(), -65, :second)
            }
          ],
          retrying: [],
          blocked: [],
          codex_totals: %{input_tokens: 1, output_tokens: 1, total_tokens: 2, seconds_running: 0.0},
          rate_limits: %{}
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/board")

    assert html =~ "Kanban Board"
    assert html =~ "Todo"
    assert html =~ "Done"
    assert html =~ "MT-1"
    assert html =~ "Wire up the board"
    assert html =~ "state-badge-active"
    assert html =~ "Running"
    assert html =~ ~r/1m \d+s/
    assert html =~ "High"
    assert html =~ "MT-2"
    assert html =~ "Ship the docs"
    refute html =~ "stale-banner"
  end

  test "renders a stale banner when the tracker fetch is failing" do
    Application.put_env(:symphony_elixir, :linear_client_module, FailingLinearClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      board_enabled: true,
      board_columns: ["Todo"],
      board_refresh_interval_ms: 60_000
    )

    restart_board_store!(enabled: true)

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :UnavailableOrchestrator))

    {:ok, _view, html} = live(build_conn(), "/board")
    assert html =~ "stale-banner"
    assert html =~ "Showing the last known snapshot"
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restart_board_store!(enabled: enabled) do
    case Supervisor.terminate_child(SymphonyElixir.Supervisor, BoardStore) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    if enabled do
      assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, BoardStore)
    end

    :ok
  end
end
