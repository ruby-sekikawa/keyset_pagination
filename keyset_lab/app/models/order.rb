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
end
