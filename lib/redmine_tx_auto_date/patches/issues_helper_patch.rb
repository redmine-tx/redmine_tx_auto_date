module RedmineTxAutoDate
  module Patches
    module IssuesHelperPatch
      def self.included(base)
        base.send(:include, InstanceMethods)
        base.send(:alias_method, :show_detail_without_tx_auto_date, :show_detail)
        base.send(:alias_method, :show_detail, :show_detail_with_tx_auto_date)
      end

      module InstanceMethods
        def show_detail_with_tx_auto_date(detail, no_html=false, options={})
          # 우리가 처리할 필드들인지 확인
          if detail.property == 'attr'
            case detail.prop_key
            when 'worker_id'
              # worker_id를 assigned_to_id처럼 처리하기 위해 기존 로직 활용
              field = detail.prop_key.to_s.delete_suffix('_id')
              label = l(:field_worker)
              value = find_name_by_reflection(field, detail.value)
              old_value = find_name_by_reflection(field, detail.old_value)
              
              # 기존 show_detail의 공통 렌더링 로직 호출
              return render_detail_change(detail, label, value, old_value, no_html, options)
              
            when 'begin_time', 'end_time', 'confirm_time'
              # DateTime 필드들을 due_date/start_date처럼 처리
              field = detail.prop_key.to_s
              label = l(("field_#{field}").to_sym)
              
              begin
                value = detail.value.present? ? format_time(Time.parse(detail.value.to_s)) : nil
                old_value = detail.old_value.present? ? format_time(Time.parse(detail.old_value.to_s)) : nil
              rescue ArgumentError
                value = detail.value.to_s if detail.value.present?
                old_value = detail.old_value.to_s if detail.old_value.present?
              end
              
              return render_detail_change(detail, label, value, old_value, no_html, options)
            end
          end
          
          # 우리가 처리하지 않는 필드는 기존 로직으로
          show_detail_without_tx_auto_date(detail, no_html, options)
        end
        
        private
        
        def render_detail_change(detail, label, value, old_value, no_html, options)
          # 기존 show_detail의 공통 로직을 단순화해서 재사용
          call_hook(:helper_issues_show_detail_after_setting, 
                   { :detail => detail, :label => label, :value => value, :old_value => old_value })
          
          value ||= ""
          old_value ||= ""
          
          unless no_html
            label = content_tag('strong', label, :class => 'field')
            old_value = content_tag("i", h(old_value)) if detail.old_value.present?
            old_value = content_tag("strike", old_value) if detail.old_value.present? && detail.value.blank?
            value = content_tag("i", h(value)) if value.present?
          end
          
          if detail.value.present?
            case detail.old_value
            when nil, ""
              l(:text_journal_set_to, :label => label, :value => value).html_safe
            else
              l(:text_journal_changed, :label => label, :old => old_value, :new => value).html_safe
            end
          elsif detail.old_value.present?
            l(:text_journal_deleted, :label => label, :old => old_value).html_safe
          else
            l(:text_journal_changed_no_detail, :label => label).html_safe
          end
        end
      end
    end
  end
end

unless IssuesHelper.included_modules.include?(RedmineTxAutoDate::Patches::IssuesHelperPatch)
  IssuesHelper.send(:include, RedmineTxAutoDate::Patches::IssuesHelperPatch)
end