defmodule SymphonyElixir.OpenProjectClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OpenProject.Client

  defp write_openproject_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "openproject",
      tracker_endpoint: "http://localhost:8080",
      tracker_api_token: "op-token",
      tracker_project_slug: "crypto-server"
    )
  end

  test "normalize_work_package maps the API v3 shape onto the Issue struct" do
    write_openproject_workflow!()

    wp = %{
      "id" => 37,
      "subject" => "OpenProject 연동 스모크 테스트",
      "lockVersion" => 2,
      "description" => %{"format" => "markdown", "raw" => "본문", "html" => "<p>본문</p>"},
      "createdAt" => "2026-07-19T07:30:00.000Z",
      "updatedAt" => "2026-07-19T07:31:00.000Z",
      "_links" => %{
        "status" => %{"href" => "/api/v3/statuses/15", "title" => "Human Review"},
        "priority" => %{"href" => "/api/v3/priorities/8", "title" => "Normal"},
        "assignee" => %{"href" => "/api/v3/users/4", "title" => "OpenProject Admin"}
      }
    }

    issue = Client.normalize_work_package(wp)

    assert issue.id == "37"
    assert issue.identifier == "WP-37"
    assert issue.title == "OpenProject 연동 스모크 테스트"
    assert issue.description == "본문"
    assert issue.state == "Human Review"
    assert issue.priority == 3
    assert issue.url == "http://localhost:8080/work_packages/37"
    assert issue.assignee_id == "4"
    assert issue.labels == []
    assert issue.blocked_by == []
    assert issue.dispatchable == true
    assert %DateTime{} = issue.created_at
  end

  test "normalize_work_package tolerates missing optional fields and unknown priority" do
    write_openproject_workflow!()

    issue =
      Client.normalize_work_package(%{
        "id" => 5,
        "subject" => "minimal",
        "_links" => %{"status" => %{"title" => "New"}, "priority" => %{"title" => "Whatever"}}
      })

    assert issue.id == "5"
    assert issue.identifier == "WP-5"
    assert issue.state == "New"
    assert issue.priority == nil
    assert issue.description == nil
    assert issue.assignee_id == nil
    assert issue.created_at == nil
  end

  test "normalize_work_package returns nil for junk" do
    write_openproject_workflow!()
    assert Client.normalize_work_package(%{"no_id" => true}) == nil
    assert Client.normalize_work_package(nil) == nil
  end
end
