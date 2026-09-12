class Order < ApplicationRecord
  enum :status, { pending: 0, paid: 1, shipped: 2, cancelled: 3, refunded: 4 }

  # keyset の1ページ分の並び。末尾に一意な id を必ず入れる（§6.2）。
  scope :page_order, -> { order(created_at: :desc, id: :desc) }

  # カーソル (created_at, id) より「過去側」へ進む。
  # 行値比較 (a,b) < (?,?) は複合インデックス idx_c の Index Cond に落ちる（§6.1）。
  # OR手書きにすると Filter になり深いページで破綻するので、必ずこの形にする。
  scope :seek_after, ->(created_at, id) {
    where("(orders.created_at, orders.id) < (?, ?)", created_at, id)
  }

  # Phase 5 選択肢2: 近似カウント（§5 の approximate_count）。
  # プランナが見積もる Plan Rows を使う。全走査せず数ミリ秒で「約N件」を返せる。
  # 精度は直近の ANALYZE に依存する（Google の「約1,230,000件」と同じ発想）。
  def self.approximate_count(status)
    sql = where(status: status).to_sql
    row = connection.select_one("EXPLAIN (FORMAT JSON) #{sql}")
    plan = JSON.parse(row["QUERY PLAN"])
    plan.dig(0, "Plan", "Plan Rows")
  end
end
