class CreateOrderStats < ActiveRecord::Migration[8.1]
  def change
    # Phase 5 選択肢3: カウンタテーブル。
    # status ごとの件数を1行で保持し、読み取りは主キー1発（数十µs）。
    # 正確だが、更新競合・整合性・リアルタイム性のコストを別途払う。
    create_table :order_stats, id: false do |t|
      t.integer :status, null: false, primary_key: true
      t.bigint  :count,  null: false, default: 0
      t.datetime :updated_at, null: false
    end
  end
end
