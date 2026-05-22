# vps-mcp

さくらのVPS（RockyLinux 9）に Claude.ai MCP サーバーを構築するスタートアップスクリプト集です。

> このコードは Claude Sonnet 4.6 が書きました。

## セキュリティポリシー

このスクリプトはMCP経由でroot権限のシェル実行（`exec_command`）を提供します。これはバグではなく、Claudeに1台のVPSを完全に委ねるための仕様です。

- token漏洩 = root権限漏洩と等価です
- 防御は「CLIENT_SECRETの保護」と「token発行通知メールによる検知」の2段のみ
- 不正な発行通知を受けた場合は、サーバを破棄して再構築してください
- 多層防御は意図的に省略しています（破られた後の緩和策は意味がないため）
- `/token` エンドポイントはclaude.aiのIPレンジ（160.79.104.0/21）のみ許可しています
  （出典: https://platform.claude.com/docs/en/api/ip-addresses）

### CLIENT_SECRET と CLIENT_ID について

両方とも**サーバ構築のたびに新規ランダム生成**してください。

- CLIENT_SECRET: 12文字以上のランダム文字列を推奨
- CLIENT_ID: 10文字以上のランダム文字列を推奨

過去に使用した値を再利用しないでください。過去のtoken通知メールやスタートアップスクリプト履歴に値が残るため、将来そのアカウントが侵害された場合に攻撃の足がかりになります。

正規ユーザーは、token通知メールを受け取ったら、メールタイトルの `client_id=***` が自分が今回設定した値と一致するか確認してください。一致しない場合、自分が接続する前にメールが来た場合、メールが2通以上きた場合は、secret突破による不正な初回接続が行われた可能性があります。ただちにサーバを廃棄し、新しい CLIENT_SECRET / CLIENT_ID で再構築してください。

## ファイル一覧

| ファイル | 説明 |
|---|---|
| `sakura-rocky9-root-dns.txt` | RockyLinux 9 用スタートアップスクリプト（BIND + MCP + Nginx + SSL・コメントなし） |
| `sakura-rocky9-root-dns-withcomment.txt` | 同上（コメントあり・参照・編集用） |

## セットアップ概要

スクリプトは以下を自動構築します：

1. swapfile（1GB）
2. Node.js 20 + MCPサーバー（express + @modelcontextprotocol/sdk）
3. BIND（プライマリDNS）+ ゾーンファイル自動生成
4. Nginx（リバースプロキシ・SSE対応）
5. certbot（HTTP-01方式・Let's Encrypt SSL 自動取得・更新）
6. firewalld（ssh/http/https/udp53/tcp53/tcp3000）
7. dnf-automatic（セキュリティアップデート自動化）
8. 週次reboot（日曜3時・カーネル更新適用）

## パラメータ

さくらのVPSコントロールパネルの「マイスクリプト」に登録し、以下のパラメータを設定してください。

| パラメータ名 | 説明 | 例 |
|---|---|---|
| `DOMAIN` | ドメイン名 | `example.com` |
| `NS1_IP` | このVPSのグローバルIPアドレス | `153.126.xxx.xxx` |
| `CLIENT_SECRET` | OAuth2認証用クライアントシークレット（12文字以上のランダム文字列を推奨） | ランダム生成値 |
| `EMAIL` | Let's Encrypt 通知メール・スタートアップログ送信先・token発行時通知先 | `you@example.com` |

### NS1_IP について

VPSのグローバルIPアドレスをゾーンファイルの `@ IN A` および `ns1 IN A`（グルーレコード）に使用します。複数NICがある場合にプライベートIPが取得されることがあるため、さくらのコントロールパネルで確認したグローバルIPを明示的に指定しています。

## OAuth2認証フロー

OAuth2 authorization_code + PKCEフローを使用しています。

```
1. GET /.well-known/oauth-authorization-server
   → claude.aiがエンドポイントを自動検出

2. GET /authorize
   → redirect_uriにcode=xでリダイレクト（素通り）

3. POST /token { client_secret: "...", client_id: "...", code: "x", ... }
   → secretファイルと照合 → secretファイル削除
   → token発行通知メール送信（タイトルにclient_id=***を含む）
   → 5秒後にtoken返却（メール配送完了の確率を上げるため）
   → tokenは最初の1回のみ発行（secretファイル削除後は403）

4. GET /mcp/sse { Authorization: Bearer <token> }
   → SSE接続成功
```

## claude.ai への登録

```
Settings → Integrations → Add custom integration
URL:           https://<DOMAIN>/mcp/sse
client_id:     <10文字以上のランダム文字列>
client_secret: <CLIENT_SECRET に設定した値>
```

初回接続時に自動でtokenが発行されます。以降は同じtokenで接続が維持されます。

### 2台目のアカウントから接続する場合

secretファイルを再作成すると同じtokenが返されます。

```bash
echo "<CLIENT_SECRETの値>" > /etc/mcp-server/secret
chmod 600 /etc/mcp-server/secret
```

### tokenのリセット

```bash
rm /etc/mcp-server/token
# 次のリクエストから401を返す
# secretファイルを再作成すると再認証可能
```

## MCPツール

| ツール名 | 機能 |
|---|---|
| `exec_command` | VPS上でシェルコマンドを実行（root権限） |
| `nginx_reload` | Nginxをリロード（設定テスト後2秒後に実行・SSEセッション切断あり） |

## セットアップ後の手動作業

1. さくらのドメインコントロールパネルで「セカンダリネームサーバーとして利用する」を選択し、VPSのIPを登録
2. レジストラ側でNSレコードを `ns1.<DOMAIN>` に向ける
3. グルーレコード（`ns1.<DOMAIN>` の A レコード）をレジストラに登録
4. DNS浸透後、certbotが未実行であれば手動で実行：
   ```bash
   certbot --nginx --non-interactive --agree-tos --email <EMAIL> -d <DOMAIN>
   ```

## ゾーン転送について

さくらのセカンダリDNSからのゾーン転送元IPは固定です：
- allow-transfer: `210.188.224.9` / `210.224.172.13`
- also-notify: `61.211.236.1`（ns1.dns.ne.jp）/ `133.167.21.1`（ns2.dns.ne.jp）

参考: [さくらのサポート - ゾーン情報を編集したい](https://help.sakura.ad.jp/domain/2302/)

## セキュリティ対応済み項目

| 項目 | 対応内容 |
|---|---|
| 認証方式 | OAuth2（authorization_code + PKCE）、client_secretで検証 |
| token発行 | 初回のみ（secretファイル削除後は403） |
| token発行通知 | メール送信・タイトルにclient_idを含む（不審な接続を即座に検知可能） |
| token返却 | 5秒遅延（メール配送完了の確率を上げるため） |
| /tokenのIPアドレス制限 | claude.aiのIPレンジ（160.79.104.0/21）のみ許可 |
| MCPログの標準出力 | Nginx access_log off（MCPパス） |
| オープンリゾルバ | allow-recursion { 127.0.0.1; } |
| セキュリティ自動更新 | dnf-automatic（security only） |
| カーネル更新 | 週次reboot（日曜3時） |
