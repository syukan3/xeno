class AddFieldFlagToCard < ActiveRecord::Migration[5.2]
  def change
    add_column :cards, :field_flag, :boolean
  end
end
