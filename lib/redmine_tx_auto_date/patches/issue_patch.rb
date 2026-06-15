module RedmineTxAutoDate
  module Patches
    module IssuePatch
      def self.included(base)
        base.class_eval do
          belongs_to :worker, class_name: 'User', optional: true

          # 컨트롤러 훅 대신 모델 콜백으로 동작시켜 웹/REST/메일/커밋/일괄수정 등
          # 모든 저장 경로에서 작업 일정·작업자가 일관되게 기록되도록 한다.
          before_save :assign_tx_auto_date_fields
        end
      end

      # 상태 변경 이력: [변경시각, 상태ID(string)] 배열 (시간순)
      def status_history
        tx_auto_date_journals_in_order.filter_map do |journal|
          detail = journal.visible_details.find { |d| d.prop_key == 'status_id' }
          [journal.created_on, detail.value] if detail
        end
      end

      # 저장 시점 자동 보정.
      # 상태(stage) 전환을 dirty tracking 으로 감지하여 begin/end/confirm/worker 를 채운다.
      def assign_tx_auto_date_fields
        worker_id_for_progress = self.assigned_to_id
        prev_in_progress = IssueStatus.is_in_progress?(status_id_was)
        prev_implemented = IssueStatus.is_implemented?(status_id_was)

        now_in_progress  = IssueStatus.is_in_progress?(self.status_id)
        now_implemented  = IssueStatus.is_implemented?(self.status_id)
        now_in_review    = IssueStatus.is_in_review?(self.status_id)

        # 작업 시작: 진행/검수 단계에 처음 진입하면 시작시간·작업자 기록
        if self.begin_time.blank? && now_in_progress
          self.begin_time = DateTime.now
          self.worker_id = worker_id_for_progress
        end

        # 작업 종료: 구현끝(이상) 단계 진입 시 완료시간 기록
        if self.end_time.blank? && now_implemented
          self.end_time = DateTime.now
          self.worker_id =
            if !prev_in_progress && !prev_implemented
              # 진행 단계를 거치지 않은 즉시 완료: 실제 처리자(현재 사용자)
              User.current.id
            else
              self.worker_id || worker_id_was || assigned_to_id_was
            end
        end

        # 검수 시작: 검수중 단계 첫 진입 시 검토 시작시간 기록
        if self.confirm_time.blank? && now_in_review
          self.confirm_time = DateTime.now
        end

        # 완료 상태가 아닌데 완료시간이 남아있으면 정리
        if self.end_time.present? && !now_implemented
          self.end_time = nil

          if now_in_review
            # 검수중으로 내려간 경우: 실제 작업자(개발자)를 그대로 유지한다.
          elsif now_in_progress
            # 다시 활성 작업 상태: 현재 담당자를 작업자로 설정
            self.worker_id = worker_id_for_progress
          else
            self.worker_id = nil
          end
        end

        # 완료시간은 있는데 시작시간이 없으면 즉시 완료로 간주
        if self.end_time.present? && self.begin_time.blank?
          self.begin_time = self.end_time
        end

        # 진행·완료 어느 단계도 아니면 자동 수집값 초기화 (복사본의 잔존값 포함)
        unless now_in_progress || now_implemented
          self.begin_time = nil
          self.end_time = nil
          self.confirm_time = nil
          self.worker_id = nil
        end
      end

      # 저널 이력 전체를 재생하여 begin/end/confirm/worker 를 재계산한다.
      # 훅이 누락된 과거 데이터의 백필/복구용. assign_tx_auto_date_fields 와 같은 결과를
      # 내도록 정합을 맞춘다.
      def update_auto_date!
        old_worker_id   = self.worker_id
        old_begin_time  = self.begin_time
        old_end_time    = self.end_time
        old_confirm_time = self.confirm_time

        new_worker_id   = nil
        new_begin_time  = nil
        new_end_time    = nil
        new_confirm_time = nil

        ordered_journals = tx_auto_date_journals_in_order
        first_assigned_to_detail = ordered_journals.filter_map do |journal|
          journal.visible_details.find { |d| d.prop_key == 'assigned_to_id' }
        end.first
        replay_assigned_to_id =
          if first_assigned_to_detail
            tx_auto_date_integer_or_nil(first_assigned_to_detail.old_value)
          else
            self.assigned_to_id
          end

        ordered_journals.each do |journal|
          visible_details = journal.visible_details
          detail_assigned_to_id = visible_details.find { |d| d.prop_key == 'assigned_to_id' }
          detail_status_id = visible_details.find { |d| d.prop_key == 'status_id' }

          assigned_to_before_journal = replay_assigned_to_id
          assigned_to_after_journal =
            if detail_assigned_to_id
              tx_auto_date_integer_or_nil(detail_assigned_to_id.value)
            else
              replay_assigned_to_id
            end

          unless detail_status_id
            replay_assigned_to_id = assigned_to_after_journal if detail_assigned_to_id
            next
          end

          old_status_id = detail_status_id.old_value.to_i
          new_status_id = detail_status_id.value.to_i

          started = !IssueStatus.is_in_progress?(old_status_id) && IssueStatus.is_in_progress?(new_status_id)
          entered_review = !IssueStatus.is_in_review?(old_status_id) && IssueStatus.is_in_review?(new_status_id)
          is_implemented = !IssueStatus.is_implemented?(old_status_id) && IssueStatus.is_implemented?(new_status_id)
          is_directly_implemented = is_implemented && !IssueStatus.is_in_progress?(old_status_id)

          # 작업 시작(최초 1회): 시작시간/작업자 확정
          if started
            new_begin_time = journal.created_on if new_begin_time.nil?
            if new_worker_id.nil?
              new_worker_id = assigned_to_after_journal
            end
          end

          # 검수 시작(최초 1회): 검토 시작시간
          if entered_review && new_confirm_time.nil?
            new_confirm_time = journal.created_on
          end

          # 작업 종료: 마지막 구현 시점으로 갱신 (재오픈 후 재구현 포함)
          if is_implemented
            new_end_time = journal.created_on
            if new_worker_id.nil?
              if is_directly_implemented
                new_worker_id = journal.user_id
              elsif detail_assigned_to_id
                new_worker_id = assigned_to_before_journal
              end
            end
          end

          replay_assigned_to_id = assigned_to_after_journal if detail_assigned_to_id
        end

        # 현재 진행/검수중(완료 전)이면 보정
        if IssueStatus.is_in_progress?(self.status_id) && !IssueStatus.is_implemented?(self.status_id)
          new_worker_id = self.assigned_to_id if new_worker_id.nil?
          new_begin_time = self.created_on if new_begin_time.nil?
          new_end_time = nil
          if new_confirm_time.nil? && IssueStatus.is_in_review?(self.status_id)
            new_confirm_time = self.confirm_time || self.created_on
          end
        end

        # 구현끝 상태인데 기록상 완료가 없으면 (예: 저널 없이 곧바로 구현끝으로 생성)
        # 작업자는 작성자(=생성 actor)로 귀속한다. 콜백의 즉시완료 경로가 worker를
        # User.current(=작성자)로 잡는 것과 일치시키기 위함이며, 담당자(검수자 등으로
        # 핸드오프됐을 수 있음)로 덮어쓰지 않는다.
        if new_end_time.blank? && IssueStatus.is_implemented?(self.status_id)
          new_end_time = self.created_on
          new_worker_id = self.author_id if new_worker_id.nil?
        end

        # 완료시간은 있는데 시작시간이 없으면 즉시완료로 간주
        if new_end_time && new_begin_time.nil?
          new_begin_time = new_end_time
          new_worker_id = self.assigned_to_id if new_worker_id.nil?
        end

        # 시작/완료가 잡혔는데 작업자가 없으면
        if (new_begin_time || new_end_time) && new_worker_id.nil?
          new_worker_id = self.assigned_to_id
        end

        # 진행·완료 어느 단계도 아니면(현재 상태 기준) 수집값 초기화.
        # 과거에 작업 이력이 있어도 현재가 비작업 상태(신규/검토중/보류/폐기)면 비운다.
        # assign_tx_auto_date_fields(before_save 콜백)의 리셋 블록과 동일 규칙으로,
        # 두 경로가 같은 결과를 내도록 맞춘다.
        unless IssueStatus.is_in_progress?(self.status_id) || IssueStatus.is_implemented?(self.status_id)
          new_worker_id = nil
          new_begin_time = nil
          new_end_time = nil
          new_confirm_time = nil
        end

        changed =
          old_worker_id != new_worker_id ||
          old_begin_time != new_begin_time ||
          old_end_time != new_end_time ||
          old_confirm_time != new_confirm_time

        if changed
          update_columns(
            worker_id: new_worker_id,
            begin_time: new_begin_time,
            end_time: new_end_time,
            confirm_time: new_confirm_time
          )
        end
      end

      private

      # 저널을 시간순(동시각이면 id순)으로 정렬해 반환한다.
      def tx_auto_date_journals_in_order
        journals.to_a.sort_by { |j| [j.created_on, j.id.to_i] }
      end

      def tx_auto_date_integer_or_nil(value)
        value.present? ? value.to_i : nil
      end
    end
  end
end

unless Issue.included_modules.include?(RedmineTxAutoDate::Patches::IssuePatch)
  Issue.send(:include, RedmineTxAutoDate::Patches::IssuePatch)
end
