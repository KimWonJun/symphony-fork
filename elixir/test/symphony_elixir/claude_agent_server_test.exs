defmodule SymphonyElixir.ClaudeAgentServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AgentServer, as: ClaudeServer

  defp setup_workspace!(name) do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-#{name}-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)
    {test_root, workspace_root, workspace}
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
end
