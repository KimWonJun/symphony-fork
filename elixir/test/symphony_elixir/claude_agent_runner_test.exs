defmodule SymphonyElixir.ClaudeAgentRunnerTest do
  use SymphonyElixir.TestSupport

  @success_ndjson """
  {"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-8"}
  {"type":"result","subtype":"success","is_error":false,"session_id":"sess-123","result":"done","usage":{"input_tokens":100,"output_tokens":40,"cache_creation_input_tokens":10,"cache_read_input_tokens":50}}
  """

  defp write_fake_claude!(dir, trace_file) do
    script_path = Path.join(dir, "fake-claude")

    script = """
    #!/usr/bin/env bash
    printf '%s\\0' "$*" >> #{trace_file}
    cat <<'NDJSON'
    #{String.trim_trailing(@success_ndjson)}
    NDJSON
    """

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp issue_fixture(state) do
    %Issue{
      id: "issue-runner-1",
      identifier: "MT-77",
      title: "Runner dispatch test",
      description: "route to claude adapter",
      state: state,
      url: "https://example.org/issues/MT-77",
      labels: []
    }
  end

  test "agent runner routes to the claude adapter and stops on terminal state" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-runner-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "trace")
    File.mkdir_p!(workspace_root)
    script = write_fake_claude!(test_root, trace_file)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        claude_command: script
      )

      fetcher = fn _ids -> {:ok, [issue_fixture("Done")]} end

      assert :ok = AgentRunner.run(issue_fixture("In Progress"), nil, issue_state_fetcher: fetcher)
      assert trace_file |> File.read!() |> String.split(<<0>>, trim: true) |> length() == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues claude turns with --resume while the issue stays active" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-runner-cont-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "trace")
    File.mkdir_p!(workspace_root)
    script = write_fake_claude!(test_root, trace_file)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        claude_command: script
      )

      fetcher = fn _ids -> {:ok, [issue_fixture("In Progress")]} end

      assert :ok = AgentRunner.run(issue_fixture("In Progress"), nil, issue_state_fetcher: fetcher, max_turns: 2)

      [argv1, argv2] = trace_file |> File.read!() |> String.split(<<0>>, trim: true)
      refute argv1 =~ "--resume"
      assert argv2 =~ "--resume"
    after
      File.rm_rf(test_root)
    end
  end

  test "claude updates arrive as codex_worker_update messages with recognizable usage" do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-runner-msg-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "trace")
    File.mkdir_p!(workspace_root)
    script = write_fake_claude!(test_root, trace_file)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        claude_command: script
      )

      fetcher = fn _ids -> {:ok, [issue_fixture("Done")]} end

      assert :ok = AgentRunner.run(issue_fixture("In Progress"), self(), issue_state_fetcher: fetcher)

      assert_receive {:worker_runtime_info, "issue-runner-1", %{workspace_path: _}}
      assert_receive {:codex_worker_update, "issue-runner-1", %{event: :session_started, timestamp: %DateTime{}}}

      assert_receive {:codex_worker_update, "issue-runner-1",
                      %{
                        event: :turn_completed,
                        payload: %{"method" => "turn/completed", "usage" => usage}
                      }}

      assert usage == %{"input_tokens" => 160, "output_tokens" => 40, "total_tokens" => 200}
    after
      File.rm_rf(test_root)
    end
  end
end
