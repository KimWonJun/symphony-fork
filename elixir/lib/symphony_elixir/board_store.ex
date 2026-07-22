defmodule SymphonyElixir.BoardStore do
  @moduledoc """
  Polls the configured tracker for the kanban board's columns and caches the
  last known good snapshot for `SymphonyElixirWeb.BoardLive`.

  Tracker-first (unlike the orchestrator, which is runtime-first): every work
  item in `board.columns` is fetched regardless of whether Symphony currently
  has a runtime entry for it.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixirWeb.BoardPubSub

  @min_backoff_ms 1_000
  @max_backoff_ms 300_000

  defmodule State do
    @moduledoc false

    defstruct [:columns, :refresh_interval_ms, issues: [], stale_since: nil, backoff_ms: nil]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec snapshot() :: %{issues: [Issue.t()], stale_since: DateTime.t() | nil}
  def snapshot do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :snapshot)

      _ ->
        %{issues: [], stale_since: DateTime.utc_now()}
    end
  end

  @spec refresh_now() :: :ok
  def refresh_now do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.cast(__MODULE__, :refresh_now)

      _ ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    board = Config.settings!().board

    if board.enabled do
      send(self(), :poll)
      {:ok, %State{columns: board.columns, refresh_interval_ms: board.refresh_interval_ms}}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, %{issues: state.issues, stale_since: state.stale_since}, state}
  end

  @impl true
  def handle_cast(:refresh_now, %State{} = state) do
    {:noreply, poll(state)}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    {:noreply, poll(state)}
  end

  defp poll(%State{} = state) do
    case Tracker.fetch_issues_by_states(state.columns) do
      {:ok, issues} ->
        Process.send_after(self(), :poll, state.refresh_interval_ms)
        maybe_broadcast(state.issues, issues)
        %{state | issues: issues, stale_since: nil, backoff_ms: nil}

      {:error, reason} ->
        backoff_ms = next_backoff(state.backoff_ms)

        Logger.warning("BoardStore fetch failed reason=#{inspect(reason)} backoff_ms=#{backoff_ms} action=retrying")

        Process.send_after(self(), :poll, backoff_ms)
        %{state | stale_since: state.stale_since || DateTime.utc_now(), backoff_ms: backoff_ms}
    end
  end

  defp maybe_broadcast(previous_issues, current_issues) do
    if sort_by_identifier(previous_issues) == sort_by_identifier(current_issues) do
      :ok
    else
      BoardPubSub.broadcast_update()
    end
  end

  defp sort_by_identifier(issues), do: Enum.sort_by(issues, & &1.identifier)

  defp next_backoff(nil), do: @min_backoff_ms
  defp next_backoff(backoff_ms), do: min(backoff_ms * 2, @max_backoff_ms)
end
