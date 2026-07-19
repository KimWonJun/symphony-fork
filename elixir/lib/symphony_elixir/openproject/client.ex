defmodule SymphonyElixir.OpenProject.Client do
  @moduledoc """
  Thin OpenProject REST API v3 client for polling and updating work packages.

  Authentication is HTTP Basic with the literal username `apikey` and the
  configured token. Status filters use status IDs, so status names from the
  workflow config are resolved via `GET /api/v3/statuses` per call.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50
  @max_error_body_log_bytes 1_000
  @priority_rank %{"immediate" => 1, "high" => 2, "normal" => 3, "low" => 4}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_openproject_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_openproject_project}
      true -> fetch_issues_by_states(tracker.active_states)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, status_ids} <- status_ids_by_name() do
      wanted =
        state_names
        |> Enum.map(&Map.get(status_ids, normalize_name(&1)))
        |> Enum.reject(&is_nil/1)

      case wanted do
        [] ->
          {:ok, []}

        ids ->
          fetch_pages([%{"status" => %{"operator" => "=", "values" => Enum.map(ids, &to_string/1)}}], 1, [])
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids([]), do: {:ok, []}

  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_pages([%{"id" => %{"operator" => "=", "values" => issue_ids}}], 1, [])
  end

  @doc false
  @spec normalize_work_package(term()) :: Issue.t() | nil
  def normalize_work_package(%{"id" => id} = wp) when is_integer(id) or is_binary(id) do
    %Issue{
      id: to_string(id),
      identifier: "WP-#{id}",
      title: wp["subject"],
      description: description_raw(wp["description"]),
      priority: priority_rank(get_in(wp, ["_links", "priority", "title"])),
      state: get_in(wp, ["_links", "status", "title"]),
      branch_name: nil,
      url: work_package_url(id),
      assignee_id: id_from_href(get_in(wp, ["_links", "assignee", "href"])),
      blocked_by: [],
      labels: [],
      assigned_to_worker: true,
      created_at: parse_datetime(wp["createdAt"]),
      updated_at: parse_datetime(wp["updatedAt"])
    }
  end

  def normalize_work_package(_wp), do: nil

  @spec status_ids_by_name() :: {:ok, %{String.t() => integer()}} | {:error, term()}
  def status_ids_by_name do
    with {:ok, body} <- request(:get, "/statuses", [], nil) do
      statuses = get_in(body, ["_embedded", "elements"]) || []

      {:ok,
       Map.new(statuses, fn status ->
         {normalize_name(status["name"]), status["id"]}
       end)}
    end
  end

  @doc false
  @spec request(atom(), String.t(), keyword(), map() | nil) :: {:ok, term()} | {:error, term()}
  def request(method, path, query, body) do
    tracker = Config.settings!().tracker
    url = api_url(tracker.endpoint, path)

    base_opts = [
      method: method,
      url: url,
      auth: {:basic, "apikey:#{tracker.api_key}"},
      receive_timeout: 30_000
    ]

    opts =
      base_opts
      |> then(fn acc -> if query == [], do: acc, else: acc ++ [params: query] end)
      |> then(fn acc -> if is_nil(body), do: acc, else: acc ++ [json: body] end)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("OpenProject HTTP #{status} #{method} #{path}: #{truncate_body(resp_body)}")
        {:error, {:http_status, status, truncate_body(resp_body)}}

      {:error, reason} ->
        {:error, {:http_transport_error, reason}}
    end
  end

  defp fetch_pages(filters, offset, acc) do
    query = [filters: Jason.encode!(filters), pageSize: @page_size, offset: offset]
    project = Config.settings!().tracker.project_slug

    with {:ok, body} <- request(:get, "/projects/#{project}/work_packages", query, nil) do
      elements = get_in(body, ["_embedded", "elements"]) || []
      issues = elements |> Enum.map(&normalize_work_package/1) |> Enum.reject(&is_nil/1)
      total = body["total"] || length(elements)
      fetched = (offset - 1) * @page_size + length(elements)

      if fetched < total and elements != [] do
        fetch_pages(filters, offset + 1, acc ++ issues)
      else
        {:ok, acc ++ issues}
      end
    end
  end

  defp api_url(endpoint, path) do
    base =
      endpoint
      |> String.trim_trailing("/")
      |> String.trim_trailing("/api/v3")

    base <> "/api/v3" <> path
  end

  defp work_package_url(id) do
    base =
      Config.settings!().tracker.endpoint
      |> String.trim_trailing("/")
      |> String.trim_trailing("/api/v3")

    base <> "/work_packages/#{id}"
  end

  defp description_raw(%{"raw" => raw}) when is_binary(raw), do: raw
  defp description_raw(_description), do: nil

  defp priority_rank(title) when is_binary(title) do
    Map.get(@priority_rank, String.downcase(String.trim(title)))
  end

  defp priority_rank(_title), do: nil

  defp id_from_href("/api/v3/users/" <> user_id) when user_id != "", do: user_id
  defp id_from_href(_href), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end

  defp normalize_name(_name), do: ""

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, @max_error_body_log_bytes)
  defp truncate_body(body), do: body |> inspect() |> String.slice(0, @max_error_body_log_bytes)
end
