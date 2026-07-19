defmodule SymphonyElixir.LiveOpenProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OpenProject.Client

  @moduletag timeout: 120_000

  @endpoint "http://localhost:8080"
  @project "crypto-server"

  test "live: fetch, transition with lock version, comment, reconcile" do
    if System.get_env("SYMPHONY_RUN_LIVE_OPENPROJECT") == "1" do
      api_key = System.fetch_env!("OPENPROJECT_API_KEY")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "openproject",
        tracker_endpoint: @endpoint,
        tracker_api_token: api_key,
        tracker_project_slug: @project,
        tracker_active_states: ["New", "In progress", "Merging", "Rework"],
        tracker_terminal_states: ["Done", "Canceled", "Duplicate", "Rejected", "Closed"]
      )

      # 픽스처 워크패키지 생성 (Client.request/4 재사용)
      {:ok, wp} =
        Client.request(:post, "/projects/#{@project}/work_packages", [], %{
          "subject" => "live-adapter-#{System.unique_integer([:positive])}",
          "_links" => %{"type" => %{"href" => "/api/v3/types/1"}}
        })

      wp_id = to_string(wp["id"])

      try do
        # 1. 폴링 경로: New 상태의 픽스처가 잡혀야 함
        {:ok, candidates} = Client.fetch_candidate_issues()
        fixture = Enum.find(candidates, &(&1.id == wp_id))
        assert fixture, "fixture WP-#{wp_id} not returned by fetch_candidate_issues"
        assert fixture.identifier == "WP-#{wp_id}"
        assert fixture.state == "New"

        # 2. 상태 전환 (lockVersion 경로) — 연속 2회로 lockVersion 증가도 검증
        assert :ok = Client.update_issue_state(wp_id, "In progress")
        assert :ok = Client.update_issue_state(wp_id, "Human Review")

        # 3. reconcile 경로
        {:ok, [refreshed]} = Client.fetch_issue_states_by_ids([wp_id])
        assert refreshed.state == "Human Review"

        # 4. 코멘트 (워크패드 경로)
        assert :ok = Client.create_comment(wp_id, "## Agent Workpad\n\n- [x] live adapter smoke")

        # 5. 존재하지 않는 상태명은 명시적 에러
        assert {:error, {:status_not_found, "No Such State"}} =
                 Client.update_issue_state(wp_id, "No Such State")
      after
        # 정리: 픽스처 삭제 (실패해도 테스트 결과에는 영향 없음)
        Client.request(:delete, "/work_packages/#{wp_id}", [], nil)
      end
    else
      assert true
    end
  end
end
