# 実装計画書: 1000万行に対する高速ページネーションAPI

## 0. この課題の目的

**表向きのゴール**: 1000万行の `orders` テーブルに対し、フィルタ・ソート・ページネーションが効くAPIを **p95 < 100ms** で実装する。

**本当のゴール**: 以下の4つを「読んで知っている」から「手が覚えている」に変える。

1. EXPLAIN を読んで、プランナの判断を説明できる
2. 複合インデックスの列順を、理由を持って決められる
3. 計測してから最適化する規律を身につける
4. p50 ではなく p95/p99 で判断する癖をつける

**最重要ルール**: 各フェーズで **計測する前に必ず予測を紙に書く**。予測と実測のズレが学習そのものです。ここを飛ばすと、ただの写経になります。

---

## 1. 前提環境

| 項目 | 推奨 |
|---|---|
| Ruby | 3.2+ |
| Rails | 7.1+ (`relation.explain(:analyze, :buffers)` が使えるため) |
| PostgreSQL | 14+ |
| 空きディスク | 5GB以上（テーブル+インデックスで約1.5GB、作業領域込み） |
| 所要時間 | 全フェーズで実働8〜12時間程度 |

Dockerを使う場合、PostgreSQLコンテナのメモリ制限に注意してください。デフォルト設定のままだと `shared_buffers` が小さすぎて、キャッシュ挙動の観察がしづらくなります。

### 1.1 セットアップ

```bash
rails new keyset_lab --database=postgresql --skip-action-mailbox --skip-action-text --skip-active-storage
cd keyset_lab
bin/rails db:create
```

`Gemfile` に計測系を追加します。

```ruby
group :development do
  gem "benchmark-ips"
  gem "stackprof"
  gem "strong_migrations"
end
```

### 1.2 PostgreSQL側の準備

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
```

`postgresql.conf` で以下を確認（開発機なら手を入れて構いません）。

```
shared_buffers = 1GB          # デフォルト128MBだと観察しづらい
work_mem = 16MB               # 小さいとSortが即ディスクに落ちる
track_io_timing = on          # EXPLAIN で I/O time が出るようになる
```

`track_io_timing` は地味ですが効きます。ディスクI/Oに何ms使ったかが EXPLAIN に表示されるようになり、「遅いのはCPUかI/Oか」が一目で分かります。

---

## 2. Phase 0: スキーマ定義

**所要**: 30分

```bash
bin/rails g model Order user_id:bigint status:integer total_cents:integer created_at:datetime
```

マイグレーションを手で整えます。

```ruby
class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.bigint     :user_id,     null: false
      t.integer    :status,      null: false, limit: 2
      t.integer    :total_cents, null: false
      t.datetime   :created_at,  null: false
    end
  end
end
```

**この時点ではインデックスを一切張らないでください。** Phase 2 でインデックスなしの地獄を体験することが目的です。

モデル:

```ruby
class Order < ApplicationRecord
  enum :status, { pending: 0, paid: 1, shipped: 2, cancelled: 3, refunded: 4 }
