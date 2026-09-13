# keyset pagination の練習問題

## 1. データを用意する

数千行では何も学べません。プランナが常にSeq Scanを選んで終わりです。

```sql
CREATE TABLE orders (
  id         bigserial PRIMARY KEY,
  user_id    bigint      NOT NULL,
  status     smallint    NOT NULL,
  total_cents integer    NOT NULL,
  created_at timestamptz NOT NULL
);

INSERT INTO orders (user_id, status, total_cents, created_at)
SELECT
  (random() * 200000)::bigint + 1,
  (random() * 4)::smallint,
  (random() * 100000)::int,
  now() - (random() * 730 || ' days')::interval
FROM generate_series(1, 10000000);

ANALYZE orders;
```

`ANALYZE` を忘れないでください。統計情報がないとプランナは当てずっぽうになります。

## 2. まず素朴に書いて、壊れるのを見る

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE status = 2
ORDER BY created_at DESC
LIMIT 20 OFFSET 100000;
```

インデックスなしの状態で走らせて、出力を保存してください。おそらく `Seq Scan` + `Sort`（あるいは `top-N heapsort`）で数秒かかります。

見るべき数字は3つです。

- **`actual rows` と `rows` の乖離** — 推定と実測がずれていたら統計かプラン選択の問題
- **`Buffers: shared hit=... read=...`** — 20行返すのに何ページ触ったか。ここが本質的なコスト
- **`Rows Removed by Filter`** — 読んだのに捨てた行数。無駄仕事の量そのもの

「1.2秒かかった」より「20行返すのに8万ブロック読んだ」の方が情報量が多い。この見方に切り替えるのが今回の裏テーマです。

## 3. なぜ OFFSET が破綻するのか

理由は2つあり、**2つ目の方が実は厄介**です。

**理由1: コストが O(offset + limit)**
DBは飛ばす10万行を実際に読んで捨てます。飛ばすためのショートカットは存在しません。1ページ目は速く、500ページ目は死ぬ。しかも遅いページほどアクセス頻度が低いので、開発中は気づかない。

**理由2: 結果が壊れる**
ページ1を表示している間に新しい行が1件INSERTされると、全体が1つずれてページ2の先頭がページ1の末尾と重複します。DELETEなら逆に1件飛ぶ。無限スクロールで「同じ投稿が2回出る」不具合の正体はほぼこれです。パフォーマンス以前に**仕様として間違っている**。

## 4. インデックス設計

```sql
CREATE INDEX idx_orders_status_created_id
  ON orders (status, created_at DESC, id DESC);
```

列順の原則は **等値条件 → ソート/範囲条件** です。

`status` を先頭に置くと、B-treeの中で `status = 2` の範囲が連続した1ブロックになり、**その中がすでに `created_at` 順に並んでいます**。だからDBは先頭から必要な件数だけ読んで即座に止められる。Sortノードが消えるのがポイントです。

逆に `(created_at, status)` にすると、順序は得られますが status 条件は読みながら弾くしかない。status=2 が全体の20%なら、20行返すのに約100行読む。悪くはないが、選択率が1%なら2000行読むことになります。

**PostgreSQL特有の注意**: B-treeは逆順スキャンができるので、実は `(status, created_at, id)` と DESC 指定なしでも `ORDER BY created_at DESC` に使えます。DESCを明示する意味が出るのは **ソート方向が混在するとき**（`ORDER BY a ASC, b DESC` など）だけです。ここは誤解している人が多い部分。

**カーディナリティの罠**: status=2 が全体の80%を占めるなら、このインデックスは「絞り込み」としてはほぼ無意味です。それでも**ソートを消す**役には立つので価値はあります。インデックスの効用は絞り込みだけではない、という感覚を持っておくと判断が変わります。

## 5. Keyset Pagination（seek method）

「N件飛ばす」のをやめて「**この値より後ろ**」に変えます。

```sql
SELECT * FROM orders
WHERE status = 2
  AND (created_at, id) < ('2024-11-03 08:12:44.123456+00', 8172635)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

`(created_at, id) < (?, ?)` は**行値比較**で、PostgreSQLはこれを複合インデックスの検索条件に落とせます。「created_atが小さい、または等しくてidが小さい」を手書きのORで書くとインデックスが効かなくなるので、必ず行値比較で書いてください。ここが一番の実装ポイントです。

**なぜ `id` が要るのか**: `created_at` は一意ではありません。同じタイムスタンプの行がページ境界にまたがると、そこで取りこぼしか重複が起きます。ソートキーの末尾には必ず一意な列を足す。これは keyset の必須要件です。

