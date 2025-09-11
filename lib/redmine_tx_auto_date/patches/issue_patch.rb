module RedmineTxAutoDate
  module Patches
    module IssuePatch
      def self.included(base)
        base.class_eval do
          belongs_to :worker, class_name: 'User', optional: true
        end
      end
      
      def status_history
        self.journals.select { |j| j.visible_details.find{ |d| d.prop_key == 'status_id' } }.map { |j| [ j.created_on, j.visible_details.find{ |d| d.prop_key == 'status_id' }.value ] }
      end

      def update_auto_date!
        old_worker_id = self.worker_id
        old_begin_time = self.begin_time
        old_end_time = self.end_time

        new_worker_id = nil
        new_begin_time = nil
        new_end_time = nil
        
        # 작업 시작 안한 경우면 정보 리셋
        if self.done_ratio == 0 then
          new_worker_id = nil
          new_begin_time = nil
          new_end_time = nil
          return
        end

        last_worker_id = self.assigned_to_id

        self.journals.each do |journal| 
          visible_details = journal.visible_details
          detail_assigned_to_id = visible_details.find{ |d| d.prop_key == 'assigned_to_id' }
          detail_status_id = visible_details.find{ |d| d.prop_key == 'status_id' }

          _old_assigned_to_id = nil
          _new_assigned_to_id = nil

          if detail_assigned_to_id then
            _old_assigned_to_id = detail_assigned_to_id.old_value.to_i
            _new_assigned_to_id = detail_assigned_to_id.value.to_i
          end
          
          if detail_status_id then
            old_status_id = detail_status_id.old_value.to_i
            new_status_id = detail_status_id.value.to_i

            # 작업 시작한 경우
            if ( detail_status_id && !IssueStatus.is_in_progress?( old_status_id ) && IssueStatus.is_in_progress?( new_status_id ) ) then
              new_begin_time = journal.created_on
              if detail_assigned_to_id then
                new_worker_id = _new_assigned_to_id 
              else
                new_worker_id = journal.user_id
              end
            end

            is_implemented = ( detail_status_id && IssueStatus.is_implemented?( old_status_id ) && IssueStatus.is_implemented?( new_status_id ) )

            # 작업 종료한 경우
            if new_end_time == nil && is_implemented then
              new_end_time = journal.created_on
              if detail_assigned_to_id then
                new_worker_id = _old_assigned_to_id
              end
            end
          end
        end

        # 현재 작업중인 경우면 작업자 설정
        if IssueStatus.is_in_progress?( self.status_id ) && !IssueStatus.is_implemented?( self.status_id ) then
          new_worker_id = self.assigned_to_id
          new_begin_time = self.created_on if new_begin_time.nil?
          new_end_time = nil
        end

        # 완료된 이유인데 기록상 완료가없으면..
        if new_end_time.blank? && IssueStatus.is_implemented?( self.status_id ) then
          new_end_time = self.created_on
          new_worker_id = self.assigned_to_id if new_worker_id.nil?
        end

        # 완료시간은 있는데 시작시간이 없으면 즉시완료한걸로..
        if new_end_time && new_begin_time.nil? then
          new_begin_time = new_end_time
          new_worker_id = self.assigned_to_id if new_worker_id.nil?
        end

        # 완료시간은 있는데 작업자가 없으면
        if ( new_begin_time || new_end_time ) && new_worker_id.nil? then
          new_worker_id = self.assigned_to_id
        end

        if old_worker_id != new_worker_id || old_begin_time != new_begin_time || old_end_time != new_end_time then
          ActiveRecord::Base.connection.execute(
            "UPDATE issues 
             SET worker_id = #{new_worker_id.nil? ? 'NULL' : new_worker_id},
                 begin_time = #{new_begin_time.nil? ? 'NULL' : "'#{new_begin_time.localtime.strftime('%Y-%m-%d %H:%M:%S')}'"},
                 end_time = #{new_end_time.nil? ? 'NULL' : "'#{new_end_time.localtime.strftime('%Y-%m-%d %H:%M:%S')}'"}
             WHERE id = #{self.id}"
          )
          self.worker_id = new_worker_id
          self.begin_time = new_begin_time
          self.end_time = new_end_time
        end
      end
    end
  end
end

unless Issue.included_modules.include?(RedmineTxAutoDate::Patches::IssuePatch)
  Issue.send(:include, RedmineTxAutoDate::Patches::IssuePatch)
end