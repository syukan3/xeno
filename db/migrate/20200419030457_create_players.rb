class CreatePlayers < ActiveRecord::Migration[5.2]
  def change
    create_table :players do |t|
      t.integer :xeno_id, null:false
      t.integer :hand
      t.boolean :predict_flag
      t.boolean :defence_flag
      t.boolean :mannual_flag
      t.integer :order
      t.integer :line_user_id
      t.string :user_name
      t.boolean :dead_flag, null: false

      t.timestamps
    end
  end
end
