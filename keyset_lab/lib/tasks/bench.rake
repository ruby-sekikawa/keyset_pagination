# lib/tasks/bench.rake
require "benchmark"

namespace :lab do
  desc "OFFSET vs Keyset の分布比較（p50/p95/p99）"
  task bench: :environment do
    status = "paid"
    CursorRec = Struct.new(:created_at, :id)

    # 現実的なカーソル群をサンプリング（浅い〜深いページが混ざるようにする）
    cursors = Order.where(status: status)
                   .order(created_at: :desc, id: :desc)
                   .limit(200_000)
                   .pluck(:created_at, :id)
                   .sample(200)

    keyset = cursors.map do |t, i|
      c = Cursor.encode(CursorRec.new(t, i))
      Benchmark.realtime { OrderPageQuery.new(status: status, cursor: c).call.records.to_a } * 1000
    end

    offsets = 200.times.map { rand(0..200_000) }
    offset_times = offsets.map do |off|
      Benchmark.realtime {
        Order.where(status: status).order(created_at: :desc)
             .limit(20).offset(off).to_a
      } * 1000
    end

    pct = ->(sorted, q) { sorted[(sorted.size * q).clamp(0, sorted.size - 1).to_i] }

    { "OFFSET" => offset_times, "Keyset" => keyset }.each do |name, times|
      s = times.sort
      puts format("%-8s p50=%7.2fms  p95=%7.2fms  p99=%7.2fms  max=%7.2fms",
                  name, pct.(s, 0.50), pct.(s, 0.95), pct.(s, 0.99), s.last)
    end
  end
end
