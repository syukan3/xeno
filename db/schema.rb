# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 2020_04_19_070426) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "cards", force: :cascade do |t|
    t.integer "xeno_id", null: false
    t.integer "card_num", null: false
    t.boolean "reincarnation_card", default: false
    t.integer "player_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "players", force: :cascade do |t|
    t.integer "xeno_id", null: false
    t.integer "hand"
    t.boolean "predict_flag"
    t.boolean "defence_flag"
    t.boolean "mannual_flag"
    t.integer "order"
    t.string "user_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "dead_flag", default: false
    t.string "line_user_id"
  end

  create_table "xenos", force: :cascade do |t|
    t.integer "status", null: false
    t.integer "num_of_player"
    t.integer "now_order"
    t.integer "winner_player_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

end
