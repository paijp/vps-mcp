# vps-mcp

さくらのVPS（RockyLinux 9）に Claude.ai MCP サーバーを構築するスタートアップスクリプト集です。

## ファイル一覧

| ファイル | 説明 |
|---|---|
| `sakura-rocky9b.txt` | RockyLinux 9 用スタートアップスクリプト（BIND + MCP + Nginx + SSL） |

## セットアップ概要

スクリプトは以下を自動構築します：

1. swapfile（1GB）
2. Node.js 20 + MCPサーバー（express + @modelcontextprotocol/sdk）
3. BIND（プライマリDNS）+ ゾーンファイル自動生成
4. certbot-dns-rfc2136（Let's Encrypt SSL 自動取得・更新）
5. Nginx（リバースプロキシ・SSE対応）
6. firewalld（ssh/http/https/udp53/tcp3000）

## パラメータ

さくらのVPSコントロールパネルの「マイスクリプト」に登録し、以下のパラメータを設定してください。

| パラメータ名 | 説明 | 例 |
|---|---|---|
| `DOMAIN` | ドメイン名 | `example.com` |
| `LETSENCRYPT_EMAIL` | Let's Encrypt 通知メール | `you@example.com` |
| `MCP_API_KEY` | MCP認証キー（32文字以上推奨） | （任意の文字列） |
| `NS1_IP` | このVPSのグローバルIPアドレス | `153.126.xxx.xxx` |

### NS1_IP について

VPSのグローバルIPアドレスをゾーンファイルの `@ IN A` および `ns1 IN A`（グルーレコード）に使用します。
`curl ifconfig.me` で自動取得することも可能ですが、複数NICがある場合にプライベートIPが取得されることがあるため、さくらのコントロールパネルで確認したグローバルIPを明示的に指定しています。

## claude.ai への登録

```
Settings → Integrations → Add Integration
URL: https://<DOMAIN>/mcp/<MCP_API_KEY>/sse
```

## MCPツール

| ツール名 | 機能 |
|---|---|
| `exec_command` | VPS上でシェルコマンドを実行（root権限） |
| `read_file` | ファイルを読み込む |
| `write_file` | ファイルに書き込む（上書き） |

## セットアップ後の手動作業

1. さくらのドメインコントロールパネルで「セカンダリネームサーバーとして利用する」を選択し、VPSのIPを登録
2. レジストラ側でNSレコードを `ns1.<DOMAIN>` に向ける
3. グルーレコード（`ns1.<DOMAIN>` の A レコード）をレジストラに登録
4. DNS浸透後、certbotが未実行であれば手動で実行：
   ```bash
   certbot certonly --dns-rfc2136 \
     --dns-rfc2136-credentials /etc/certbot/rfc2136.ini \
     --non-interactive --agree-tos --email <EMAIL> -d <DOMAIN>
   ```

## SSL証明書の自動更新について

`certbot certonly` で取得した証明書は、certbotが `/etc/cron.d/certbot` または systemdタイマー（`certbot-renew.timer`）を自動登録するため、**90日ごとに自動更新されます**。

ただし `certbot certonly` はNginxへの反映（reload）を自動で行いません。以下のdeploy hookを設定してください：

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

更新動作の確認：
```bash
certbot renew --dry-run
```

## ゾーン転送について

さくらのセカンダリDNSからのゾーン転送元IPは固定です：
- `210.188.224.9`
- `210.224.172.13`

参考: [さくらのサポート - ゾーン情報を編集したい](https://help.sakura.ad.jp/domain/2302/)

## セキュリティ注意事項

- MCPサーバーはroot権限で動作します（実験用途）
- 本番運用前に専用ユーザーへの切り替えを検討してください
- MCP_API_KEY はURLパスに含まれます（Nginxログはマスク済み）