期待されるプランはこうなります。

```
Limit  (actual rows=20 loops=1)
  ->  Index Scan using idx_orders_status_created_id on orders
        Index Cond: ((status = 2) AND (ROW(created_at, id) < ROW(...)))
        Buffers: shared hit=24
```

**Sortノードが無い**、`actual rows` が20前後、Buffersが数十。これが合格の形です。100万ページ目でも1ページ目と同じコストになります。

トレードオフも正直に押さえておいてください。任意のページへのジャンプができない（「500ページ目」が作れない）。無限スクロールやAPIとは相性が良く、ページ番号UIとは相性が悪い。

## 6. COUNT の壁

実は多くの場合、ここが最後に残るボトルネックです。

```sql
SELECT COUNT(*) FROM orders WHERE status = 2;  -- 200万行を数える
```

一致行が200万件あれば、数えるだけでインデックス全走査になり、それだけで100msを超えます。クエリ本体を1msにしても、画面に「全2,041,882件」を出した瞬間に台無し。

現実的な選択肢は3つです。

1. **総件数を出さない** — 無限スクロール、または `LIMIT 21` して21件目の有無で「次あり」を判定する
2. **近似値で妥協** — `EXPLAIN` の推定行数や `pg_class.reltuples` を使い、「約200万件」と表示する。Googleの検索結果と同じ発想
3. **カウンタを別に持つ** — 集計テーブルや非同期更新。整合性のコストを払う

「正確な総件数が本当に必要か」をプロダクト側と交渉するのが、実は一番効くエンジニアリングです。技術で殴らず要件を削る、という判断の練習にもなります。

## 7. Rails 実装

```ruby
class Order < ApplicationRecord
  scope :seek_after, ->(created_at, id) {
    where("(orders.created_at, orders.id) < (?, ?)", created_at, id)
  }
end

scope = Order.where(status: :paid)
             .order(created_at: :desc, id: :desc)
             .limit(21)
scope = scope.seek_after(cursor[:created_at], cursor[:id]) if cursor

rows      = scope.to_a
has_next  = rows.size > 20
rows      = rows.first(20)
next_cursor = has_next ? encode_cursor(rows.last) : nil
```

**踏みやすい地雷が1つ**あります。カーソルのシリアライズです。

```ruby
# NG: 秒精度に丸まる → 同秒の行を取りこぼす／重複する
time.to_s

# OK: マイクロ秒まで保持する
time.iso8601(6)
```

PostgreSQLのtimestampはマイクロ秒精度です。JSONやURLに載せる過程で丸めると、境界で確実にバグります。カーソルはBase64で不透明にしておくと、クライアントに内部構造を触らせずに済むのでおすすめです。

## 8. p95 を実際に測る

ここを飛ばさないでください。**1ページ目だけ測っても意味がありません**。

```ruby
require 'benchmark'
cursors = Order.where(status: 2).order(created_at: :desc)
               .limit(500).offset(0).pluck(:created_at, :id).sample(200)

times = cursors.map { |c| Benchmark.realtime { fetch_page(c) } * 1000 }
sorted = times.sort
puts "p50: #{sorted[sorted.size * 0.50]}ms"
puts "p95: #{sorted[sorted.size * 0.95]}ms"
puts "p99: #{sorted[sorted.size * 0.99]}ms"
```

散らばったカーソルで叩いて分布を見る。OFFSET版と keyset版で同じ測定をして、**p50はさほど変わらないのにp95/p99が桁違い**になるのを目で確認してください。平均値を見ていたら見逃す差です。ここで「平均は嘘をつく」が腹落ちします。

もう一段リアルにするなら、`pgbench` で同時接続20くらいの負荷をかけながら測る。バッファキャッシュが効かなくなって数字が変わります。

## 9. 発展課題

ここまでできたら、次の3つが実務で本当に難しい部分です。

- **可変フィルタ**: ユーザーが6つの条件を任意に組み合わせられるとき、全組み合わせにインデックスは張れません。どれを張り、どれを諦めるか。PostgreSQLのbitmap index scanで複数インデックスを合成できる条件は何か
- **JOINを跨ぐソート**: `users` をJOINして `users.name` でソートしたい。インデックスは1テーブル内でしか順序を保証しません。どう設計するか
- **NULLABLEなソート列**: `NULLS LAST` が入ると行値比較が使えなくなります。回避策は

---

まずは3節までを実際に手で走らせて、EXPLAINの出力を見るのが最初の一歩です。実行結果を貼ってもらえれば一緒に読み解けますし、どこか特定の節を先に掘り下げても構いません。
