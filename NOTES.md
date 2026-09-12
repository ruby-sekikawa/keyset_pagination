# Keyset Pagination Lab — 実測ノート

> このノートが成果物です（計画書 §10）。各フェーズで「予測 → 実測 → ズレと理由」を必ず埋める。
> 時間ではなく **ブロック数(Buffers)** で考える癖をつける（計画書 §4.3）。

- 環境: PostgreSQL 16 (Docker) / Rails 8.1 / Ruby 3.3 (host)
- DB接続: `localhost:5433` user=keyset db=keyset_lab_development
- psql に入る: `docker compose exec db psql -U keyset -d keyset_lab_development`

---

## 進捗

| Phase | 内容 | 状態 |
|---|---|---|
| 0 | スキーマ定義 | ✅完了 |
| 1 | 1000万行投入 | ✅完了 |
| 2 | ベースライン計測 | ✅完了 |
| 3 | インデックス比較実験 | ✅完了 |
| 4 | Keyset実装 | ✅完了 |
| 5 | COUNT問題 | ✅完了 |
| 6 | p95計測 | 未 |
| 7 | 発展 | 未 |

---

## Phase 0: スキーマ定義  ✅ 完了

やろうとしたこと:
- インデックスを一切張らずに orders テーブルを作る（Phase 2 で「インデックスなしの地獄」を体験するため）

実測結果:
- `db:migrate` 成功（CreateOrders, 0.0153s）
- `\d orders`: インデックスは `orders_pkey` (PRIMARY KEY, btree(id)) のみ。PK以外なし ✅
- カラム型: id=bigint, user_id=bigint, status=smallint(limit:2), total_cents=integer, created_at=timestamp(6) without time zone, いずれも NOT NULL

補足メモ:
- created_at は `timestamp(6) without time zone`（Rails既定）。計画書§6.5は timestamptz を想定するが、
  マイクロ秒精度(6桁)は保持されるため keyset の精度要件は満たす。TZは Rails/DB とも UTC で統一済み。
  Phase 4 の iso8601(6) 検証で改めて確認する。
- 環境: Ruby は Rails 8.1 の構文要件に合わせ 3.4.9 に変更（3.3.0 では actionview が SyntaxError）。

---

## Phase 1: 1000万行の投入

計測前の予測（Claude の予測 / ユーザーも自分の予測を書いてOK）:
- chunk 1回(100万行)あたりの投入時間: 2〜5 秒（generate_series + 単純INSERT、WALはmax_wal_size=4GBで緩和）
- テーブルサイズ: 約600MB（計画書の見積り通り。1行あたり~50B想定）
- `SELECT count(*)` の所要時間: 0.3〜1.0 秒（全行スキャン必要、キャッシュに乗れば速い）← Phase 5 の伏線

実測結果:
- 投入: 100万行 × 10チャンク、各 1.2〜1.6 秒（予測 2〜5秒 → 予測より速い）
- テーブルのみ 574MB / インデックス込み 789MB（予測 約600MB → ほぼ的中）
- `count(*)`: 1回目 **580ms**（コールド寄り）→ 2回目 **121ms**（キャッシュ温）。← Phase 5 の伏線。
  「2回目が速い」＝バッファキャッシュ効果を早速観測。
- last_analyze: 2026-08-22 07:36:18 UTC（入っている ✅）

status 分布（重大な発見あり）:
| status | 実測件数 | 実測% | 計画書の意図% |
|---|---|---|---|
| 1 paid | 5,999,498 | 60.0% | 60% ✅ |
| 2 shipped | 3,199,370 | 32.0% | 20% |
| 0 pending | 744,907 | 7.4% | 13% |
| 3 cancelled | 55,664 | 0.56% | 6% |
| 4 refunded | **561** | **0.0056%** | **1%** |

