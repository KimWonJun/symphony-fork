defmodule SymphonyElixir.LiveClaudeSmokeTest do
  use SymphonyElixir.TestSupport

  @moduletag timeout: 300_000

  test "one real claude -p turn completes against a scratch workspace" do
    if System.get_env("SYMPHONY_RUN_LIVE_CLAUDE") == "1" do
      test_root = Path.join(System.tmp_dir!(), "symphony-live-claude-#{System.unique_integer([:positive])}")
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          claude_model: "claude-haiku-4-5",
          prompt: "Reply with the single word DONE and end the turn. Do not run any tools."
        )

        issue = %Issue{
          id: "live-claude-1",
          identifier: "LIVE-1",
          title: "Live smoke",
          description: "Reply DONE",
          state: "In Progress",
          url: "https://example.org/issues/LIVE-1",
          labels: [],
          dispatchable: true
        }

        fetcher = fn _ids -> {:ok, [%Issue{issue | state: "Done"}]} end

        assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: fetcher)
        assert_receive {:codex_worker_update, "live-claude-1", %{event: :turn_completed}}, 240_000
      after
        File.rm_rf(test_root)
      end
    else
      assert true
    end
  end
end
