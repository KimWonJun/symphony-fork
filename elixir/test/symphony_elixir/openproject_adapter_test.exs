defmodule SymphonyElixir.OpenProjectAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OpenProject.Adapter

  defmodule FakeOpenProjectClient do
    def fetch_issues_by_states(states), do: {:ok, {:by_states, states}}
    def fetch_issues_by_ids(ids), do: {:ok, {:by_ids, ids}}
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

  defp valid_tracker_settings(overrides \\ %{}) do
    Map.merge(
      %{
        endpoint: "http://localhost:8080",
        api_key: "op-token",
        project_slug: "crypto-server",
        assignee: nil,
        active_states: ["New", "In progress"],
        terminal_states: ["Done", "Closed"],
        secret_environment_names: []
      },
      overrides
    )
  end

  test "adapter delegates reads to the configured client" do
    assert {:ok, {:by_states, ["New"]}} = Adapter.fetch_issues_by_states(["New"])
    assert {:ok, {:by_ids, ["37"]}} = Adapter.fetch_issues_by_ids(["37"])
  end

  test "secret_environment_names passes through tracker_settings" do
    tracker_settings = valid_tracker_settings(%{secret_environment_names: ["OPENPROJECT_API_KEY"]})

    assert Adapter.secret_environment_names(tracker_settings) == ["OPENPROJECT_API_KEY"]
  end

  describe "validate_config/1" do
    test "accepts a fully configured tracker_settings map" do
      assert :ok = Adapter.validate_config(valid_tracker_settings())
    end

    test "rejects a missing/default-linear endpoint" do
      assert {:error, :missing_openproject_endpoint} =
               Adapter.validate_config(valid_tracker_settings(%{endpoint: nil}))

      assert {:error, :missing_openproject_endpoint} =
               Adapter.validate_config(valid_tracker_settings(%{endpoint: "https://api.linear.app/graphql"}))
    end

    test "rejects a missing api key" do
      assert {:error, :missing_openproject_api_token} =
               Adapter.validate_config(valid_tracker_settings(%{api_key: nil}))
    end

    test "rejects a missing project slug" do
      assert {:error, :missing_openproject_project} =
               Adapter.validate_config(valid_tracker_settings(%{project_slug: nil}))
    end

    test "rejects an assignee filter" do
      assert {:error, :openproject_assignee_filter_not_supported} =
               Adapter.validate_config(valid_tracker_settings(%{assignee: "me"}))
    end

    test "rejects a missing active_states list" do
      assert {:error, :missing_openproject_active_states} =
               Adapter.validate_config(valid_tracker_settings(%{active_states: []}))
    end

    test "rejects a missing terminal_states list" do
      assert {:error, :missing_openproject_terminal_states} =
               Adapter.validate_config(valid_tracker_settings(%{terminal_states: []}))
    end
  end
end