ズレた点と理由（★重要な学び）:
- 計画書の CASE は各 WHEN で **独立した random() を呼んでいる**ため、閾値 0.60/0.80/0.93/0.99 が
  「単一乱数に対する累積しきい値」として機能していない。
  - 意図: 1つの乱数 r に対し r<0.60→paid, 0.60〜0.80→shipped… という累積分割（→ refunded=1%）
  - 実際: 各分岐で毎回サイコロを振り直すので、後段ほど到達確率が掛け算で激減（refunded≈0.0056%）
- paid だけ 60% で一致するのは、最初の分岐だけは単一乱数と等価だから。
- SQL の CASE は WHEN ごとに式を再評価する、という基本の落とし穴の実例。

修正後（単一乱数 r を FROM 側で1回生成 → 累積しきい値で分岐）で再投入した結果、意図通りに:
| status | 件数 | % | 意図% |
|---|---|---|---|
| 0 pending | 1,298,358 | 12.98% | 13% ✅ |
| 1 paid | 5,998,790 | 59.99% | 60% ✅ |
| 2 shipped | 2,001,409 | 20.01% | 20% ✅ |
| 3 cancelled | 601,400 | 6.01% | 6% ✅ |
| 4 refunded | 100,043 | 1.00% | 1% ✅ |
→ これ以降のフェーズはこの分布を前提にする。refunded=約10万件で §5.2/§6.7 の narrative と整合。

計測前の予測（計画書 §4.1 / Claude の予測）:
- Q1. status='paid'(600万件)で絞り created_at DESC で20件取るのに: **約800ms**
    （インデックス無し→ orders 全走査 574MB + 600万行のソートが支配的）
- Q2. OFFSET 0 と OFFSET 100000 の速度差: **約1.2倍（あまり変わらない）**
    （全走査＋ソートが支配的なので OFFSET の増加は総時間に効きにくい、と予想。
      OFFSET が線形に効く現象は index があってこそ、という仮説）
- Q3. 20行返すためにDBは何行読む: **約1000万行（全行）** — うち600万行が status=1 通過。
    Buffers は 574MB/8KB ≒ **約73,000 ブロック**

実測（§4.4 記録テンプレート。prewarm 済みなので Buffers は全て hit。時間は 1回目/2回目warm）:

| OFFSET | 実行時間(cold/warm) | Buffers | actual rows(スキャン) | Sort 方式 |
|---|---|---|---|---|
| 0 | 2604ms / 314ms | shared hit=73,602 | 全1000万走査(paid 600万通過, 400万をFilterで除去) | **top-N heapsort 27kB（メモリ内）** |
| 100,000 | 1126ms / 583ms | hit=73,602 + temp書込 30,863 | 同上 | **external merge Disk ~88MB（ディスク退避）** |
| 1,000,000 | 807ms / 662ms | hit=73,602 + temp書込 30,863 | 同上 | **external merge Disk ~94MB（ディスク退避）** |

共通のプラン: `Limit → Gather Merge(2 workers) → Sort → Parallel Seq Scan`
- Parallel Seq Scan: 3プロセス(leader+worker2)で分担、各 loop 199万行、Rows Removed by Filter 各133万
- **Buffers: shared hit=73,530 はどの OFFSET でも一定** ＝ テーブル読み込みコストは OFFSET に無関係

回答:
- Q1（予測800ms）: cold 2604ms / warm 314ms。warmは予測より速く、coldは予測より遅い。
  → 「何msか」は**キャッシュ状態で桁が動く**。ブロック数(73,602)の方が安定した指標。
- Q2（予測1.2倍）: warm で 314→583→662ms。OFFSET 0→100k で約1.85倍、100k→1M(10倍)でも1.13倍。
  → **線形には増えない**。理由は下記。予測の「あまり変わらない」は方向性は当たりだが、
    真因（work_mem 溢れ）を外していた。
- Q3（予測1000万行/73,000ブロック）: **的中**。actual で全1000万走査・shared hit=73,530 ≒ 73,000。

