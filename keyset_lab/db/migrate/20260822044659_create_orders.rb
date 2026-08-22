class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.bigint     :user_id,     null: false
      t.integer    :status,      null: false, limit: 2
      t.integer    :total_cents, null: false
      t.datetime   :created_at,  null: false
    end
    # Phase 2 で「インデックスなしの地獄」を体験するため、
    # この時点では PRIMARY KEY 以外のインデックスを一切張らない（計画書 §2）。
  end
end
