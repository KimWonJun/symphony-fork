defmodule SymphonyElixir.WorkspaceCwdTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.WorkspaceCwd

  test "validate_local reports unreadable paths that cannot be canonicalized" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-cwd-unreadable-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    locked_dir = Path.join(workspace_root, "locked")
    unreadable_workspace = Path.join(locked_dir, "MT-404")
    File.mkdir_p!(locked_dir)
    File.chmod!(locked_dir, 0o000)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, _path, _reason}} =
               WorkspaceCwd.validate_local(unreadable_workspace)
    after
      File.chmod!(locked_dir, 0o755)
      File.rm_rf(test_root)
    end
  end
end
