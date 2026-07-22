defmodule SymphonyElixirWeb.BoardLive do
  @moduledoc """
  Tracker-first kanban board.

  Unlike `SymphonyElixirWeb.DashboardLive` (runtime-first: only renders what
  the orchestrator currently holds), this view lays out every work package in
  `board.columns` first and overlays the Symphony runtime status (running /
  retrying / blocked) on top, joined by `issue_identifier`. Read-only: no
  drag-and-drop yet.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.BoardStore
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixirWeb.{BoardPubSub, Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:board_columns, board_columns())
      |> assign(:now, DateTime.utc_now())
      |> load_board()
      |> load_runtime()

    if connected?(socket) do
      :ok = BoardPubSub.subscribe()
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:board_updated, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_info(:observability_updated, socket) do
    {:noreply, load_runtime(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="board-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">OpenProject &times; Symphony</p>
            <h1 class="hero-title">Kanban Board</h1>
            <p class="hero-copy">
              Work packages grouped by tracker state, with live Symphony runtime status overlaid per card.
            </p>
          </div>
        </div>
      </header>

      <p :if={@stale_since} class="stale-banner">
        Tracker data hasn't refreshed since
        <span class="mono numeric"><%= DateTime.to_iso8601(@stale_since) %></span>. Showing the last known snapshot.
      </p>

      <div class="board-columns">
        <section :for={{column, issues} <- @columns_with_issues} class="board-column">
          <div class="board-column-header">
            <h2 class="board-column-title"><%= column %></h2>
            <span class="board-column-count"><%= length(issues) %></span>
          </div>

          <div class="board-column-cards">
            <p :if={issues == []} class="empty-state">No work packages.</p>

            <.board_card
              :for={issue <- issues}
              issue={issue}
              runtime={Map.get(@runtime_index, issue.identifier)}
              now={@now}
            />
          </div>
        </section>
      </div>
    </section>
    """
  end

  attr(:issue, :any, required: true)
  attr(:runtime, :any, default: nil)
  attr(:now, :any, required: true)

  defp board_card(assigns) do
    ~H"""
    <article class="board-card">
      <div class="board-card-header">
        <.issue_identifier identifier={@issue.identifier} url={@issue.url} />
        <span :if={runtime_badge_label(@runtime)} class={runtime_badge_class(@runtime)}>
          <%= runtime_badge_label(@runtime) %>
        </span>
      </div>

      <p class="board-card-title"><%= @issue.title %></p>

      <div :if={priority_label(@issue.priority) || runtime_meta(@runtime, @now)} class="board-card-meta muted">
        <span :if={priority_label(@issue.priority)}><%= priority_label(@issue.priority) %></span>
        <span :if={runtime_meta(@runtime, @now)} class="numeric"><%= runtime_meta(@runtime, @now) %></span>
      </div>
    </article>
    """
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp board_columns, do: Config.settings!().board.columns

  defp load_board(socket) do
    %{issues: issues, stale_since: stale_since} = BoardStore.snapshot()

    socket
    |> assign(:stale_since, stale_since)
    |> assign(:columns_with_issues, group_by_column(issues, socket.assigns.board_columns))
  end

  defp load_runtime(socket) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    assign(socket, :runtime_index, runtime_index(payload))
  end

  defp orchestrator, do: Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000

  defp group_by_column(issues, columns) do
    grouped = Enum.group_by(issues, &Schema.normalize_issue_state(&1.state || ""))

    Enum.map(columns, fn column ->
      {column, Map.get(grouped, Schema.normalize_issue_state(column), [])}
    end)
  end

  defp runtime_index(%{error: _}), do: %{}

  defp runtime_index(payload) do
    tagged =
      Enum.map(Map.get(payload, :running, []), &Map.put(&1, :kind, :running)) ++
        Enum.map(Map.get(payload, :retrying, []), &Map.put(&1, :kind, :retrying)) ++
        Enum.map(Map.get(payload, :blocked, []), &Map.put(&1, :kind, :blocked))

    Map.new(tagged, &{&1.issue_identifier, &1})
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp runtime_badge_class(nil), do: nil
  defp runtime_badge_class(%{kind: :running}), do: "state-badge state-badge-active"
  defp runtime_badge_class(%{kind: :retrying}), do: "state-badge state-badge-warning"
  defp runtime_badge_class(%{kind: :blocked}), do: "state-badge state-badge-danger"

  defp runtime_badge_label(nil), do: nil
  defp runtime_badge_label(%{kind: :running}), do: "Running"
  defp runtime_badge_label(%{kind: :retrying} = entry), do: "Retry ##{Map.get(entry, :attempt)}"
  defp runtime_badge_label(%{kind: :blocked}), do: "Blocked"

  defp runtime_meta(nil, _now), do: nil

  defp runtime_meta(%{kind: :running} = entry, now) do
    format_runtime_seconds(runtime_seconds_from_started_at(Map.get(entry, :started_at), now))
  end

  defp runtime_meta(%{kind: :retrying} = entry, _now), do: Map.get(entry, :due_at)
  defp runtime_meta(%{kind: :blocked} = entry, _now), do: Map.get(entry, :error)

  defp priority_label(1), do: "Immediate"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Normal"
  defp priority_label(4), do: "Low"
  defp priority_label(_priority), do: nil

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end
end
