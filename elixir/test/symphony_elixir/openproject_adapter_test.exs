defmodule SymphonyElixir.OpenProjectAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OpenProject.Adapter

  defmodule FakeOpenProjectClient do
    def fetch_candidate_issues, do: {:ok, [:candidate]}
    def fetch_issues_by_states(states), do: {:ok, {:by_states, states}}
    def fetch_issue_states_by_ids(ids), do: {:ok, {:by_ids, ids}}

    def create_comment(issue_id, body) do
      send(self(), {:fake_comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:fake_state_update, issue_id, state_name})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :openproject_client_module)
    Application.put_env(:symphony_elixir, :openproject_client_module, FakeOpenProjectClient)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :openproject_client_module)
      else
        Application.put_env(:symphony_elixir, :openproject_client_module, previous)
      end
    end)

    :ok
  end

  test "adapter delegates every Tracker callback to the configured client" do
    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert {:ok, {:by_states, ["New"]}} = Adapter.fetch_issues_by_states(["New"])
    assert {:ok, {:by_ids, ["37"]}} = Adapter.fetch_issue_states_by_ids(["37"])

    assert :ok = Adapter.create_comment("37", "workpad")
    assert_receive {:fake_comment, "37", "workpad"}

    assert :ok = Adapter.update_issue_state("37", "In progress")
    assert_receive {:fake_state_update, "37", "In progress"}
  end
end
