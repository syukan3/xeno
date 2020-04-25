class ChangeFieldFlagToCard < ActiveRecord::Migration[5.2]
  def change
    remove_column :cards, :field_flag
    add_column :cards, :field_flag, :boolean, default: false
  end
end
