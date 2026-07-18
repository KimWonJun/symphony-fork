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

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{state_pid: state_pid, workspace: workspace}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

    turn =
      Agent.get_and_update(state_pid, fn state ->
        {state.turn + 1, %{state | turn: state.turn + 1}}
      end)

    resume_id = Agent.get(state_pid, & &1.claude_session_id)
    timeout_ms = Config.settings!().claude.turn_timeout_ms

    case start_port(workspace, prompt, resume_id) do
      {:ok, port} ->
        metadata = port_metadata(port)

        Logger.info("Claude turn started for #{issue_context(issue)} turn=#{turn} resume=#{resume_id || "new"}")

        outcome = receive_loop(port, on_message, metadata, state_pid, turn, issue, timeout_ms, "")
        close_port(port)
        outcome

      {:error, reason} ->
        emit(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  defp receive_loop(port, on_message, metadata, state_pid, turn, issue, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case handle_line(pending <> chunk, on_message, metadata, state_pid, turn, issue) do
          :continue ->
            receive_loop(port, on_message, metadata, state_pid, turn, issue, timeout_ms, "")

          {:done, outcome} ->
            outcome
        end

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, metadata, state_pid, turn, issue, timeout_ms, pending <> chunk)

      {^port, {:exit_status, 0}} ->
        {:error, :stream_ended_without_result}

      {^port, {:exit_status, status}} ->
        {:error, {:claude_exited, status}}
    after
      timeout_ms ->
        {:error, {:turn_timeout, timeout_ms}}
    end
  end

  defp handle_line(line, on_message, metadata, state_pid, turn, issue) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid} = payload} ->
        Agent.update(state_pid, fn state -> %{state | claude_session_id: sid} end)

        emit(
          on_message,
          :session_started,
          %{session_id: session_id(sid, turn), thread_id: sid, turn_id: turn, payload: payload},
          metadata
        )

        :continue

      {:ok, %{"type" => "result"} = payload} ->
        usage = accumulate_usage(state_pid, Map.get(payload, "usage"))
        sid = Agent.get(state_pid, & &1.claude_session_id) || "unknown"

        emit(
          on_message,
          :turn_completed,
          %{
            payload: %{"method" => "turn/completed", "usage" => usage},
            raw: line,
            session_id: session_id(sid, turn)
          },
          metadata
        )

        if Map.get(payload, "is_error", false) do
          {:done, {:error, {:claude_turn_error, Map.get(payload, "subtype"), Map.get(payload, "result")}}}
        else
          {:done, {:ok, %{result: payload, session_id: session_id(sid, turn), thread_id: sid, turn_id: turn}}}
        end

      {:ok, payload} when is_map(payload) ->
        emit(on_message, :other_message, %{payload: payload, raw: line}, metadata)
        :continue

      {:error, _decode_error} ->
        Logger.debug("Claude non-JSON line for #{issue_context(issue)}: #{String.slice(line, 0, 500)}")
        :continue
    end
  end

  defp accumulate_usage(state_pid, usage) when is_map(usage) do
    turn_input =
      int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) +
        int(usage["cache_read_input_tokens"])

    turn_output = int(usage["output_tokens"])

    Agent.get_and_update(state_pid, fn state ->
      totals = %{
        "input_tokens" => state.usage["input_tokens"] + turn_input,
        "output_tokens" => state.usage["output_tokens"] + turn_output,
        "total_tokens" => state.usage["total_tokens"] + turn_input + turn_output
      }

      {totals, %{state | usage: totals}}
    end)
  end

  defp accumulate_usage(state_pid, _usage), do: Agent.get(state_pid, & &1.usage)

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  defp start_port(workspace, prompt, resume_id) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(bash)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(build_command(prompt, resume_id))],
              cd: String.to_charlist(workspace),
              env: [{~c"ANTHROPIC_API_KEY", false}],
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp build_command(prompt, resume_id) do
    claude = Config.settings!().claude

    flags =
      [
        "-p",
        shell_escape(prompt),
        "--output-format stream-json",
        "--verbose",
        resume_id && "--resume #{shell_escape(resume_id)}",
        claude.model && "--model #{shell_escape(claude.model)}",
        permission_flag(claude),
        extra_args_flag(claude.extra_args)
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" ")

    "exec #{claude.command} #{flags}"
  end

  defp extra_args_flag(extra_args) when is_binary(extra_args) and extra_args != "", do: extra_args
  defp extra_args_flag(_extra_args), do: nil

  defp permission_flag(%{dangerously_skip_permissions: true}), do: "--dangerously-skip-permissions"

  defp permission_flag(%{permission_mode: mode}) when is_binary(mode),
    do: "--permission-mode #{shell_escape(mode)}"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp session_id(sid, turn), do: "#{sid}#t#{turn}"

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    # The OS process can exit and the VM can reclaim the port before we get
    # here (a race under load), and dialyzer proves `port` is always a real
    # port() at this call site, so a defensive is_port/Port.list membership
    # check is both redundant and itself racy; just rescue the already-closed
    # case instead.
    ArgumentError -> :ok
  end

  defp issue_context(%{id: id, identifier: identifier}) when is_binary(id),
    do: "issue_id=#{id} issue_identifier=#{identifier}"

  defp issue_context(_issue), do: "issue_id=unknown"
end