end
```

### チェックポイント

- [ ] `bin/rails db:migrate` が通る
- [ ] `\d orders` で PRIMARY KEY 以外にインデックスが無いことを確認した

---

## 3. Phase 1: 1000万行の投入

**所要**: 1〜2時間（うち待ち時間が大半）

### 3.1 なぜ1000万行なのか

数千行だとプランナは常に Seq Scan を選びます。テーブル全体がメモリに乗り、インデックスを使う方が遅いからです。**インデックスの効果は行数がないと観察できません**。これが「ローカルでは速いのに本番で落ちる」の正体でもあります。

### 3.2 投入スクリプト

一度に1000万行 INSERT すると WAL が膨れて遅くなるので、100万行 × 10回に分けます。

```ruby
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
          (CASE
             WHEN random() < 0.60 THEN 1   -- paid が60%（高カーディナリティ側）
             WHEN random() < 0.80 THEN 2
             WHEN random() < 0.93 THEN 0
             WHEN random() < 0.99 THEN 3
             ELSE 4                        -- refunded は1%（低選択率側）
           END)::smallint,
          (random() * 100000)::int,
          now() - (random() * 730 || ' days')::interval
        FROM generate_series(1, #{chunk});
      SQL
      puts "chunk #{i + 1}/#{total / chunk} done (#{(Time.now - t).round(1)}s)"
    end

    puts "ANALYZE..."
    conn.execute("ANALYZE orders;")
  end
end
```

**status の分布を意図的に偏らせている**のがポイントです。`paid` が60%、`refunded` が1%。同じインデックスでも選択率によって効果が全く違うことを、後のフェーズで比較するための仕込みです。

```bash
bin/rails lab:seed_orders
```

### 3.3 ANALYZE を絶対に忘れない

統計情報がないとプランナは当てずっぽうで動きます。「なぜか変なプランを選ぶ」の8割はこれです。

```sql
SELECT relname, n_live_tup, last_analyze
FROM pg_stat_user_tables WHERE relname = 'orders';
```

### チェックポイント

- [ ] `SELECT count(*) FROM orders;` が 10,000,000（この count 自体が何秒かかったかメモしておく — Phase 5 の伏線です）
- [ ] `SELECT status, count(*) FROM orders GROUP BY status;` で分布を確認
- [ ] `\dt+ orders` でテーブルサイズを確認（600MB前後のはず）
- [ ] `last_analyze` に時刻が入っている

---

## 4. Phase 2: ベースライン計測（インデックスなし）

**所要**: 1時間

ここが計画書の中で**一番重要なフェーズ**です。急いで通り過ぎないでください。

### 4.1 予測を先に書く

計測前に、以下をノートに書いてください。

```
Q1. status='paid' (600万件) で絞って created_at DESC で20件取るのに何ms?
    予測: ____ ms

Q2. OFFSET 0 と OFFSET 100000 で速度は何倍違う?
    予測: ____ 倍

Q3. 20行返すために、DBは何行読む?
    予測: ____ 行
```

### 4.2 計測

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE status = 1
ORDER BY created_at DESC
LIMIT 20 OFFSET 0;
```

同じクエリで `OFFSET 100000`、`OFFSET 1000000` も実行します。

### 4.3 出力の読み方

見るべき数字は3つだけです。

| 項目 | 意味 | 危険信号 |
|---|---|---|
| `rows` vs `actual rows` | 推定と実測の乖離 | 10倍以上ずれていたら統計かプラン選択の問題 |
| `Buffers: shared hit/read` | 触ったページ数（1ページ=8KB） | 20行返すのに数万ブロックなら異常 |
| `Rows Removed by Filter` | 読んで捨てた行数 | ここが大きい = 無駄仕事 |

`hit` はキャッシュヒット、`read` はディスクから読んだページです。2回連続で実行すると `read` が `hit` に変わるはずで、これがバッファキャッシュの効果です。

**時間ではなくブロック数で考える癖をつけてください。** 「1.2秒かかった」より「20行返すのに8万ブロック読んだ」の方が、マシンが変わっても通用する情報です。

### 4.4 記録テンプレート

| OFFSET | 実行時間 | Buffers (hit/read) | actual rows | Sortの有無 |
|---|---|---|---|---|
| 0 | | | | |
| 100,000 | | | | |
| 1,000,000 | | | | |

### チェックポイント

- [ ] 予測と実測のズレを記録した
- [ ] OFFSET が増えるとコストが線形に増えることを数字で確認した
- [ ] `Sort` または `top-N heapsort` ノードが存在することを確認した

---

## 5. Phase 3: インデックス設計の比較実験

**所要**: 2時間

### 5.1 3パターンを実際に張って比べる

いきなり正解を張らず、**間違ったものも張って挙動を見てください**。これが一番身につきます。

```sql
-- パターンA: ソート列のみ
CREATE INDEX idx_a ON orders (created_at DESC);

-- パターンB: 列順が逆
CREATE INDEX idx_b ON orders (created_at DESC, status);

-- パターンC: 正解
CREATE INDEX idx_c ON orders (status, created_at DESC, id DESC);
```

1つ張るごとに他を `DROP` し、Phase 2 と同じクエリを流して記録します。

```sql
-- 特定のインデックスだけを試す
DROP INDEX IF EXISTS idx_a, idx_b, idx_c;
CREATE INDEX idx_c ON orders (status, created_at DESC, id DESC);
ANALYZE orders;
```

| パターン | 実行時間 | Buffers | Sortノード | Rows Removed by Filter |
|---|---|---|---|---|
| なし | | | | |
| A `(created_at)` | | | | |
| B `(created_at, status)` | | | | |
| C `(status, created_at, id)` | | | | |

### 5.2 なぜ C が正解なのか

**原則: 等値条件 → ソート/範囲条件 の順**

`status` を先頭に置くと、B-tree の中で `status = 1` の範囲が連続した1ブロックになり、**その中がすでに `created_at` 順に並んでいます**。だからDBは先頭から必要な件数だけ読んで即座に止められる。`Sort` ノードが消えるのがこの設計の本質です。

B のように `created_at` を先頭にすると、順序は得られますが `status` は読みながら弾くしかありません。`paid` が60%なら20行返すのに約33行読む（許容範囲）。しかし `refunded`(1%) で同じクエリを投げると **2000行読むことになります**。ここを必ず実験してください:

```sql
-- パターンB のまま、選択率1%の条件で実行する
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE status = 4 ORDER BY created_at DESC LIMIT 20;
```

`Rows Removed by Filter` が跳ね上がるはずです。**同じインデックスでも、データ分布が変われば評価が反転する** — これが実務で最も再現しづらいバグの温床です。

### 5.3 DESC 指定は必要か（よくある誤解）

PostgreSQL の B-tree は**逆順スキャンができます**。つまり `(status, created_at, id)` と DESC なしで作っても、`ORDER BY created_at DESC, id DESC` に使えます。

DESC を明示する意味が出るのは **ソート方向が混在するとき**だけです。

```sql
-- これは (status, created_at DESC, id ASC) が必要
ORDER BY created_at DESC, id ASC
```

両方作って `EXPLAIN` で確認してみてください。「DESCを付けないとDESCソートに使えない」と思い込んでいる人は非常に多いです。

### 5.4 プランナを騙して比較する

インデックスを張っても使われないとき、強制的に比較できます。

```sql
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
RESET enable_seqscan;
```

これで「プランナが Seq Scan を選んだのは正しかったのか」を検証できます。**本番で使う設定ではなく、あくまで学習・調査用**です。

### チェックポイント

- [ ] 3パターンすべての EXPLAIN を記録した
- [ ] パターンC で `Sort` ノードが消えたことを確認した
- [ ] 選択率60%と1%で、パターンBの評価が変わることを数字で確認した
- [ ] `pg_size_pretty(pg_relation_size('idx_c'))` でインデックスサイズを確認した（書き込みコストの目安）

---

## 6. Phase 4: Keyset Pagination の実装

**所要**: 2〜3時間

### 6.1 SQLレベルで先に成立させる

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE status = 1
  AND (created_at, id) < ('2024-11-03 08:12:44.123456+00', 8172635)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

`(created_at, id) < (?, ?)` は**行値比較 (row value comparison)** で、PostgreSQL はこれを複合インデックスの検索条件（`Index Cond`）に落とせます。

**手書きORでは絶対に書かないでください:**

```sql
-- NG: Index Cond に落ちず、Filter になる
WHERE created_at < ? OR (created_at = ? AND id < ?)
```

論理的には等価ですが、プランナはこれをインデックス検索条件として使えません。両方 EXPLAIN して `Index Cond` と `Filter` の違いを目で見てください。**この差が今回の課題で一番実用的な知識**です。

### 6.2 なぜ id が必要か

`created_at` は一意ではありません。同一タイムスタンプの行がページ境界にまたがると、そこで取りこぼしか重複が発生します。**ソートキーの末尾には必ず一意な列を足す** — keyset の必須要件です。

意図的に壊して確認しておくと理解が定着します:

```sql
-- 同じ created_at を持つ行を大量に作る
UPDATE orders SET created_at = '2024-06-01 00:00:00+00'
WHERE id BETWEEN 1000000 AND 1000500;
```

この状態で `id` なしのカーソル（`created_at` のみ）でページを繰ると、行が飛ぶか重複します。実際に再現させてから元に戻してください。

### 6.3 目標とするプラン

```
Limit  (actual rows=20 loops=1)
  ->  Index Scan using idx_c on orders
        Index Cond: ((status = 1) AND (ROW(created_at, id) < ROW(...)))
        Buffers: shared hit=24
```

**合格条件**: `Sort` ノードが無い / `actual rows` が20前後 / Buffers が数十。カーソルが何ページ目を指していてもこの数字が変わらないことを確認してください。

### 6.4 Rails 実装

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  enum :status, { pending: 0, paid: 1, shipped: 2, cancelled: 3, refunded: 4 }

  scope :seek_after, ->(created_at, id) {
    where("(orders.created_at, orders.id) < (?, ?)", created_at, id)
  }
end
```

```ruby
# app/queries/order_page_query.rb
class OrderPageQuery
  PER_PAGE = 20

  Result = Struct.new(:records, :next_cursor, keyword_init: true)

  def initialize(status:, cursor: nil, per_page: PER_PAGE)
    @status, @cursor, @per_page = status, cursor, per_page
  end

  def call
    scope = Order.where(status: @status)
                 .order(created_at: :desc, id: :desc)
                 .limit(@per_page + 1)          # +1 で「次があるか」を判定
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
```

### 6.5 カーソルのシリアライズ（最大の地雷）

```ruby
# app/queries/cursor.rb
class Cursor
  def self.encode(record)
    payload = { t: record.created_at.iso8601(6), i: record.id }
    Base64.urlsafe_encode64(payload.to_json, padding: false)
  end

  def self.decode(str)
    return nil if str.blank?
    data = JSON.parse(Base64.urlsafe_decode64(str))
    { created_at: Time.iso8601(data["t"]), id: data["i"].to_i }
  rescue ArgumentError, JSON::ParserError
    nil   # 壊れたカーソルは1ページ目扱いにする
  end
end
```

**`iso8601(6)` の 6 が生命線です。**

```ruby
time.to_s        # => "2024-11-03 08:12:44 UTC"  秒に丸まる → 境界でバグる
time.iso8601     # => "2024-11-03T08:12:44Z"     同上
time.iso8601(6)  # => "2024-11-03T08:12:44.123456Z"  正しい
```

PostgreSQL の `timestamptz` はマイクロ秒精度です。JSON や URL に載せる過程で丸めると、**同一秒内に複数行があるページ境界で確実に取りこぼします**。しかもテストデータが少ないと再現しないので、本番でだけ起きるタイプのバグになります。

Base64 で包む理由は、クライアントに内部構造を触らせないためです。カーソルを不透明にしておけば、後からソートキーを変えてもAPI互換性を壊しません。

### 6.6 Controller

```ruby
class Api::OrdersController < ApplicationController
  def index
    result = OrderPageQuery.new(
      status: params[:status] || "paid",
      cursor: params[:cursor]
    ).call

    render json: {
      data: result.records.as_json(only: %i[id user_id status total_cents created_at]),
      next_cursor: result.next_cursor
    }
  end
end
```

### 6.7 正しさのテスト

パフォーマンス以前に、**取りこぼし・重複がないこと**を検証します。

```ruby
# test/queries/order_page_query_test.rb
test "全ページを繰って重複も欠落もない" do
  seen, cursor = [], nil
  50.times do
    r = OrderPageQuery.new(status: "refunded", cursor: cursor).call
    seen.concat(r.records.map(&:id))
    cursor = r.next_cursor
    break if cursor.nil?
  end

  assert_equal seen.uniq.size, seen.size, "重複あり"

  expected = Order.where(status: "refunded")
                  .order(created_at: :desc, id: :desc)
                  .limit(seen.size).pluck(:id)
  assert_equal expected, seen, "順序または欠落の問題"
end
```

余力があれば、**ページ送りの途中で INSERT を挟むテスト**も書いてください。OFFSET 版では落ち、keyset 版では通ります。これが「OFFSET はパフォーマンス以前に仕様として壊れている」の証明になります。

### チェックポイント

- [ ] `Index Cond` に `ROW(...)` が含まれている（`Filter` ではない）
- [ ] OR 手書き版との EXPLAIN 差分を記録した
- [ ] カーソルが何ページ目でも Buffers がほぼ一定
- [ ] 重複・欠落テストが通る
- [ ] `iso8601(6)` を `to_s` に変えるとテストが落ちることを確認した

---

## 7. Phase 5: COUNT の壁

**所要**: 1時間

ここが最後に残るボトルネックです。クエリ本体を1msにしても、画面に「全6,001,204件」を出した瞬間に台無しになります。

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM orders WHERE status = 1;
```

600万件を数えるだけでインデックス全走査になり、それ単体で100msを超えるはずです。Phase 1 でメモした `count(*)` の時間と突き合わせてください。

### 選択肢を3つとも実装してみる

**1. 総件数を出さない（推奨）**

`LIMIT 21` して21件目の有無で「次あり」を判定する。Phase 4 で既に実装済みです。無限スクロールUIならこれで十分。

**2. 近似値で妥協**

```ruby
def self.approximate_count(status)
  sql = Order.where(status: status).to_sql
  row = connection.select_one("EXPLAIN (FORMAT JSON) #{sql}")
  JSON.parse(row["QUERY PLAN"]).dig(0, "Plan", "Plan Rows")
end
```

プランナの推定行数を使います。Google の検索結果が「約1,230,000件」と出すのと同じ発想。`ANALYZE` の頻度に精度が依存する点は理解しておいてください。

**3. カウンタテーブル**

```ruby
# 集計テーブル + 定期更新 or トリガ
class OrderStat < ApplicationRecord  # status, count
end
```

正確ですが、整合性・更新競合・リアルタイム性のコストを払います。

### この節の本当の学び

「正確な総件数が本当に必要か」を**プロダクト側と交渉する**のが、実は一番効くエンジニアリングです。技術で殴らずに要件を削る判断 — この課題で唯一コードを書かない解法があることを覚えておいてください。

### チェックポイント

- [ ] COUNT 単体の実行時間を計測した
- [ ] 3つの選択肢のトレードオフを自分の言葉で説明できる

---

## 8. Phase 6: p95 の計測と比較

**所要**: 1〜2時間

**1ページ目だけ測っても意味がありません。** 散らばったカーソルで叩いて分布を見ます。

```ruby
# lib/tasks/bench.rake
namespace :lab do
  desc "OFFSET vs Keyset の分布比較"
  task bench: :environment do
    status = "paid"

    # 現実的なカーソル群をサンプリング
    cursors = Order.where(status: status)
                   .order(created_at: :desc, id: :desc)
                   .limit(200_000)
                   .pluck(:created_at, :id)
                   .sample(200)

    keyset = cursors.map do |t, i|
      c = Cursor.encode(OpenStruct.new(created_at: t, id: i))
      Benchmark.realtime { OrderPageQuery.new(status: status, cursor: c).call.records.to_a } * 1000
    end

    offsets = 200.times.map { rand(0..200_000) }
    offset_times = offsets.map do |off|
      Benchmark.realtime {
        Order.where(status: status).order(created_at: :desc)
             .limit(20).offset(off).to_a
      } * 1000
    end

    { "OFFSET" => offset_times, "Keyset" => keyset }.each do |name, times|
      s = times.sort
      puts format("%-8s p50=%6.1fms  p95=%6.1fms  p99=%6.1fms  max=%6.1fms",
                  name, s[s.size * 0.50], s[s.size * 0.95], s[s.size * 0.99], s.last)
    end
  end
end
```

### 何を見るか

**p50 はさほど変わらないのに p95/p99 が桁違い**になるはずです。平均値だけ見ていたら見逃す差であり、これが「平均は嘘をつく」の実物です。

さらにリアルにするなら:

```bash
# 同時接続をかけながら測る（バッファキャッシュが効かなくなる）
pgbench -c 20 -j 4 -T 60 -f bench.sql keyset_lab_development
```

キャッシュを落とした状態（コールドキャッシュ）での比較もやってみてください。差がさらに開きます。

### アプリ層のプロファイル

DBが1msでも、Railsのシリアライズが遅ければ意味がありません。

```ruby
StackProf.run(mode: :wall, out: "tmp/stackprof.dump", raw: true) do
  200.times { OrderPageQuery.new(status: "paid").call.records.map(&:attributes) }
end
```

```bash
stackprof tmp/stackprof.dump --text --limit 20
```

`as_json` や ActiveRecord のオブジェクト生成が上位に来ることが多いはずです。**「遅い＝SQLが悪い」とは限らない**ことを、ここで一度体験しておいてください。

### チェックポイント

- [ ] OFFSET と Keyset の p50/p95/p99 を表にした
- [ ] 目標の p95 < 100ms を達成した
- [ ] StackProf でアプリ層の内訳を確認した

---

## 9. Phase 7: 発展課題

ここから先が実務で本当に難しい部分です。時間があれば。

### 9.1 可変フィルタ

ユーザーが `status` / `user_id` / `total_cents` 範囲 / 期間 を任意に組み合わせられるとき、全組み合わせにインデックスは張れません。

- どの組み合わせが実際に使われるか（`pg_stat_statements` で実測する）
- PostgreSQL の **Bitmap Index Scan** で複数インデックスを合成できる条件は何か
- 「張らない」判断をどう正当化するか

### 9.2 JOIN を跨ぐソート

`users` を JOIN して `users.name` でソートしたい。インデックスは1テーブル内でしか順序を保証しません。

- 非正規化（`orders.user_name` を持つ）のコストと利点
- MATERIALIZED VIEW という選択肢

### 9.3 NULLABLE なソート列

`ORDER BY shipped_at DESC NULLS LAST` が入ると行値比較が使えません。

- 部分インデックス（`WHERE shipped_at IS NOT NULL`）で分割する
- `COALESCE` した式インデックス

### 9.4 安全なマイグレーション

1000万行のテーブルにインデックスを追加する = 本番なら書き込みが止まります。

```ruby
class AddIndexToOrders < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :orders, [:status, :created_at, :id], algorithm: :concurrently
  end
end
```

`disable_ddl_transaction!` を外すとどうなるか、`strong_migrations` がどんな警告を出すか、実際に試してください。

---

## 10. 進捗管理

| Phase | 内容 | 目安 | 完了 |
|---|---|---|---|
| 0 | スキーマ定義 | 30分 | ☐ |
| 1 | 1000万行投入 | 1-2h | ☐ |
| 2 | ベースライン計測 | 1h | ☐ |
| 3 | インデックス比較実験 | 2h | ☐ |
| 4 | Keyset実装 | 2-3h | ☐ |
| 5 | COUNT問題 | 1h | ☐ |
| 6 | p95計測 | 1-2h | ☐ |
| 7 | 発展 | 任意 | ☐ |

### 予測と実測の記録シート

各フェーズでこれを埋めてください。**このシートが成果物です。**

```
日付:
Phase:
やろうとしたこと:

計測前の予測:
  -

実測結果:
  -

ズレた点と、その理由:
  -

次に確かめたいこと:
  -
```

---

## 11. つまずきやすい箇所

| 症状 | 原因 | 対処 |
|---|---|---|
| インデックスを張ったのに使われない | `ANALYZE` していない | `ANALYZE orders;` |
| 同上 | 選択率が高すぎてSeq Scanが正解 | `SET enable_seqscan=off` で比較して納得する |
| 2回目の実行が急に速い | バッファキャッシュ | 比較は必ず複数回実行して2回目以降で |
| Keyset で行が飛ぶ | カーソルの時刻精度 | `iso8601(6)` を使う |
| `Index Cond` でなく `Filter` になる | OR で手書きしている | 行値比較 `(a,b) < (?,?)` に直す |
| Sort が消えない | 列順が違う / ソート方向が混在 | 等値条件を先頭に。混在時はインデックス側もDESC指定 |
| Rails の `explain` が素っ気ない | Rails 7.0以前 | `connection.execute("EXPLAIN (ANALYZE, BUFFERS) ...")` |

---

## 12. 完了の定義

- [ ] p95 < 100ms を達成し、数字で示せる
- [ ] OFFSET と Keyset の分布比較表がある
- [ ] インデックス3パターンの EXPLAIN 記録がある
- [ ] 重複・欠落テストが通っている
- [ ] **「なぜ `(status, created_at, id)` なのか」を、B-treeの構造から他人に説明できる**

最後の項目が本命です。ここまで到達すれば、この課題の目的は達成されています。
