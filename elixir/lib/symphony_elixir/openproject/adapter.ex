defmodule SymphonyElixir.OpenProject.Adapter do
  @moduledoc """
  OpenProject-backed tracker adapter (REST API v3).
  """

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: {:error, :not_implemented}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(_states), do: {:error, :not_implemented}

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids), do: {:error, :not_implemented}

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(_issue_id, _body), do: {:error, :not_implemented}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: {:error, :not_implemented}
end
