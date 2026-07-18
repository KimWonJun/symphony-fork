defmodule SymphonyElixir.Claude.AgentServer do
  @moduledoc """
  Runs Claude Code headless (`claude -p --output-format stream-json`) as the
  per-issue coding agent, mirroring the Codex AppServer session contract.

  Unlike the Codex app-server there is no resident subprocess: each turn spawns
  one `claude -p` invocation, and cross-turn state (Claude session id for
  `--resume`, cumulative token usage) lives in an Elixir `Agent` process.
  """

  require Logger
  alias SymphonyElixir.{Config, WorkspaceCwd}

  @port_line_bytes 1_048_576

  @type session :: %{
          state_pid: pid(),
          metadata: map(),
          workspace: Path.t(),
          worker_host: nil
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      nil -> start_local_session(workspace)
      worker_host -> {:error, {:claude_remote_worker_not_supported, worker_host}}
    end
  end

  defp start_local_session(workspace) do
    with {:ok, expanded_workspace} <- WorkspaceCwd.validate_local(workspace),
         {:ok, state_pid} <- Agent.start_link(&initial_state/0) do
      {:ok, %{state_pid: state_pid, metadata: %{}, workspace: expanded_workspace, worker_host: nil}}
    end
  end

  defp initial_state do
    %{
      claude_session_id: nil,
      turn: 0,
      usage: %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    }
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{state_pid: state_pid}) when is_pid(state_pid) do
    if Process.alive?(state_pid) do
      Agent.stop(state_pid, :normal)
    end

    :ok
  end
end
