# keyset ページネーションの本体（§6.4）。
# LIMIT を per_page+1 にして「次があるか」を1クエリで判定する（COUNT不要 = Phase 5 の伏線）。
class OrderPageQuery
  PER_PAGE = 20

  Result = Struct.new(:records, :next_cursor, keyword_init: true)

  def initialize(status:, cursor: nil, per_page: PER_PAGE)
    @status, @cursor, @per_page = status, cursor, per_page
  end

  def call
    scope = Order.where(status: @status)
                 .page_order
                 .limit(@per_page + 1) # +1 で「次があるか」を判定

    if (c = Cursor.decode(@cursor))
      scope = scope.seek_after(c[:created_at], c[:id])
    end

    rows     = scope.to_a
    has_next = rows.size > @per_page
    rows     = rows.first(@per_page)

    Result.new(
      records:     rows,
      next_cursor: has_next ? Cursor.encode(rows.last) : nil
    )
  end
end
