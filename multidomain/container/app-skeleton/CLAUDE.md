# このリポジトリについて（3コンテナモデル）

このコンテナは、本番・ステージング・開発の3つのコンテナのうちの**開発コンテナ**です。

| 役割 | 例 | MCP | 更新のしかた |
|---|---|---|---|
| 本番 | `a.example.com` | なし | 人がホストで `make a.example.com.stg2prod` |
| ステージング | `a-stg.example.com` | なし | 人がホストで `make a.example.com.dev2stg` |
| 開発（ここ） | `a-dev.example.com` | あり | Claude が直接作業する |

本番とステージングには、ここから接続できません。試行錯誤はこの開発コンテナの中だけで行い、
結果をこのリポジトリ（`/srv/app`）にコミットします。人がそれをステージング、次に本番へ送ります。

## 作業のしかた

1. `files/` の下に、置き先と同じパスでファイルを置く
   （例: `files/etc/nginx/app.d/shop.conf` → `/etc/nginx/app.d/shop.conf`）。
2. `make install` でこのコンテナに反映して動作を確認する。
   開発コンテナでは nginx を reload しないので、反映後に `nginx_reload` ツールを使う。
3. **コミットする。** ステージングに送られるのはコミット済みの HEAD だけで、
   未コミットの変更があるとホストの `dev2stg` は止まる。

`make install` は、開発・ステージング・本番のどれでも同じように動く必要があります。
このコンテナで手作業で入れたもの（パッケージ、設定、ファイル）に依存しないよう、
必要なものはすべて Makefile か `files/` に入れてください。

## Makefile の約束

- `install` は冪等にし、最初のエラーで止める。失敗したら `getlog` で診断情報を出し、
  終了コードは失敗のままにする（ホストで人が実行し、その出力が Claude に渡される）。
- `diff` は、`install` が何を変えるかを表示するだけにする。
- 秘密情報（DB のパスワード、API キーなど）はコミットしない。各サーバーに人が置き、
  `REQUIRED_LOCAL` にパスを書く。
- 管理者などの最初のログイン情報は人が登録する。シードデータに入れない。
- nginx の設定は `files/etc/nginx/app.d/<アプリ名>.conf` に location ブロックとして書く。
  `/etc/nginx/conf.d/vps-mcp.conf` と `/etc/nginx/mcp.d/` は変更しない。
- 別のホスト名を受ける HTTPS の server ブロックは `files/etc/nginx/conf.d/` に置き、
  `listen` と `ssl_certificate` は書かずに、次の2行を入れる（転送モードの切り替えで
  ホスト側が書き換えるファイル）:
  ```nginx
  include /etc/nginx/listen443.conf;
  include /etc/nginx/ssl-cert.conf;
  ```
  そのホスト名は `files/etc/vps-mcp/cert-names` にも1行で足す（本番の証明書に入る）。

## 旧サーバーからの移行（`files/etc/nginx/app.d/forward.conf` がある場合）

このサイトは旧サーバーから移行中です。`forward.conf` は、ほかの `app.d/` のファイルが
受け持たないリクエストを、すべて旧サーバーへ転送します。

- 移植した部分は、`app.d/<アプリ名>.conf` に書く。より具体的な `location` が優先されるので、
  `forward.conf` を変えなくても移植した部分はこちらで答える。
- 転送する範囲を狭めるときは `forward.conf` の `location` を書き換え、全部移植したら
  `forward.conf` を消して、`app.d/default.conf`（`/var/www/html` を返す）か自分の
  `location /` を置く。
- 旧サーバーの応答は、このコンテナからも確かめられる（同じ転送がここでも効いている）。

## ステージングの様子を見る

- `/mnt/stg/` … ステージングのファイルシステム全体（読み取り専用）。
  `make install` が失敗したときは、ここで実際のファイルとログを確認する
  （ジャーナルは `journalctl -D /mnt/stg/var/log/journal`）。
- `/srv/stg-mail/` … ステージングが送信したメールの写し（1通1ファイル、`.eml`）。
  メールは本来の宛先にも届いている。登録確認やログインのメールはここで読める。

## git の目印

- `stg/main` … いまステージングで動いているコミット
- `prod/main` … いま本番で動いているコミット

どちらもホストが付け替えるので、動かさないでください。
`git log stg/main..HEAD` で、まだステージングに出していない変更が分かります。
本番の不具合を急いで直すときは、作業中の `main` に別の名前のブランチを付けてから、
`main` を `prod/main` に戻して修正し、あとで作業中のブランチに取り込みます。
