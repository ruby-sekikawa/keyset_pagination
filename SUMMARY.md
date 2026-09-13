# Keyset Pagination Lab — 要点まとめ

1000万行の `orders` に対し、フィルタ・ソート・ページネーションが効く API を **p95 < 100ms** で実装する課題の学習記録（要点版）。
詳細な予測・実測ログは [NOTES.md](./NOTES.md) を参照。

- 環境: PostgreSQL 16 (Docker) / Rails 8.1 / Ruby 3.4.9 (host)
- データ: orders 1000万行（574MB）、status 分布 paid60% / shipped20% / pending13% / cancelled6% / refunded1%

---

## 最終結果（完了の定義）

| 項目 | 結果 |
|---|---|
| p95 < 100ms | ✅ **Keyset p95 = 1.5〜6.3ms**（目標を余裕で達成） |
| OFFSET vs Keyset 分布 | OFFSET p99≈100ms・max最大6.5秒 / Keyset max≈16ms |
| index 3パターンの EXPLAIN | ✅ 記録済み |
| 重複・欠落テスト | ✅ green |

**一言で**: OFFSET を捨てて Keyset（カーソル方式）＋ 正しい複合インデックス `(status, created_at, id)` にすると、深いページでもコストが一定になり p95 が跳ねない。

---

## いちばん大事な結論：なぜ `(status, created_at, id)` なのか

**原則: 等値条件 → ソート/範囲条件 → 一意タイブレーク の順に並べる。**

1. **`status`（等値）を先頭に** → B-tree 内で `status = 1` の範囲が連続した1ブロックに集まり、**その中は既に `created_at` 順に並ぶ**。だから「その棚に直行して先頭から20件読むだけ」で済み、**`Sort` ノードが消える**。
2. **`created_at`（ソート/範囲）を2番目に** → 並び順とカーソルの範囲条件をインデックスだけで満たせる。
3. **`id`（一意）を末尾に** → `created_at` は重複しうる。一意な列を足さないと、同一時刻の行がページ境界にまたがったとき取りこぼす／重複する（keyset の必須要件）。

この列順のおかげで、**選択率に関係なく**（paid 60% でも refunded 1% でも）Buffers は約24枚で一定だった。

---

## フェーズ別の要点

### Phase 2: インデックス無しの地獄
- `WHERE status=1 ORDER BY created_at DESC LIMIT 20` が **全表スキャン（73,602ブロック）＋ 全ソート**。
- **OFFSET のコストはテーブル読込でなくソート量に出る**（Buffers は OFFSET によらず一定）。
- OFFSET が増えると `work_mem`(16MB) を超え、ソートがメモリ→**ディスク退避（external merge）**に落ちる断崖。

### Phase 3: インデックスの列順が命
- インデックスを張ると `Sort` が消え 314ms → **0.015ms**。
- ただし **paid(60%)・1ページ目では A/B/C の優劣が見えない**（楽な条件では悪い設計が紛れる）。
- **refunded(1%) で差が露呈**: `created_at` だけの index(A) は `Filter` 爆発（Buffers 2,527・捨て行2,498）。`status` を含む B/C は `Index Cond` で無駄ゼロ。
- **DESC は必須ではない**: 昇順 index でも `Index Scan Backward` で降順に使える。方向が混在するときだけ DESC 明示に意味がある。

### Phase 4: Keyset 実装
- **行値比較 `(created_at, id) < (?, ?)`** は `Index Cond: ROW(...)` に落ちる（Buffers 27）。
- **OR手書き** `created_at<? OR (created_at=? AND id<?)` は論理的に等価でも `Filter` になり **Buffers 10万超・4.6秒**（約3700倍遅い）。→ 今回一番実用的な知識。
- **カーソルが何ページ目でも Buffers 一定**（浅い27 ↔ 深い24）。OFFSET と違い先頭から数えない。
- **カーソル時刻は `iso8601(6)`（マイクロ秒）が生命線**。`to_s`（秒精度）に丸めると同一秒境界で重複爆発（テストで実証）。

