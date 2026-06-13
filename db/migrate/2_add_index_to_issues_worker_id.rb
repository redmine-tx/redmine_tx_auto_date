class AddIndexToIssuesWorkerId < ActiveRecord::Migration[5.2]
  def up
    add_index :issues, :worker_id unless index_exists?(:issues, :worker_id)
  end

  def down
    remove_index :issues, :worker_id if index_exists?(:issues, :worker_id)
  end
end
