defmodule SymphonyElixir.ClaudeConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  test "claude block defaults are applied when omitted" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.claude.command == "claude"
    assert settings.claude.model == nil
    assert settings.claude.permission_mode == "bypassPermissions"
    assert settings.claude.dangerously_skip_permissions == false
    assert settings.claude.extra_args == ""
    assert settings.claude.turn_timeout_ms == 3_600_000
    assert settings.agent.kind == "codex"
  end

  test "agent.kind accepts claude and rejects unknown kinds" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => "claude"}})
    assert settings.agent.kind == "claude"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"kind" => "gemini"}})

    assert message =~ "kind"
  end

  test "claude block values parse from workflow yaml via test support" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      claude_command: "/opt/bin/claude",
      claude_model: "claude-opus-4-8",
      claude_turn_timeout_ms: 120_000
    )

    assert {:ok, settings} = Config.settings()
    assert settings.agent.kind == "claude"
    assert settings.claude.command == "/opt/bin/claude"
    assert settings.claude.model == "claude-opus-4-8"
    assert settings.claude.turn_timeout_ms == 120_000
  end
end
