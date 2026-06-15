require File.expand_path('../test_helper', __dir__)

class RedmineTxAutoDateWorkerSequenceTest < ActiveSupport::TestCase
  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :issues,
           :issue_statuses,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enumerations

  def setup
    @previous_user = User.current

    @planner = User.find(2)
    @developer = User.find(4)
    @qa = User.find(3)

    configure_issue_status_stages
  end

  def teardown
    User.current = @previous_user
    reset_issue_status_stage_cache
  end

  # ---------------------------------------------------------------------------
  # 저장 콜백(assign_tx_auto_date_fields) 시나리오
  # ---------------------------------------------------------------------------

  def test_hook_direct_new_to_implemented_with_assignee_handoff_uses_actor_as_worker
    issue = build_issue(status: @new_status, assigned_to: @planner)

    User.current = @developer
    issue.status = @implemented_status
    issue.assigned_to = @qa

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_not_nil issue.begin_time
    assert_not_nil issue.end_time
  end

  def test_hook_progress_to_implemented_preserves_existing_worker_when_assignee_moves_to_qa
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = build_issue(
      status: @in_progress_status,
      assigned_to: @developer,
      worker: @developer,
      begin_time: started_at
    )

    User.current = @developer
    issue.status = @implemented_status
    issue.assigned_to = @qa

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_not_nil issue.end_time
  end

  def test_hook_scoping_does_not_create_worker_period
    issue = build_issue(status: @new_status, assigned_to: @planner)

    User.current = @planner
    issue.status = @scoping_status

    issue.assign_tx_auto_date_fields

    assert_nil issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time
    assert_nil issue.confirm_time
  end

  def test_hook_review_pingpong_preserves_worker_when_reviewer_restarts_progress
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = build_issue(
      status: @in_progress_status,
      assigned_to: @developer,
      worker: @developer,
      begin_time: started_at
    )

    User.current = @developer
    issue.status = @review_status
    issue.assigned_to = @qa

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
    assert_not_nil issue.confirm_time

    issue.update_columns(
      status_id: @review_status.id,
      assigned_to_id: @qa.id,
      worker_id: issue.worker_id,
      begin_time: issue.begin_time,
      end_time: issue.end_time,
      confirm_time: issue.confirm_time
    )
    issue.reload

    User.current = @qa
    issue.status = @in_progress_status

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
  end

  def test_hook_reopened_implemented_issue_to_progress_clears_end_and_uses_current_assignee
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    finished_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @qa,
      worker: @developer,
      begin_time: started_at,
      end_time: finished_at
    )

    User.current = @developer
    issue.status = @in_progress_status
    issue.assigned_to = @developer

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
  end

  # 결함 ④: 구현끝 -> 검수중 전환 시 작업자(개발자)가 검수자로 덮어써지면 안 된다.
  def test_hook_implemented_to_review_preserves_worker_not_reviewer
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    finished_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @developer,
      worker: @developer,
      begin_time: started_at,
      end_time: finished_at
    )

    User.current = @qa
    issue.status = @review_status
    issue.assigned_to = @qa

    issue.assign_tx_auto_date_fields

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
    assert_not_nil issue.confirm_time
  end

  # 결함 ⑤: 신규 이슈를 곧바로 구현끝 상태로 생성하면 완료시간/작업자가 기록돼야 한다.
  def test_hook_new_issue_created_directly_implemented_records_end_and_worker
    issue = Issue.new(
      project_id: 1,
      tracker_id: 1,
      subject: 'direct implemented',
      author: @developer,
      status: @implemented_status,
      assigned_to: @developer
    )

    User.current = @developer
    issue.assign_tx_auto_date_fields

    assert_not_nil issue.end_time
    assert_not_nil issue.begin_time
    assert_equal @developer.id, issue.worker_id
  end

  # 복사본 등 비활성 상태 이슈에 남은 confirm_time(및 begin/worker)은 정리돼야 한다.
  def test_hook_resets_stale_fields_on_non_work_status
    issue = build_issue(status: @new_status, assigned_to: @planner)
    issue.confirm_time = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue.begin_time = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue.end_time = Time.zone.local(2026, 5, 12, 10, 0, 0)
    issue.worker_id = @developer.id

    issue.assign_tx_auto_date_fields

    assert_nil issue.confirm_time
    assert_nil issue.begin_time
    assert_nil issue.end_time
    assert_nil issue.worker_id
  end

  # before_save 콜백이 실제 save 경로에서 동작하고, 변경이 저널에 기록되는지 (표시 패치 전제)
  def test_save_integration_fires_callback_and_journals_changes
    issue = build_issue(status: @new_status, assigned_to: @developer)

    User.current = @developer
    issue.init_journal(@developer)
    issue.status = @in_progress_status

    assert issue.save
    issue.reload

    assert_not_nil issue.begin_time
    assert_equal @developer.id, issue.worker_id

    journal = issue.journals.detect { |j| j.details.any? { |d| d.prop_key == 'status_id' } }
    assert_not_nil journal, '상태 변경 저널이 있어야 함'
    detail_keys = journal.details.map(&:prop_key)
    assert_includes detail_keys, 'begin_time'
    assert_includes detail_keys, 'worker_id'
  end

  # ---------------------------------------------------------------------------
  # 재계산(update_auto_date!) 시나리오
  # ---------------------------------------------------------------------------

  def test_recalculation_direct_new_to_implemented_with_assignee_handoff_uses_journal_actor
    implemented_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @qa,
      done_ratio: 100
    )

    add_journal(
      issue,
      user: @developer,
      created_on: implemented_at,
      status: [@new_status, @implemented_status],
      assigned_to: [@planner, @qa]
    )

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal implemented_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
  end

  def test_recalculation_progress_to_implemented_preserves_worker_from_progress_start
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    implemented_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @qa,
      done_ratio: 100
    )

    add_journal(
      issue,
      user: @developer,
      created_on: started_at,
      status: [@new_status, @in_progress_status],
      assigned_to: [@planner, @developer]
    )
    add_journal(
      issue,
      user: @developer,
      created_on: implemented_at,
      status: [@in_progress_status, @implemented_status],
      assigned_to: [@developer, @qa]
    )

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
  end

  def test_recalculation_review_pingpong_preserves_original_worker
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    review_at = Time.zone.local(2026, 5, 12, 10, 0, 0)
    rework_at = Time.zone.local(2026, 5, 12, 10, 30, 0)
    implemented_at = Time.zone.local(2026, 5, 12, 12, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @developer,
      done_ratio: 100
    )

    add_journal(
      issue,
      user: @developer,
      created_on: started_at,
      status: [@new_status, @in_progress_status]
    )
    add_journal(
      issue,
      user: @developer,
      created_on: review_at,
      status: [@in_progress_status, @review_status]
    )
    add_journal(
      issue,
      user: @qa,
      created_on: rework_at,
      status: [@review_status, @in_progress_status]
    )
    add_journal(
      issue,
      user: @developer,
      created_on: implemented_at,
      status: [@in_progress_status, @implemented_status]
    )

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
    assert_time_equal review_at, issue.confirm_time
  end

  def test_recalculation_scoping_to_implemented_is_treated_as_direct_implementation
    scoped_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    implemented_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @qa,
      done_ratio: 100
    )

    add_journal(
      issue,
      user: @planner,
      created_on: scoped_at,
      status: [@new_status, @scoping_status],
      assigned_to: [@planner, @planner]
    )
    add_journal(
      issue,
      user: @developer,
      created_on: implemented_at,
      status: [@scoping_status, @implemented_status],
      assigned_to: [@planner, @qa]
    )

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal implemented_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
  end

  def test_recalculation_non_work_status_clears_stale_worker_period_even_when_done_ratio_is_zero
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    finished_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @new_status,
      assigned_to: @planner,
      worker: @developer,
      begin_time: started_at,
      end_time: finished_at,
      done_ratio: 0
    )

    issue.update_auto_date!
    issue.reload

    assert_nil issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time
  end

  # 결함 ①: 재오픈 후 재구현 시 begin > end 로 역전되면 안 된다.
  def test_recalculation_reopen_and_reimplement_keeps_begin_before_end
    t9  = Time.zone.local(2026, 5, 12,  9, 0, 0)
    t10 = Time.zone.local(2026, 5, 12, 10, 0, 0)
    t11 = Time.zone.local(2026, 5, 12, 11, 0, 0)
    t12 = Time.zone.local(2026, 5, 12, 12, 0, 0)
    issue = build_issue(status: @implemented_status, assigned_to: @developer, done_ratio: 100)

    add_journal(issue, user: @developer, created_on: t9,  status: [@new_status, @in_progress_status])
    add_journal(issue, user: @developer, created_on: t10, status: [@in_progress_status, @implemented_status])
    add_journal(issue, user: @developer, created_on: t11, status: [@implemented_status, @in_progress_status])
    add_journal(issue, user: @developer, created_on: t12, status: [@in_progress_status, @implemented_status])

    issue.update_auto_date!
    issue.reload

    assert_time_equal t9, issue.begin_time
    assert_time_equal t12, issue.end_time
    assert issue.begin_time <= issue.end_time, "begin_time(#{issue.begin_time}) > end_time(#{issue.end_time})"
    assert_equal @developer.id, issue.worker_id
  end

  # 결함 ②: 검수중 이슈 재계산 시 작업자(개발자)가 검수자로 덮어써지면 안 된다.
  def test_recalculation_in_review_preserves_worker_not_reviewer
    t9  = Time.zone.local(2026, 5, 12, 9, 0, 0)
    t10 = Time.zone.local(2026, 5, 12, 10, 0, 0)
    issue = build_issue(status: @review_status, assigned_to: @qa, done_ratio: 50)

    add_journal(issue, user: @developer, created_on: t9,
                status: [@new_status, @in_progress_status],
                assigned_to: [@planner, @developer])
    add_journal(issue, user: @developer, created_on: t10,
                status: [@in_progress_status, @review_status],
                assigned_to: [@developer, @qa])

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal t9, issue.begin_time
    assert_nil issue.end_time
    assert_time_equal t10, issue.confirm_time
  end

  # 상태만 진행중으로 바뀐 저널도 콜백과 같이 당시 담당자를 작업자로 사용해야 한다.
  def test_recalculation_status_only_progress_uses_assignee_not_journal_actor
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = build_issue(status: @in_progress_status, assigned_to: @developer, done_ratio: 0)

    add_journal(issue, user: @planner, created_on: started_at,
                status: [@new_status, @in_progress_status])

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
  end

  # 진행 진입 저널에 담당자 변경 detail이 없고 나중에 QA로 핸드오프돼도
  # 재계산은 저널 actor가 아니라 당시 담당자(개발자)를 보존해야 한다.
  def test_recalculation_replays_assignee_when_status_only_progress_is_later_handed_off
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    implemented_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(status: @implemented_status, assigned_to: @qa, done_ratio: 100)

    add_journal(issue, user: @planner, created_on: started_at,
                status: [@new_status, @in_progress_status])
    add_journal(issue, user: @developer, created_on: implemented_at,
                status: [@in_progress_status, @implemented_status],
                assigned_to: [@developer, @qa])

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
  end

  # 결함 ③: done_ratio == 0 이어도 진행중 이슈의 시작시간/작업자는 보존돼야 한다.
  def test_recalculation_in_progress_with_zero_done_ratio_is_preserved
    started_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = build_issue(
      status: @in_progress_status,
      assigned_to: @developer,
      worker: @developer,
      begin_time: started_at,
      done_ratio: 0
    )
    add_journal(issue, user: @developer, created_on: started_at,
                status: [@new_status, @in_progress_status])

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
  end

  # 작업 이력이 있어도 현재 상태가 비작업(신규)으로 회귀하면 수집값을 모두 비워야 한다.
  # (콜백의 리셋 블록과 동일 규칙 — 백필 시 보류/폐기/재오픈 이슈의 기록 부활 방지)
  def test_recalculation_regresses_to_new_clears_work_record
    t9  = Time.zone.local(2026, 5, 12,  9, 0, 0)
    t10 = Time.zone.local(2026, 5, 12, 10, 0, 0)
    t11 = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(status: @new_status, assigned_to: @planner)

    add_journal(issue, user: @developer, created_on: t9,  status: [@new_status, @in_progress_status])
    add_journal(issue, user: @developer, created_on: t10, status: [@in_progress_status, @implemented_status])
    add_journal(issue, user: @planner,   created_on: t11, status: [@implemented_status, @new_status])

    issue.update_auto_date!
    issue.reload

    assert_nil issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time
    assert_nil issue.confirm_time
  end

  # 검수까지 갔다가 비작업(scoping)으로 회귀하면 confirm_time 까지 비워야 한다.
  def test_recalculation_regresses_to_scoping_after_review_clears_confirm_time
    t9  = Time.zone.local(2026, 5, 12,  9, 0, 0)
    t10 = Time.zone.local(2026, 5, 12, 10, 0, 0)
    t11 = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(status: @scoping_status, assigned_to: @planner)

    add_journal(issue, user: @developer, created_on: t9,  status: [@new_status, @in_progress_status])
    add_journal(issue, user: @developer, created_on: t10, status: [@in_progress_status, @review_status])
    add_journal(issue, user: @planner,   created_on: t11, status: [@review_status, @scoping_status])

    issue.update_auto_date!
    issue.reload

    assert_nil issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time
    assert_nil issue.confirm_time
  end

  # 저널 없이 곧바로 구현끝으로 생성된 이슈: 작업자는 작성자(=생성 actor)로 귀속해야 한다.
  # (콜백의 즉시완료 경로가 worker=User.current(작성자)로 잡는 것과 일치 — 담당자로 덮어쓰지 않음)
  def test_recalculation_directly_implemented_without_journal_attributes_author_as_worker
    created_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = Issue.generate!(
      project_id: 1,
      tracker_id: 1,
      status_id: @implemented_status.id,
      author_id: @developer.id,
      done_ratio: 100,
      created_on: created_at,
      updated_on: created_at
    )
    # 생성 시 콜백이 채운 값을 비우고, 상태변경 저널 없는 상태로 만든다.
    # created_on 은 Rails 가 insert 시각으로 덮어쓰므로 명시적으로 고정한다.
    issue.update_columns(
      assigned_to_id: @qa.id,
      worker_id: nil,
      begin_time: nil,
      end_time: nil,
      confirm_time: nil,
      created_on: created_at
    )
    issue.reload

    issue.update_auto_date!
    issue.reload

    assert_equal @developer.id, issue.worker_id, '작성자가 작업자로 귀속돼야 함(담당자 qa 아님)'
    assert_time_equal created_at, issue.begin_time
    assert_time_equal created_at, issue.end_time
  end

  # 상태 변경 저널 없이 검수중으로 존재하는 이슈도 콜백과 같이 검토 시작시각을 백필한다.
  def test_recalculation_directly_in_review_without_journal_sets_confirm_time
    created_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    issue = Issue.generate!(
      project_id: 1,
      tracker_id: 1,
      status_id: @review_status.id,
      author_id: @developer.id,
      done_ratio: 0,
      created_on: created_at,
      updated_on: created_at
    )
    issue.update_columns(
      assigned_to_id: @qa.id,
      worker_id: nil,
      begin_time: nil,
      end_time: nil,
      confirm_time: nil,
      created_on: created_at
    )
    issue.reload

    issue.update_auto_date!
    issue.reload

    assert_equal @qa.id, issue.worker_id
    assert_time_equal created_at, issue.begin_time
    assert_nil issue.end_time
    assert_time_equal created_at, issue.confirm_time
  end

  private

  def configure_issue_status_stages
    @new_status = IssueStatus.find(1)
    @in_progress_status = IssueStatus.find(2)
    @implemented_status = IssueStatus.find(3)
    @review_status = IssueStatus.find(4)
    @scoping_status = IssueStatus.find(5)
    @completed_status = IssueStatus.find(6)

    @new_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_NEW)
    @in_progress_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_IN_PROGRESS)
    @implemented_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_IMPLEMENTED)
    @review_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_REVIEW)
    @scoping_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_SCOPING)
    @completed_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_COMPLETED)

    [@new_status, @in_progress_status, @implemented_status, @review_status, @scoping_status, @completed_status].each(&:reload)
    reset_issue_status_stage_cache
  end

  def reset_issue_status_stage_cache
    TxAdvancedIssueStatusHelper.class_variable_set(:@@all_issue_statuses, nil)
    TxAdvancedIssueStatusHelper.class_variable_set(:@@all_issue_statuses_updated_at, nil)
  end

  def build_issue(status:, assigned_to:, worker: nil, begin_time: nil, end_time: nil, done_ratio: 30)
    issue = Issue.generate!(
      project_id: 1,
      tracker_id: 1,
      status_id: status.id,
      author_id: @planner.id,
      done_ratio: done_ratio,
      created_on: Time.zone.local(2026, 5, 12, 8, 0, 0),
      updated_on: Time.zone.local(2026, 5, 12, 8, 0, 0)
    )
    issue.update_columns(
      assigned_to_id: assigned_to&.id,
      worker_id: worker&.id,
      begin_time: begin_time,
      end_time: end_time,
      confirm_time: nil
    )
    issue.reload
  end

  def add_journal(issue, user:, created_on:, status: nil, assigned_to: nil)
    journal = Journal.new(
      journalized: issue,
      user: user,
      notes: '',
      created_on: created_on
    )
    journal.notify = false if journal.respond_to?(:notify=)

    if status
      journal.details.build(
        property: 'attr',
        prop_key: 'status_id',
        old_value: status.first.id.to_s,
        value: status.last.id.to_s
      )
    end

    if assigned_to
      journal.details.build(
        property: 'attr',
        prop_key: 'assigned_to_id',
        old_value: assigned_to.first&.id&.to_s,
        value: assigned_to.last&.id&.to_s
      )
    end

    journal.save!
    journal
  end

  def assert_time_equal(expected, actual)
    assert_not_nil actual
    assert_equal expected.to_i, actual.to_i
  end
end
