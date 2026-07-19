defmodule SymphonyElixir.OpenProject.Adapter do
  @moduledoc """
  OpenProject-backed tracker adapter (REST API v3).

  Orchestrator-facing reads implement the Tracker behaviour. Work-package
  mutations (comments, status transitions) are agent-side concerns handled by
  the `openproject` skill; the client keeps those helpers for live tests.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.OpenProject.Client
  alias SymphonyElixir.Tracker.Issue

  @linear_default_endpoint "https://api.linear.app/graphql"

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    cond do
      not present_string?(tracker_settings.endpoint) or
          tracker_settings.endpoint == @linear_default_endpoint ->
        {:error, :missing_openproject_endpoint}

      not present_string?(tracker_settings.api_key) ->
        {:error, :missing_openproject_api_token}

      not present_string?(tracker_settings.project_slug) ->
        {:error, :missing_openproject_project}

      is_binary(tracker_settings.assignee) ->
        {:error, :openproject_assignee_filter_not_supported}

      empty_states?(tracker_settings.active_states) ->
        {:error, :missing_openproject_active_states}

      empty_states?(tracker_settings.terminal_states) ->
        {:error, :missing_openproject_terminal_states}

      true ->
        :ok
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: tracker_settings.secret_environment_names

  defp client_module do
    Application.get_env(:symphony_elixir, :openproject_client_module, Client)
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp empty_states?(states) when is_list(states), do: states == []
  defp empty_states?(_states), do: true
end
