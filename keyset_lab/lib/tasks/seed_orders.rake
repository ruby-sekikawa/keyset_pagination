# lib/tasks/seed_orders.rake
namespace :lab do
  desc "Insert 10M rows into orders"
  task seed_orders: :environment do
    conn = ActiveRecord::Base.connection
    total, chunk = 10_000_000, 1_000_000

    (total / chunk).times do |i|
      t = Time.now
      conn.execute(<<~SQL)
        INSERT INTO orders (user_id, status, total_cents, created_at)
        SELECT
          (random() * 200000)::bigint + 1,
          -- status の分布は「1行につき1つの乱数 r」に対する累積しきい値で決める。
          -- 計画書のように各 WHEN で random() を呼ぶと分岐ごとに振り直しになり、
          -- 閾値が累積として働かず分布が壊れる（refunded が 1% でなく ~0.006% になる）。
          -- そこで r を FROM 側で1回だけ生成して固定する。
          (CASE
             WHEN r < 0.60 THEN 1   -- paid     60%（高カーディナリティ側）
             WHEN r < 0.80 THEN 2   -- shipped  20%
             WHEN r < 0.93 THEN 0   -- pending  13%
             WHEN r < 0.99 THEN 3   -- cancelled 6%
             ELSE 4                 -- refunded  1%（低選択率側）
           END)::smallint,
          (random() * 100000)::int,
          -- 計画書の `(random()*730 || ' days')::interval` は random が極小のとき
          -- 指数表記(例 6.76e-05)で文字列化され interval 構文エラーになるため、
          -- 文字列連結をやめて interval を直接掛ける形に修正（意図は同じ: 0〜730日のオフセット）。
          now() - (random() * 730) * interval '1 day'
        FROM (SELECT random() AS r FROM generate_series(1, #{chunk})) s;
      SQL
      puts "chunk #{i + 1}/#{total / chunk} done (#{(Time.now - t).round(1)}s)"
    end

    puts "ANALYZE..."
    conn.execute("ANALYZE orders;")
  end
end