ズレた点と理由（★このフェーズの核心）:
- **最大の発見: work_mem を超えた瞬間にソートがメモリ→ディスクに落ちる断崖**。
  - OFFSET 0: LIMIT境界が20行→ top-N heapsort が 27kB で収まり**メモリ内**（速い）
  - OFFSET 100k/1M: 実質 OFFSET+LIMIT 行をソート対象に保持 → work_mem 16MB を超え
    → **external merge（ディスク退避, temp 80〜94MB書込）** に切替。これが遅さの正体。
  - §1.2 で work_mem=16MB にした意味がここで出た。「小さいとSortが即ディスクに落ちる」の実物。
- **OFFSET のコストは「テーブル読込」ではなく「ソート量」に出る**。
  Buffers hit は 73,602 で不変。増えるのは Gather Merge が通す行数(100,020 / 1,000,020)と temp I/O。
  つまり「20行返すために毎回全表を読み、さらに大量行をソート＆退避して大半を捨てている」。
- 温度差の実例: 同じ OFFSET 100k でも temp write I/O が 1093ms→322ms と変動。
  → 計画書§11「比較は必ず複数回」の通り、1回の数字を信じてはいけない。
- 副次観察: JIT が効いており cold 実行で 15〜236ms の追加コスト。「遅い=SQLが悪い」とは限らない例。

---

## Phase 3: インデックス設計の比較実験

予測（Claude の予測）:
- どのパターンで Sort ノードが消えるか: **C のみ**。A は created_at 順は得るが status を Filter で弾く。
  B も先頭が created_at なので status は Filter。C だけ status 等値→created_at 連続で Sort 不要。
- A/B は status=1 でも Index を使い、created_at 降順スキャンしながら status!=1 を捨てる想定。
  paid は 60% なので 20 行返すのに約 33 行読む（許容）。
- status=4(refunded, 1%) でパターン B の Rows Removed by Filter: **約 2000 行**（20/0.01）。
- idx_c サイズ: 3 列 btree で **約 300MB** と予想。

実測（status=1 paid, LIMIT 20, warm）:

| パターン | 実行時間(warm) | Buffers | スキャン種別/Sort | Rows Removed by Filter |
|---|---|---|---|---|
| なし | 314ms | hit=73,602 | Parallel Seq Scan + **Sort(top-N)** | 400万(全表) |
| A (created_at) | 0.015ms | hit=41 | Index Scan, **Sortなし**, Filter:status | 18 |
| B (created_at DESC, status) | 0.015ms | hit=23 | Index Scan, **Sortなし**, **Index Cond:status** | 0 |
| C (status, created_at DESC, id DESC) | 0.015ms | hit=24 | Index Scan, **Sortなし**, **Index Cond:status** | 0 |

インデックスサイズ: A=214MB / B=300MB / C=387MB（列が増えるほど大きい＝書込コスト増）

### ★ 選択率による評価の反転（§5.2 の核心）— status=4 refunded(1%) で再計測

| パターン | 実行時間(warm) | Buffers | Rows Removed by Filter |
|---|---|---|---|
| A (created_at のみ) | 0.86ms | **hit=2,527** | **2,498** ← Filter爆発 |
| B (created_at, status) | 0.031ms | hit=32 | 0（Index Cond） |
| C (status, created_at, id) | 0.014ms | hit=24 | 0（Index Cond） |

### §5.3 DESC 指定は必要か（逆順スキャン検証）
- 全ASCの idx (status, created_at, id) でも `ORDER BY created_at DESC, id DESC` は
  **Index Scan Backward** で処理でき **Sort なし**。→「DESCを付けないとDESCに使えない」は誤解。
- 方向混在 `created_at DESC, id ASC` にすると **Incremental Sort** が出現（created_atは整列済みなので
  同値グループ内のidだけ部分ソート）。→ 方向が混在するときだけ DESC 明示に意味がある。

ズレた点と理由（★重要）:
1. **予測「B は status を Filter で弾く」は外れ**。実際は `Index Cond: status=1`。
   理由: idx_b は status を2列目に**含む**ため、ヒープに行かず**インデックス内で status を評価**できる。
   → 計画書が想定した「B で Filter 爆発」は、現代 PG では B では起きない。
