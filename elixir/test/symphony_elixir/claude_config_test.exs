defmodule SymphonyElixir.ClaudeConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "claude.model_by_state" do
    test "falls back to the global model when no override is configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        claude_model: "claude-opus-4-8"
      )

      assert {:ok, settings} = Config.settings()
      assert settings.claude.model_by_state == %{}
      assert Config.claude_model_for_state("In specification") == "claude-opus-4-8"
      assert Config.claude_model_for_state("Confirmed") == "claude-opus-4-8"
    end

    test "returns the per-state model when the state matches" do
      assert {:ok, settings} =
               Schema.parse(%{
                 "claude" => %{
                   "model" => "claude-opus-4-8",
                   "model_by_state" => %{
                     "In specification" => "claude-opus-4-8",
                     "Confirmed" => "claude-sonnet-5"
                   }
                 }
               })

      # 키는 normalize_issue_state(trim + downcase)로 정규화되어 저장된다.
      assert settings.claude.model_by_state == %{
               "in specification" => "claude-opus-4-8",
               "confirmed" => "claude-sonnet-5"
             }
    end

    test "state lookup ignores case and surrounding whitespace" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude",
        claude_model: "claude-opus-4-8",
        claude_model_by_state: %{"Confirmed" => "claude-sonnet-5"}
      )

      assert {:ok, _settings} = Config.settings()
      assert Config.claude_model_for_state("Confirmed") == "claude-sonnet-5"
      assert Config.claude_model_for_state("  confirmed  ") == "claude-sonnet-5"
      assert Config.claude_model_for_state("CONFIRMED") == "claude-sonnet-5"
      # 매핑에 없는 상태는 전역 모델로 떨어진다.
      assert Config.claude_model_for_state("In testing") == "claude-opus-4-8"
    end

    test "non-binary states and missing global model yield nil" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude")

      assert {:ok, settings} = Config.settings()
      assert settings.claude.model == nil
      # nil 이면 --model 플래그 자체가 붙지 않는다(claude CLI 기본 모델).
      assert Config.claude_model_for_state("In specification") == nil
      assert Config.claude_model_for_state(nil) == nil
      assert Config.claude_model_for_state(:atom) == nil
    end

    test "rejects blank state names and non-string models" do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"claude" => %{"model_by_state" => %{"  " => "claude-opus-4-8"}}})

      assert message =~ "state names must not be blank"

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"claude" => %{"model_by_state" => %{"Confirmed" => 5}}})

      assert message =~ "models must be non-empty strings"

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"claude" => %{"model_by_state" => %{"Confirmed" => "  "}}})

      assert message =~ "models must be non-empty strings"
    end
  end

  test "claude block defaults are applied when omitted" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.claude.command == "claude"
    assert settings.claude.model == nil
    assert settings.claude.model_by_state == %{}
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
