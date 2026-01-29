class AddBeginEndToIssues < ActiveRecord::Migration[5.2]
  def up
    add_column :issues, :begin_time, :datetime unless column_exists?(:issues, :begin_time)
    add_column :issues, :confirm_time, :datetime unless column_exists?(:issues, :confirm_time)
    add_column :issues, :end_time, :datetime unless column_exists?(:issues, :end_time)
    add_column :issues, :worker_id, :integer unless column_exists?(:issues, :worker_id)
  end

  def down
    remove_column :issues, :begin_time if column_exists?(:issues, :begin_time)
    remove_column :issues, :confirm_time if column_exists?(:issues, :confirm_time)
    remove_column :issues, :end_time if column_exists?(:issues, :end_time)
    remove_column :issues, :worker_id if column_exists?(:issues, :worker_id)
  end
end
