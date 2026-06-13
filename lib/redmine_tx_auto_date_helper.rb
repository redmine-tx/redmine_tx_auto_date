module RedmineTxAutoDateHelper
    class Hooks < Redmine::Hook::ViewListener
      # 일감 상세 하단에 작업자/작업기간 표시
      render_on :view_issues_show_details_bottom, partial: 'issues/tx_auto_date'

      # 작업 일정·작업자 자동 기록은 Issue#assign_tx_auto_date_fields (before_save 콜백)에서
      # 처리한다. 컨트롤러 훅으로는 메일/커밋/일괄수정 등 일부 저장 경로를 놓치기 때문이다.
      # (RedmineTxAutoDate::Patches::IssuePatch 참조)
    end
end
