# Phase 5 選択肢3: カウンタテーブル（§5）。
# 読み取りは主キー1発で即座。正確だが「誰が更新し続けるか」の問題が残る:
#   - 定期バッチ（refresh_all）: 実装は楽だが最大 N 分の遅延（結果整合）
#   - INSERT/UPDATE/DELETE トリガ: 常に正確だが書き込みごとに競合ポイントが増える
# ここでは定期バッチ方式を実装（トリガはトレードオフの説明用にコメントで示す）。
class OrderStat < ApplicationRecord
  self.primary_key = :status

  # 全 status を集計し直してテーブルを更新する（定期実行を想定）。
  def self.refresh_all
    # group(:status).count は enum 名（"paid" 等）をキーで返す。
    # integer 列にそのまま upsert すると全部 0 にキャストされ衝突するので、
    # Order.statuses で整数コードへ明示変換する。
    counts = Order.group(:status).count
    now = Time.current
    rows = counts.map do |name, count|
      { status: Order.statuses.fetch(name.to_s), count:, updated_at: now }
    end
    upsert_all(rows, unique_by: :status) if rows.any?
  end

  # 保存済みの件数を即座に返す（無ければ nil）。
  def self.count_for(status)
    code = Order.statuses.fetch(status.to_s, status)
    where(status: code).pick(:count)
  end
end