2. **真の Filter 爆発は パターンA（status を含まない index）で起きた**。
   refunded で Rows Removed by Filter=2,498 / Buffers 2,527（paid の 100倍）。
   → §5.2 の教訓「同じ index でも選択率で評価が反転」は正しいが、それが露呈するのは
     「ソート列だけの index（A）」の場合。予測2000行に対し実測2498行でほぼ的中。
3. A/B/C とも paid では 0.015ms・数十ブロックで横並び（Sort が消えた効果は絶大）。
   差が出るのは (a)低選択率 refunded と (b)keyset で深いページを繰るとき（Phase 4 で確認）。
   → 1ページ目だけ見ると A/B/C の優劣が見えない。ここが Phase 4/6 の伏線。
4. C を Phase 4 用の正解として最終的に残した（他は DROP 済み）。

---

## Phase 4: Keyset Pagination の実装

予測（Claude）:
- 行値比較 `(created_at,id) < (?,?)` は Index Cond に落ち、Buffers 数十・Sortなし。
- OR手書き `created_at<? OR (created_at=? AND id<?)` は Index Cond に落ちず Filter になり、
  カーソルより新しい側を大量に読んで捨てる（深いページほど悪化）想定。
- keyset はカーソルが深いページでも Buffers ほぼ一定（OFFSET と違い先頭から数えない）。

実測（SQLレベル §6.1〜6.3）:
- Index Cond に ROW(...) が入ったか: **✅ 入った**
  `Index Cond: ((status = 1) AND (ROW(created_at, id) < ROW('2026-08-10 ...', 9368553)))`
  warm 27ブロック / 0.196ms、Sort なし。目標プラン(§6.3)通り。
- OR手書き版との EXPLAIN 差分: **★決定的**
  | 書き方 | Index Cond | Filter | Rows Removed | Buffers | 時間 |
  |---|---|---|---|---|---|
  | 行値比較 (a,b)<(?,?) | status + ROW(...) | なし | 0 | **27** | 0.2ms |
  | OR手書き | status のみ | OR式 | **100,001** | **100,518** | **4637ms** |
  → OR は「カーソルより新しい側10万件を全部読んで捨てる」。行値比較の**約3700倍のブロック**。
  論理的には等価でも、プランナは OR を Index Cond に落とせない。これが本課題で最も実用的な知識。
- カーソルが何ページ目でも Buffers 一定か: **✅ 一定**
  1ページ目相当(OFFSET 10万境界) hit=27 / 深いページ(OFFSET 300万境界) hit=24。
  → OFFSET は先頭から数えるので深いほど悪化するが、keyset は「境界へ直行」なので不変。
    これが Phase 6 の p95 で効いてくる本質。

### ★ 低選択率 status=4 refunded(1%) でも keyset は一定か（追加検証）
選択率が高い paid(60%) だけでなく、低い refunded(1%) でも行値比較が効くかを確認。
| カーソル位置 | Index Cond | Buffers | 時間(warm) |
|---|---|---|---|
| 浅い(1000件目) | status=4 AND ROW(...) | hit=24 | 0.020ms |
| 深い(9万件目≒最後) | status=4 AND ROW(...) | hit=24 | 0.019ms |
→ **選択率に関係なく Index Cond に落ち、Buffers 24 で一定**。paid(27↔24) とほぼ同値。
  理由: idx_c は先頭が status なので「refunded の棚」に直行し、その中は created_at 順。
  棚のサイズ(1% か 60% か)は関係なく、境界から20件読むだけ。
  ※Phase3 のパターンA(created_atのみ)では refunded で Buffers 2,527 に爆発したのと対照的。
    「keyset が効くのは正しい列順(status先頭)の idx_c があってこそ」を再確認。
- iso8601(6) → to_s に変えるとテストが落ちるか: **✅ 落ちた**
  to_s（秒精度に丸め）にすると同一秒境界で期待200件→実測1000件（同じ行を無限再読込＝重複爆発）。
  iso8601(6) に戻すと全テスト green。§6.5 の「境界で取りこぼす/重複する」を実証。

