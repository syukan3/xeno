class ChangeUserIdIntegerToString < ActiveRecord::Migration[5.2]
  def change
    remove_column :players, :line_user_id
    add_column :players, :line_user_id, :string
  end
end
