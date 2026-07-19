defmodule SymphonyElixir.OpenProjectConfigTest do
  use SymphonyElixir.TestSupport

  defp write_openproject_workflow!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "openproject",
          tracker_endpoint: "http://localhost:8080",
          tracker_api_token: "op-token",
          tracker_project_slug: "crypto-server",
          tracker_active_states: ["New", "In progress", "Merging", "Rework"],
          tracker_terminal_states: ["Done", "Canceled", "Duplicate", "Rejected", "Closed"]
        ],
        overrides
      )
    )
  end

  test "openproject kind is accepted and dispatches to the OpenProject adapter" do
    write_openproject_workflow!()

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.kind == "openproject"
    assert Tracker.adapter() == SymphonyElixir.OpenProject.Adapter
  end

  test "openproject kind requires an explicit endpoint" do
    write_openproject_workflow!(tracker_endpoint: "https://api.linear.app/graphql")

    assert {:error, :missing_openproject_endpoint} = Config.validate!()
  end

  test "openproject kind requires api key and project" do
    write_openproject_workflow!(tracker_api_token: nil)
    assert {:error, :missing_openproject_api_token} = Config.validate!()

    write_openproject_workflow!(tracker_project_slug: nil)
    assert {:error, :missing_openproject_project} = Config.validate!()
  end

  test "openproject kind rejects assignee filter" do
    write_openproject_workflow!(tracker_assignee: "me")

    assert {:error, :openproject_assignee_filter_not_supported} = Config.validate!()
  end

  test "openproject api key resolves from OPENPROJECT_API_KEY env" do
    original = System.get_env("OPENPROJECT_API_KEY")
    System.put_env("OPENPROJECT_API_KEY", "env-op-token")

    try do
      write_openproject_workflow!(tracker_api_token: "$OPENPROJECT_API_KEY")

      assert {:ok, settings} = Config.settings()
      assert settings.tracker.api_key == "env-op-token"
    after
      restore_env("OPENPROJECT_API_KEY", original)
    end
  end
end