Rails 実装（§6.4〜6.7）:
- app/models/order.rb: scope page_order / seek_after（行値比較）
- app/queries/cursor.rb: iso8601(6) + Base64 urlsafe（不透明カーソル）
- app/queries/order_page_query.rb: LIMIT per_page+1 で has_next 判定（COUNT不要）
- app/controllers/api/orders_controller.rb + routes（GET /api/orders）
- test/queries/order_page_query_test.rb: 自前データ（同一秒の塊を境界にまたがせる）で
  重複・欠落・順序・壊れカーソル・iso8601精度を検証 → 3 runs green

E2E 検証:
- 単体テスト(テストDB): 3 runs 0 failures
- 1000万行(dev DB)に対し runner でページ送り: page1↔page2 重複0件・時系列連続 ✅
- HTTP: GET /api/orders?status=paid → 20件+next_cursor、cursor送りで page2 取得 ✅
  refunded でも status 絞り込み動作 ✅
- 注意: JSON表示の created_at はミリ秒精度(as_json既定)だが、カーソルは内部で
  record.created_at.iso8601(6) を使うので境界精度は保たれる（表示とカーソルは別物）。

TODO(後続): idx_c はまだ生SQL作成でマイグレーション未化。テストDBには idx_c が無い
（正しさ検証はindex非依存なので影響なし）。Phase 7 の安全なマイグレーションで add_index する。

---

## Phase 5: COUNT の壁

予測（Claude）:
- `COUNT(*) WHERE status=1`(600万件) は idx_c を index-only scan で全走査 → 200〜400ms 程度。
  Phase 1 の `count(*)` 全件 121ms(warm) より、範囲が狭い分やや速いか同等と予想。
- 近似(EXPLAINのPlan Rows)は 1ms 未満。ANALYZE 依存で誤差数%。

実測:
- `COUNT(*) WHERE status=1`(paid 600万) 単体: cold 468ms / **warm 232ms**（EXPLAIN）
  ★プランナは index-only scan ではなく **Parallel Seq Scan** を選択（予測外れ）。
   status=1 は60%と選択率が高すぎ、インデックスより全走査が得と判断（§11の「選択率が高すぎてSeq Scanが正解」）。
   Buffers 約73,530。Rails経由の `.count` でも warm 138ms。
- keyset 本体は 0.02ms。**COUNT を足した瞬間に 138〜232ms で p95<100ms を確実に割る** = COUNTの壁。
- Phase 1 の全件 `count(*)` warm 121ms と同オーダー（範囲を絞っても全走査なら大差なし）。

3つの選択肢（実装して計測）:

| 方式 | 実測 | 正確さ | コスト/トレードオフ |
|---|---|---|---|
| ①総件数を出さない(has_next) | 0.02ms | 件数は出ない | 実装済(Phase4のLIMIT+1)。無限スクロールUIなら最適。**技術で殴らず要件を削る** |
| ②近似(EXPLAIN Plan Rows) | **0.27ms** | 誤差0.0099%(5,999,381 vs 5,998,790) | ANALYZE 頻度に精度依存。"約N件"表示に最適。Google 検索結果と同発想 |
| ③カウンタテーブル | 読取**1.96ms**/更新257ms | 完全一致 | 読取は速く正確だが「誰が更新し続けるか」の問題。定期バッチ=結果整合(遅延)、トリガ=常時正確だが書込ごとに競合ポイント増 |

学び: 「正確な総件数が本当に必要か」をプロダクト側と交渉するのが一番効く（唯一コードを書かない解法=①）。
実装: Order.approximate_count / OrderStat(refresh_all, count_for) + migration。
バグ: group(:status).count は enum名文字列を返し integer列にupsertすると全部0にキャストされ衝突
→ Order.statuses で整数コードへ明示変換して解決。

---

## Phase 6: p95 の計測と比較

| 方式 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| OFFSET | | | | |
| Keyset | | | | |

- 目標 p95 < 100ms 達成: ____
- StackProf アプリ層内訳: ____

---

## Phase 7: 発展課題（任意）
-
