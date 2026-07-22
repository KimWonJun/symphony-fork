defmodule SymphonyElixir.BoardConfigTest do
  use SymphonyElixir.TestSupport

  test "board defaults to disabled with no explicit columns" do
    write_workflow_file!(Workflow.workflow_file_path())

    settings = Config.settings!()
    assert settings.board.enabled == false
    assert settings.board.refresh_interval_ms == 15_000
  end

  test "board columns default to tracker active_states ++ terminal_states when unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"]
    )

    assert Config.settings!().board.columns == ["Todo", "In Progress", "Done", "Cancelled"]
  end

  test "explicit board columns are preserved as configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Cancelled"],
      board_columns: ["Specified", "In Progress", "Done"]
    )

    assert Config.settings!().board.columns == ["Specified", "In Progress", "Done"]
  end

  test "board.enabled and board.refresh_interval_ms can be overridden" do
    write_workflow_file!(Workflow.workflow_file_path(),
      board_enabled: true,
      board_refresh_interval_ms: 5_000
    )

    settings = Config.settings!()
    assert settings.board.enabled == true
    assert settings.board.refresh_interval_ms == 5_000
  end

  test "rejects a non-positive board.refresh_interval_ms" do
    write_workflow_file!(Workflow.workflow_file_path(), board_refresh_interval_ms: 0)

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "board.refresh_interval_ms"
  end
end
