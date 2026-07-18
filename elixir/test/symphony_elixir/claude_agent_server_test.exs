defmodule SymphonyElixir.ClaudeAgentServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AgentServer, as: ClaudeServer

  @success_ndjson """
  {"type":"system","subtype":"init","session_id":"sess-123","model":"claude-opus-4-8"}
  {"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}
  {"type":"result","subtype":"success","is_error":false,"session_id":"sess-123","result":"done","usage":{"input_tokens":100,"output_tokens":40,"cache_creation_input_tokens":10,"cache_read_input_tokens":50}}
  """

  defp setup_workspace!(name) do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-#{name}-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)
    {test_root, workspace_root, workspace}
  end

  defp write_fake_claude!(dir, trace_file, ndjson, extra_shell \\ "") do
    script_path = Path.join(dir, "fake-claude")

    script = """
    #!/usr/bin/env bash
    printf '%s\\n' "$*" >> #{trace_file}
    #{extra_shell}
    cat <<'NDJSON'
    #{String.trim_trailing(ndjson)}
    NDJSON
    """

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp issue_fixture do
    %Issue{
      id: "issue-claude-1",
      identifier: "MT-1",
      title: "Claude adapter test",
      description: "drive the fake claude binary",
      state: "In Progress",
      url: "https://example.org/issues/MT-1",
      labels: []
    }
  end

  test "start_session validates workspace and returns a stoppable session" do
    {test_root, workspace_root, workspace} = setup_workspace!("lifecycle")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude"
      )

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert {:ok, session} = ClaudeServer.start_session(workspace)
      assert is_pid(session.state_pid)
      assert session.workspace == canonical_workspace
      assert session.worker_host == nil
      assert :ok = ClaudeServer.stop_session(session)
      refute Process.alive?(session.state_pid)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session rejects workspaces outside the workspace root" do
    {test_root, workspace_root, _workspace} = setup_workspace!("guard")
    outside = Path.join(test_root, "outside")
    File.mkdir_p!(outside)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               ClaudeServer.start_session(outside)
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session rejects remote worker hosts" do
    {test_root, workspace_root, workspace} = setup_workspace!("remote")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:claude_remote_worker_not_supported, "worker-1"}} =
               ClaudeServer.start_session(workspace, worker_host: "worker-1")
    after
      File.rm_rf(test_root)
    end
  end

  test "run_turn drives one claude -p invocation and reports cumulative usage" do
    {test_root, workspace_root, workspace} = setup_workspace!("happy")
    trace_file = Path.join(test_root, "trace")
    script = write_fake_claude!(test_root, trace_file, @success_ndjson)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "claude",
        claude_command: script
      )

      test_pid = self()
      on_message = fn message -> send(test_pid, {:claude_msg, message}) end
      {:ok, session} = ClaudeServer.start_session(workspace)

      assert {:ok, turn} =
               ClaudeServer.run_turn(session, "do the task", issue_fixture(), on_message: on_message)

      assert turn.thread_id == "sess-123"
      assert turn.turn_id == 1
      assert turn.session_id == "sess-123#t1"

      assert_receive {:claude_msg, %{event: :session_started, session_id: "sess-123#t1", timestamp: %DateTime{}}}
      assert_receive {:claude_msg, %{event: :other_message}}

      assert_receive {:claude_msg,
                      %{
                        event: :turn_completed,
                        payload: %{
                          "method" => "turn/completed",
                          "usage" => %{"input_tokens" => 160, "output_tokens" => 40, "total_tokens" => 200}
                        }
                      }}

      argv = File.read!(trace_file)
      assert argv =~ "-p"
      assert argv =~ "--output-format stream-json"
      assert argv =~ "--verbose"
      assert argv =~ "--permission-mode bypassPermissions"
      refute argv =~ "--resume"

      ClaudeServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end
end
