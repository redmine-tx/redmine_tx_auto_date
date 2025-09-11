module RedmineTxAutoDateHelper
    class Hooks < Redmine::Hook::ViewListener

      render_on :view_issues_show_details_bottom, partial: 'issues/tx_auto_date'

      def controller_issues_edit_before_save(context={})
        
        if true then
          
          issue = context[:issue]

          # 시작 시간 자동 설정
          if issue.begin_time.blank? && issue.status.is_in_progress?
            issue.begin_time = DateTime.now
            issue.worker_id = issue.assigned_to_id
          end

          # 종료 시간 자동 설정
          if issue.id && issue.end_time.blank? && issue.status.is_implemented?
            prev_issue = Issue.find(issue.id)
            issue.end_time = DateTime.now
            issue.worker_id = prev_issue.assigned_to_id
          end

          # 컨펌 시작 시간 설정
          if issue.confirm_time.blank? && issue.status.is_in_review?
            issue.confirm_time = DateTime.now
          end

          if issue.end_time.present? && !issue.status.is_implemented?
            # 완료 상태가 아니면 완료시간 삭제
            issue.end_time = nil

            # 작업 상태면 작업자 설정
            if issue.status.is_in_progress? then
              issue.worker_id = issue.assigned_to_id
            else
              if !issue.status.is_in_review? then
                issue.worker_id = nil
              end
            end
          end

          # 완료시간이 있는데 시작시간이 없으면 시작시간을 완료시간으로 설정
          if issue.end_time.present? && issue.begin_time.blank? then
            issue.begin_time = issue.end_time
          end

          if !issue.status.is_in_progress? && !issue.status.is_implemented? then
            issue.begin_time = nil
            issue.end_time = nil
            issue.worker_id = nil
          end
        end

      end

      def controller_issues_new_before_save(context={})
        controller_issues_edit_before_save(context)
      end

      def controller_issues_bulk_edit_before_save(context={})
        controller_issues_edit_before_save(context)
      end
    end
end