### Phase 5: COUNT の壁
- 正確な `COUNT(*) WHERE status=1` は warm でも **138〜232ms**（選択率60%で index でなく Seq Scan 選択）。
- keyset 本体 0.02ms を、総件数表示の COUNT 1個が台無しにする。
- 3つの回避策: ①総件数を出さない(has_next) ②近似(EXPLAIN Plan Rows, 誤差0.01%) ③カウンタテーブル。
- **本当の学び**: 「正確な総件数が本当に必要か」をプロダクトと交渉するのが一番効く（唯一コードを書かない解法）。

### Phase 6: p95 で判断する
- OFFSET p50≈40ms / p95≈77ms / p99≈100ms、Keyset p50 1-5ms / **p95 1.5-6.3ms** / max≈16ms。
- **平均や p50 は嘘をつく**: p50 で9倍差、裾（p95/p99）では大きく開く。ユーザー体験を壊すのは裾。
- **p95/p99 の裾は「最初の1回」ではなく毎回**: 深い offset は uncached でも毎回70-80ms
  （`Index Scan` で N件を歩いて捨てる CPU コスト。Buffers 全hitでも遅い＝キャッシュで消えない）。
  一方 max の6.5秒は単発の外れ値。→ **max でなく p95 で判断する**理由そのもの。
- StackProf: keyset の数ms は **SQL実行が約10%だけ**、残りは Ruby(AR生成・GC)。「遅い＝SQLが悪い」とは限らない。

---

## EXPLAIN を3秒で診断するチェックリスト

1. `Seq Scan` が出てないか（大テーブルなら赤信号）
2. `Sort` が出てないか（index で消せる並べ替えコスト）
3. `Filter` + `Rows Removed by Filter` の数字（大きい＝読んで捨てる無駄＝列順を疑う）
4. `Index Cond` になっているか（なっていれば index に直行できている）
5. `Buffers: hit/read`（20件返すのに数千〜数万なら異常）

---

## 実装物（keyset_lab/）

| ファイル | 役割 |
|---|---|
| `app/models/order.rb` | scope `page_order` / `seek_after`（行値比較）、`approximate_count` |
| `app/queries/cursor.rb` | カーソル符号化（iso8601(6) + Base64、不透明化） |
| `app/queries/order_page_query.rb` | 1ページ取得（LIMIT+1 で has_next 判定、COUNT不要） |
| `app/controllers/api/orders_controller.rb` | `GET /api/orders?status=&cursor=` |
| `app/models/order_stat.rb` | カウンタテーブル（refresh_all / count_for） |
| `test/queries/order_page_query_test.rb` | 重複・欠落・順序・精度・壊れカーソルの検証 |
| `lib/tasks/seed_orders.rake` | 1000万行投入 |
| `lib/tasks/bench.rake` | OFFSET vs Keyset の p50/p95/p99 比較 |

---

## 計画書に対して見つけた補正点（実測で判明）

1. seed の `(random()*730 || ' days')::interval` は乱数極小時に指数表記でクラッシュ → `* interval '1 day'` に修正。
2. seed の `CASE` 内で `random()` を分岐ごとに呼び直し分布が崩壊 → 単一乱数を FROM 側で生成して修正。
3. 「Filter 爆発は B で起きる」想定 → 実際は **A（status 非包含）** で起きる（B は status を含むため Index Cond）。
4. COUNT は index-only scan でなく **Parallel Seq Scan** を選択（選択率が高すぎるため）。
5. `group(:status).count` は enum 名を返し、integer 列に upsert すると 0 衝突 → `Order.statuses` で整数化。

---

## 未対応（必要になれば）

- `idx_c` は生 SQL 作成のままで**マイグレーション未化**（テスト DB には無い）。本番運用・§9.4「安全なマイグレーション（`algorithm: :concurrently`）」をやるなら対応。
- Phase 7（可変フィルタ / JOIN 跨ぎソート / NULLABLE ソート列）は未着手。
- コールドキャッシュ・同時接続下（pgbench）での比較は未実施。
