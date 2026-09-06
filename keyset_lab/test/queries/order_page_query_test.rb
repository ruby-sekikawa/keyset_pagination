require "test_helper"

class OrderPageQueryTest < ActiveSupport::TestCase
  # 自前でデータを組み立てる。ポイントは「同一秒（マイクロ秒だけ違う）行の塊」を
  # 境界にまたがせること。これで §6.5 の iso8601(6) 精度要件を直接検証できる。
  setup do
    base = Time.utc(2026, 6, 1, 0, 0, 0)
    rows = []
    # 200件の refunded。半分は「同一秒・マイクロ秒だけ違う」塊にして境界をまたがせる。
    100.times do |i|
      rows << { user_id: 1, status: 4, total_cents: 100,
                created_at: base + i.seconds }
    end
    100.times do |i|
      # すべて同じ秒(base+500s)。マイクロ秒だけ 0,1,2,... とずらす。
      rows << { user_id: 1, status: 4, total_cents: 100,
                created_at: (base + 500.seconds) + (i * 1e-6) }
    end
    # ノイズとして paid も混ぜる（絞り込みが効くことの確認）
    50.times { |i| rows << { user_id: 2, status: 1, total_cents: 100, created_at: base + i.seconds } }

    Order.insert_all!(rows)
    @refunded_total = 200
  end

  test "全ページを繰って重複も欠落もない（§6.7）" do
    seen, cursor = [], nil
    50.times do
      r = OrderPageQuery.new(status: "refunded", cursor: cursor).call
      seen.concat(r.records.map(&:id))
      cursor = r.next_cursor
      break if cursor.nil?
    end

    # 全 refunded を過不足なく辿れている
    assert_equal @refunded_total, seen.size, "件数が合わない（欠落 or 重複）"
    assert_equal seen.uniq.size, seen.size, "重複あり"

    expected = Order.where(status: "refunded")
                    .order(created_at: :desc, id: :desc)
                    .pluck(:id)
    assert_equal expected, seen, "順序または欠落の問題"
  end

  test "同一秒境界でも取りこぼさない（iso8601(6)の精度が効いている）" do
    # per_page=5 で細かく繰り、同一秒の塊が必ず境界にまたがるようにする
    seen, cursor = [], nil
    100.times do
      r = OrderPageQuery.new(status: "refunded", cursor: cursor, per_page: 5).call
      seen.concat(r.records.map(&:id))
      cursor = r.next_cursor
      break if cursor.nil?
    end
    assert_equal @refunded_total, seen.size, "同一秒境界で欠落 or 重複"
    assert_equal seen.uniq.size, seen.size, "重複あり（境界の精度落ち）"
  end

  test "壊れたカーソルは1ページ目扱いになる" do
    r = OrderPageQuery.new(status: "refunded", cursor: "not-a-valid-cursor").call
    assert_equal 20, r.records.size
    # 先頭ページ（最新）から始まっている
    newest = Order.where(status: "refunded").order(created_at: :desc, id: :desc).first
    assert_equal newest.id, r.records.first.id
  end
end
