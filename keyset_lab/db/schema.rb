# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_06_074714) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_prewarm"
  enable_extension "pg_stat_statements"

  create_table "order_stats", primary_key: "status", id: :serial, force: :cascade do |t|
    t.bigint "count", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "status", limit: 2, null: false
    t.integer "total_cents", null: false
    t.bigint "user_id", null: false
    t.index ["status", "created_at", "id"], name: "idx_c", order: { created_at: :desc, id: :desc }
  end
end
