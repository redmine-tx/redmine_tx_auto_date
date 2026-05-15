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
    @hook = RedmineTxAutoDateHelper::Hooks.send(:new)

    @planner = User.find(2)
    @developer = User.find(4)
    @qa = User.find(3)

    configure_issue_status_stages
  end

  def teardown
    User.current = @previous_user
    reset_issue_status_stage_cache
  end

  def test_hook_direct_new_to_implemented_with_assignee_handoff_uses_actor_as_worker
    issue = build_issue(status: @new_status, assigned_to: @planner)

    User.current = @developer
    issue.status = @implemented_status
    issue.assigned_to = @qa

    @hook.controller_issues_edit_before_save(issue: issue)

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

    @hook.controller_issues_edit_before_save(issue: issue)

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_not_nil issue.end_time
  end

  def test_hook_planning_review_does_not_create_worker_period
    issue = build_issue(status: @new_status, assigned_to: @planner)

    User.current = @planner
    issue.status = @planning_review_status

    @hook.controller_issues_edit_before_save(issue: issue)

    assert_nil issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time
    assert_not_nil issue.confirm_time
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
    issue.status = @planning_review_status
    issue.assigned_to = @qa

    @hook.controller_issues_edit_before_save(issue: issue)

    assert_equal @developer.id, issue.worker_id
    assert_nil issue.begin_time
    assert_nil issue.end_time

    issue.update_columns(
      status_id: @planning_review_status.id,
      assigned_to_id: @qa.id,
      worker_id: issue.worker_id,
      begin_time: issue.begin_time,
      end_time: issue.end_time,
      confirm_time: issue.confirm_time
    )
    issue.reload

    User.current = @qa
    issue.status = @in_progress_status

    @hook.controller_issues_edit_before_save(issue: issue)

    assert_equal @developer.id, issue.worker_id
    assert_not_nil issue.begin_time
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

    @hook.controller_issues_edit_before_save(issue: issue)

    assert_equal @developer.id, issue.worker_id
    assert_time_equal started_at, issue.begin_time
    assert_nil issue.end_time
  end

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
      status: [@in_progress_status, @planning_review_status]
    )
    add_journal(
      issue,
      user: @qa,
      created_on: rework_at,
      status: [@planning_review_status, @in_progress_status]
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
    assert_time_equal rework_at, issue.begin_time
    assert_time_equal implemented_at, issue.end_time
  end

  def test_recalculation_planning_review_to_implemented_is_treated_as_direct_implementation
    reviewed_at = Time.zone.local(2026, 5, 12, 9, 0, 0)
    implemented_at = Time.zone.local(2026, 5, 12, 11, 0, 0)
    issue = build_issue(
      status: @implemented_status,
      assigned_to: @qa,
      done_ratio: 100
    )

    add_journal(
      issue,
      user: @planner,
      created_on: reviewed_at,
      status: [@new_status, @planning_review_status],
      assigned_to: [@planner, @planner]
    )
    add_journal(
      issue,
      user: @developer,
      created_on: implemented_at,
      status: [@planning_review_status, @implemented_status],
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

  private

  def configure_issue_status_stages
    @new_status = IssueStatus.find(1)
    @in_progress_status = IssueStatus.find(2)
    @implemented_status = IssueStatus.find(3)
    @planning_review_status = IssueStatus.find(4)
    @qa_status = IssueStatus.find(5)
    @completed_status = IssueStatus.find(6)

    @new_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_NEW)
    @in_progress_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_IN_PROGRESS)
    @implemented_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_IMPLEMENTED)
    @planning_review_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_PLANNING_REVIEW)
    @qa_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_QA)
    @completed_status.update_columns(stage: TxAdvancedIssueStatusHelper::STAGE_COMPLETED)

    [@new_status, @in_progress_status, @implemented_status, @planning_review_status, @qa_status, @completed_status].each(&:reload)
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
