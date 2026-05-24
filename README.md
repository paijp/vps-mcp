# vps-mcp

さくらのVPS(RockyLinux 9)に Claude.ai MCP サーバーを構築するスタートアップスクリプト集です。

> このコードとドキュメントは Claude Sonnet 4.6・Opus 4.7 が書きました。

## セキュリティポリシー

このスクリプトはMCP経由でroot権限のシェル実行(`exec_command`)を提供します。これはバグではなく、Claudeに1台のVPSを完全に委ねるための仕様です。

- token漏洩 = root権限漏洩と等価です
- 防御は「CLIENT_SECRETの保護」と「token発行通知メールによる検知」の2段のみ
- 不正な発行通知を受けた場合は、サーバを破棄して再構築してください
- 多層防御は意図的に省略しています(破られた後の緩和策は意味がないため)
- `/token` エンドポイントはclaude.aiのIPレンジ(160.79.104.0/21)のみ許可しています
  (出典: <https://platform.claude.com/docs/en/api/ip-addresses>)

なお、Claude による VPS 操作は、**自己責任**でお願いします。指示の内容や状況によっては、ファイルの削除・設定の破壊・課金が発生する処理など、取り返しのつかない操作がおこなわれるリスクがあります。承知の上でご利用ください。

## クイックスタート

### 1. ドメインのDNS設定(先に実行)

VPSのIPアドレスでドメインが名前解決できる状態を、**スタートアップスクリプト実行前に**用意してください。DNSが引けないと、スクリプト内で certbot が Let's Encrypt 証明書を取得できず、MCP サーバへの HTTPS アクセスもできません。

このVPSをドメインのネームサーバとして使う場合と、既存のネームサーバから A レコードで指す場合の2通りがあります。

**(A) このVPSをネームサーバにする場合**

レジストラ側で以下を設定:

- NSレコードを `ns1.<DOMAIN>` に向ける
- グルーレコード(`ns1.<DOMAIN>` の A レコード)をVPSのIPで登録
- さくらのドメインコントロールパネルで「セカンダリネームサーバーとして利用する」を選択し、VPSのIPを登録

スタートアップスクリプトのパラメータ `NS1_IP` にはVPSのグローバルIPv4アドレスを指定します(後述)。VPSがゾーンファイルの `@ IN A` および `ns1 IN A`(グルーレコード)を生成します。複数NICがある場合にプライベートIPが取得されることがあるため、さくらのコントロールパネルで確認したグローバルIPを明示的に指定しています。

**(B) 既存のネームサーバを使う場合**

ドメインの A レコードに、VPSのグローバルIPv4アドレスを設定してください。この場合もスタートアップスクリプトのパラメータ `NS1_IP` には同じくVPSのIPを指定します(スクリプトはBINDも構築しますが、外部からの問い合わせは既存ネームサーバが処理します)。

DNS浸透を確認してから次のステップに進んでください(`dig @8.8.8.8 <DOMAIN>` 等で確認)。

なお、IPv6はOS側で無効化されています(`net.ipv6.conf.all.disable_ipv6 = 1`)。さくらVPSの管理画面でグローバルIPv6が割り当て表示されていても、カーネル・nginx・Node.js のいずれもIPv6パケットを処理しません。

### 2. スタートアップスクリプトの登録

さくらのVPSコントロールパネルの「マイスクリプト」に `sakura-rocky9-root-dns.txt` を登録してください。以下のパラメータを設定します:

| パラメータ名 | 説明 | 例 |
|---|---|---|
| `DOMAIN` | ドメイン名 | `example.com` |
| `NS1_IP` | このVPSのグローバルIPv4アドレス | `153.126.xxx.xxx` |
| `CLIENT_SECRET` | OAuth2認証用クライアントシークレット(12文字以上のランダム文字列を推奨) | ランダム生成値 |
| `EMAIL` | Let's Encrypt 通知メール・スタートアップログ送信先・token発行時通知先 | `you@example.com` |

#### CLIENT_SECRET と CLIENT_ID の値について

`CLIENT_SECRET` はパラメータとして設定します。`CLIENT_ID` はサーバ側に保存されず、後のステップでClaude.ai コネクタに入力する値です。両方とも**サーバ構築のたびに新規ランダム生成**してください。

- **CLIENT_SECRET**: 12文字以上のランダム文字列を推奨
- **CLIENT_ID**: **6〜8桁の数字**(`/token` 側で整数として解釈される)

過去に使用した値を再利用しないでください。過去のtoken通知メールやスタートアップスクリプト履歴に値が残るため、将来そのアカウントが侵害された場合に攻撃の足がかりになります。

**CLIENT_ID に推測されやすい値を使わないでください**:

- **今日の日付**(`20260524` 等)
- 誕生日、電話番号、連続数字、ゾロ目
- 過去のサーバ構築で使った値

これらは攻撃者がステルス侵入時の偽装に使う最有力候補です。理由の詳細は「専門家向け補足」の攻撃シナリオ 2.1 を参照してください。推奨は `node -e "console.log(require('crypto').randomInt(10000000, 100000000))"` 等によるランダム8桁生成です。

CLIENT_ID の仕様詳細:

- 受理される値: 6〜8桁の整数(例 `123456`, `78451293`)
- 拒否される値: 空文字列、`0`、英字を含む文字列、`null`、`undefined`、オブジェクト等
- **先頭のゼロは省略される**(例: `00123456` → `123456` として扱われる)。ゼロで始まる値は避けてください
- 小数や指数表記(`1e7` 等)も数値として通るが、推奨は素直な6〜8桁の整数
- メール件名には数値化後の値がそのまま出力される(例: `MCP token issued client_id=78451293`)

`client_id` がメール件名内のspam分類トリガー文字列になりうることを避けるため、文字種を数字のみに制限しています。設計上の理由は「専門家向け補足」を参照してください。

### 3. OS再インストールの実行

さくらVPSコントロールパネルで対象サーバを選び、「OS再インストール」を選択。RockyLinux 9 を選び、上記マイスクリプトと先ほど設定したパラメータを指定して、インストールを実行してください。

インストールが完了するとスタートアップスクリプトが自動実行されます。数分から10分程度で、登録したメールアドレスにセットアップ完了の通知メールが届きます。

セットアップ完了メールが届かない場合、DNS設定がまだ反映されていないために Let's Encrypt の証明書取得が失敗している可能性があります。**SSH公開鍵を設定済みであれば**、SSHでログインして手動で certbot を実行してください:

```bash
certbot --nginx --non-interactive --agree-tos --email <EMAIL> -d <DOMAIN>
```

SSHを使えない場合は、DNS浸透を待ってからOS再インストールをやり直すか、しばらく待ってサーバ側の certbot 自動リトライ(`systemctl status certbot-renew.timer` 等)を確認してください。

### 4. Claude.ai コネクタの登録

Claude.ai で以下を操作:

```
カスタマイズ → コネクタ → 追加 → カスタムコネクタ
URL:           https://<DOMAIN>/mcp/sse
client_id:     <ステップ2で決めた6〜8桁の数字>
client_secret: <ステップ2で設定したCLIENT_SECRET>
```

### 5. 接続時の確認(最重要)

接続を実行すると、token発行通知メールが届きます。**メールタイトル内の `client_id=***` が、ステップ2で自分が決めた値と完全に一致するか必ず確認してください**。

確認すべき項目:

- **メールタイトルの `client_id=***` が自分が設定した値と完全に一致するか** ← 最重要
- メールが自分が接続する前に届いていないか
- メールが2通以上きていないか

いずれかに該当する場合、CLIENT_SECRET突破による不正な初回接続が行われた可能性があります。**ただちにサーバを廃棄し、新しい CLIENT_SECRET / CLIENT_ID で再構築してください**(具体手順は次節)。

なお、攻撃者がroot権限を取得後にメール送信機能を一時的に潰して2通目を発火させない攻撃が成立しうるため(専門家向け補足 2.1 参照)、「2通来たか」「自分の操作前か」は補助的な判定にとどまります。**`client_id` の完全一致こそが本質的な検知シグナル**です。

### 6. 利用開始

これで Claude.ai から VPS を操作できるようになりました。例えば「`<コネクタ名>` でwebサーバに準備中のページを作って」のような指示が可能です。

なお、Claude による VPS 操作は、**自己責任**でお願いします。指示の内容や状況によっては、ファイルの削除・設定の破壊・課金が発生する処理など、取り返しのつかない操作がおこなわれるリスクがあります。承知の上でご利用ください。

## 不正検知時の対応

**重要: 「secret/tokenの再設定」だけでは不十分です。** 攻撃者が一度でも `exec_command` を実行できた場合、cron・systemdユニット・SSH鍵・iptables・kernel module 等あらゆる場所に永続バックドアを仕込めるため、**OSレベルで信頼できる状態に戻すことは事実上不可能**です。VPSインスタンス自体を捨ててください。

具体手順:

1. **claude.aiコネクタを削除** — 設定 → Integrations → 該当コネクタを削除
2. **さくらVPS管理画面でサーバを削除** — 「サーバ削除」を実行(完全削除、停止だけでは不十分)
3. **DNSレコードを退避または削除** — 同じドメインを再利用する場合、攻撃者がDNSキャッシュを利用して中間者攻撃を仕掛けるリスクを下げるため、TTLが切れるまで待つ
4. **新しいVPSをセットアップ** — マイスクリプトで**新しい** CLIENT_SECRET / CLIENT_ID / EMAIL を指定。古い値は二度と使わない
5. **同じドメインを再利用する場合**、新VPSのIPでDNSを再設定。Aレコードに加え、ns1のグルーレコードも更新が必要
6. **claude.aiコネクタを再登録** — 新しい認証情報で

## ファイル一覧

| ファイル | 説明 |
|---|---|
| `sakura-rocky9-root-dns.txt` | RockyLinux 9 用スタートアップスクリプト(BIND + MCP + Nginx + SSL・コメントなし) |
| `sakura-rocky9-root-dns-withcomment.txt` | 同上(コメントあり・参照・編集用) |

## セットアップ概要

スクリプトは以下を自動構築します:

1. swapfile (1GB)
2. Node.js 20 + MCPサーバー (express + @modelcontextprotocol/sdk)
3. BIND (プライマリDNS) + ゾーンファイル自動生成
4. Nginx (リバースプロキシ・SSE対応)
5. certbot (HTTP-01方式・Let's Encrypt SSL 自動取得・更新)
6. firewalld (ssh/http/https/udp53/tcp53/tcp3000)
7. dnf-automatic (セキュリティアップデート自動化)
8. fail2ban (SSH ブルートフォース対策)
9. 週次reboot (日曜3時・カーネル更新適用)

## OAuth2認証フロー

OAuth2 authorization_code フローに**形式上**従っていますが、実質的な認証は `/token` への `client_secret` 提示のみです(設計詳細は専門家向け補足を参照)。

```
1. GET /.well-known/oauth-authorization-server
   → claude.aiがエンドポイントを自動検出

2. GET /authorize
   → redirect_uri の host が "claude.ai" の場合のみ 302 リダイレクト、
     それ以外は 400(Open Redirect 対策)
   → code は固定値 "x" を返す(認可コードとしては機能しない、形式のみ)

3. POST /token { client_secret: "...", client_id: <数字>, code: "x", ... }
   → secretファイルと照合 → 一致しなければ 403
   → client_id を +v で数値化、0 または NaN なら 403
   → secretファイル削除
   → tokenファイル読み込み → hashファイル(sha256)書き込み → tokenファイル削除
   → token発行通知メール送信(タイトルにclient_id=<数字>を含む)
   → 5秒後にtoken返却(メール配送完了の確率を上げるため)
   → tokenは最初の1回のみ発行(secretファイル削除後は403)

4. GET /mcp/sse { Authorization: Bearer <token> }
   → tokenをsha256化してhashファイルとtimingSafeEqual比較
   → 一致すればSSE接続成功
```

## MCPツール

| ツール名 | 機能 |
|---|---|
| `exec_command` | VPS上でシェルコマンドを実行(root権限・30秒タイムアウト) |
| `nginx_reload` | Nginxをリロード(設定テスト後2秒後に実行・SSEセッション切断あり) |

## ゾーン転送について

さくらのセカンダリDNSからのゾーン転送元IPは固定です:

- allow-transfer: `210.188.224.9` / `210.224.172.13`
- also-notify: `61.211.236.1` (ns1.dns.ne.jp) / `133.167.21.1` (ns2.dns.ne.jp)

参考: [さくらのサポート - ゾーン情報を編集したい](https://help.sakura.ad.jp/domain/2302/)

## セキュリティ対応済み項目

| 項目 | 対応内容 |
|---|---|
| 認証方式 | OAuth2形式 (authorization_code フロー)、実質は client_secret の1回交換 |
| Open Redirect | `/authorize` の redirect_uri は host が `claude.ai` のもののみ許可 |
| token発行 | 初回のみ(secretファイル削除後は403) |
| token認証 | sha256ハッシュ比較・`crypto.timingSafeEqual` でタイミング攻撃対策 |
| token発行通知 | メール送信・タイトルにclient_idを含む(不審な接続を即座に検知可能) |
| token返却 | 5秒遅延(メール配送完了の確率を上げるため・タイミング攻撃対策ではない) |
| client_id サニタイズ | `+v` で数値化、0/NaN は403(spam分類トリガー文字列の混入防止) |
| `/token` のIPアドレス制限 | claude.aiのIPレンジ (160.79.104.0/21) のみ許可 |
| メール送信 | `spawn` の argv 配列形式でシェルインジェクション対策 |
| MCPログの標準出力 | Nginx access_log off (MCPパス) |
| IPv6 | OS側で完全無効化 (`disable_ipv6 = 1`) |
| SSHブルートフォース対策 | fail2ban (5回失敗で10分バン) |
| オープンリゾルバ | allow-recursion { 127.0.0.1; } |
| セキュリティ自動更新 | dnf-automatic (security only) |
| カーネル更新 | 週次reboot (日曜3時) |

---

# 専門家向け補足

## 1. 設計の本質: OAuth2のインターフェースを使った1回限りAPIキー発行システム

このサーバは「OAuth2 authorization_code + PKCE フロー」をメタデータで宣言していますが、**実質的にはOAuth2の認可フローを実装していません**。本質は以下です。

**実態**:

- ユーザーが事前に設定した `CLIENT_SECRET` を `/token` に提示
- 一致すれば 1回限り `access_token`(UUID)を返却
- 以後はそのtokenを `Authorization: Bearer` ヘッダで提示するAPIキー方式

**OAuth2要素が「形式だけ」になっている箇所**:

| 要素 | 形式上の宣言 | 実装 |
|---|---|---|
| `/authorize` | 認可エンドポイント | redirect_uri検証以外は素通り、`code=x` 固定 |
| 認可コード (code) | 一時的な認可証 | 値は無視される、`/token` で検証されない |
| PKCE (code_challenge) | クライアント認証強化 | メタデータに `S256` と宣言、実装なし |
| grant_type | フロー識別子 | `/token` で検証されない |
| token expiry | アクセス制御 | 無期限(永続) |
| refresh_token | token更新 | 未発行・未対応 |

**なぜこの形にしているのか**:

claude.aiコネクタはOAuth2インターフェースを期待します。そのため:

- メタデータエンドポイントを提供して「OAuth2サーバーである」と宣言する必要がある
- claude.aiが `/authorize` → `/token` の順でアクセスしてくる
- そのフローに表面的に従えば、claude.ai側は満足する

その上で、認可フローの内実は「secret提示」だけにして、複雑な状態管理(認可コード保存、PKCE検証、expiry管理、refresh処理)を捨てています。**SSH不要・状態最小・ロジック最小**というこのスクリプトの設計目標と一致しています。

正確に表現するなら:

> **OAuth2 client_credentials grant に最も近い動作を、authorization_code grant のインターフェースで実装したもの。** 認可コードは無意味、token はAPIキー、再発行はファイル操作で行う。

claude.aiが将来 `client_credentials` を直接サポートすれば、`/authorize` を削除してより単純化できます。

## 2. 検討した攻撃シナリオ

このスクリプトの設計過程で検討された攻撃シナリオと、その評価を記録します。

### 2.1 ステルス侵入シナリオ(中心的な脅威)

**攻撃**: secret を破った攻撃者が、正規ユーザーより先に `/token` を消費し、新しいsecret/tokenを書き戻し、さらにメール送信機能を一時的に潰すことで、正規ユーザーには侵入を気づかれずにroot権限を奪取する。

```
1. 攻撃者がCLIENT_SECRETを破る(辞書攻撃・推測・漏洩)
2. 攻撃者が /token を叩いてaccess_token_Aを取得
   → この時点でメール1通発火(攻撃者が指定したclient_id)
3. 攻撃者がexec_command経由でroot権限取得
4. 攻撃者が secret(同じ値)と新しいtoken_Bを書き戻す
5. 攻撃者がメール送信を機能的に無効化する:
   - 例: /opt/mcp-server/index.mjs のspawn行を1行コメントアウトしてサービス再起動(最速)
   - 例: /bin/mail を exit(0) だけのダミーバイナリで一時的に置換
   - 例: postfix のリレー設定を破壊
   - 例: spawn の対象パスを書き換える
6. 後から正規ユーザーが /token を叩く → token_B が返る
   → 本来ここでメールが発火するが、ステップ5の細工により送信されない
7. 攻撃者がメール送信機能を元に戻す(タイマー、ファイル監視、自分宛メールを仕込んで配信完了で検知、等)
8. 正規ユーザーは「1通だけメールを受け取った」状態になる
9. その1通の client_id が自分の想定値と一致すれば、ユーザーは正規通知と誤認
10. 攻撃者はステルスで永続化、ユーザーと同じtoken_Bでサーバ共有
```

**防御の最終防衛線**: メール1通の中の `client_id` 値を、攻撃者が事前に予測できないこと。

- 正規ユーザーは自分が設定した client_id を知っている
- 攻撃者は client_id を知らない(サーバ側にも保存されていない)
- 攻撃者がランダムな値で叩く → 通知メールに「見覚えのない client_id」が出る → 正規ユーザーが異常検知
- 攻撃者が「ユーザーが選びそうな値」を当てに行く → ユーザーが**ありきたりな値**を使っていれば的中の可能性

**従って、CLIENT_ID には攻撃者から推測困難な値を選ぶことが本質的に重要**。「2通来た」「自分が接続する前に来た」は追加の検知シグナルだが、攻撃者が ステップ5 のような細工で1通に絞ってきた場合、これらのシグナルは機能しない。`client_id` の推測困難性こそが最後の砦になる。

### 2.2 通知ブロック攻撃(深刻な副次脅威)

**攻撃**: 上記2.1の手順中、攻撃者が `client_id` フィールドを細工してメール送信を失敗させる。メールが届かなければステルス侵入が成立する。

検討された具体ベクタ:

| ベクタ | 結果 | 評価 |
|---|---|---|
| NUL バイト挿入 | Node.js の `spawn` が `ERR_INVALID_ARG_VALUE` で同期 throw | 通知ブロック&token発行も失敗(throw 経路では `setTimeout` 未登録、`r.json` 呼ばれず)→ DoS のみ |
| 1MB 超の巨大文字列 | `execve` の `ARG_MAX` 超過で `E2BIG` throw | 同上 |
| `{toString: 1}` 等オブジェクト | template literal の String 変換で throw | 同上 |
| spam語混入 (`VIAGRA` 等) | spamフィルタによる受信側分類 | **検知シグナル破壊**、ユーザーが見落とすリスク |
| CRLF (`\r\n`) でヘッダインジェクション | s-nail が NL/CR を自動除去 | 不成立 |
| 引数注入 (`--option` 風) | `spawn` の argv 配列形式により argv 境界が動かない | 不成立 |
| 長すぎる件名 | spamフィルタ反応、MUA truncate | **検知シグナル劣化** |

**防御**: `client_id` を `+v` で数値化、`!cid` で 403。数字のみに制限することで:

- spam語(英単語ベース)が件名に出ない
- 制御文字・NULバイトが排除される
- 件名長が自動的に短い(最大8桁)
- 数字のメール件名はspamフィルタが反応しない

throw 経路で「token発行されず通知も飛ばない」は「token発行されて通知が飛ばない」よりは安全なので許容(DoSのみで侵入は成立しない)。

### 2.3 Open Redirect 経由のフィッシング

**攻撃**: `/authorize` の `redirect_uri` を任意のサイトに指定して、claude.aiユーザーをフィッシングサイトに誘導。OAuthの慣例として `/authorize` URLは正規サイトと認識されるため、ユーザーが警戒しにくい。

**防御**: `new URL(redirect_uri).host !== "claude.ai"` で 400。

検証済みのバイパス試行(すべて失敗):

- `https://claude.ai@evil.com/` (userinfo) → host判定で evil.com 扱い → 400
- `https://claude.ai.evil.com/` (サブドメイン) → 400
- `https://evilclaude.ai/` (suffix) → 400
- `javascript:` / `data:` URL → 400
- 制御文字 (`\t`, `\r`, `\n`, `\0`) 挿入 → URL APIが除去後にhost判定 → 400
- IDN同形字 (`claude.ai。evil.com`) → 400

通る/グレーなケース(いずれも実害なし):

- `https://claude.ai\@evil.com/` → ブラウザがWHATWG準拠でパスとして解釈 → claude.ai 着地
- `http://claude.ai/cb` (httpダウングレード) → claude.ai に着地
- `ftp://` `gopher://` 等 → ブラウザが開かない

### 2.4 CTログ + claude.ai経由の大規模辞書攻撃

**攻撃**: 攻撃者が Certificate Transparency ログから `mcp.*` / `*-claude.*` 等のホストを抽出し、claude.aiでコネクタ登録試行を自動化する。`/token` のnginx ACL `allow 160.79.104.0/21` はAnthropicレンジ全体を許可しているので、claude.ai経由の攻撃は素通りする。

**評価**:

- secret強度が弱い場合は成立する(短い secret、辞書語、サンプル値コピペ)
- 母数が必要(ニッチな状態では攻撃の経済性が立たない)
- 普及した場合は、claude.aiが標準SSHコネクタを実装する可能性が高い(歴史的に、ある機能の需要が高まれば他社追随)
- SSH標準化後は新規ユーザーは標準SSHを使うため、このスクリプトの攻撃面が縮小
- 既存ユーザーは randomUUID() 由来の122bit token で安全に運用継続可能

**防御**:

- CLIENT_SECRET の十分な強度(12文字以上ランダム、ドキュメントのサンプル値をそのまま使わない)
- CLIENT_ID の十分な強度(6〜8桁数字、誕生日・電話番号・連続数字を避ける)
- メール通知ループによる検知 → 攻撃成立しても1台ごとに発見・廃棄され、攻撃の経済性が悪化

### 2.5 IPv6 経由でのACLすり抜け

**攻撃**: `/token` の nginx ACL は IPv4 CIDR `allow 160.79.104.0/21` のみで、IPv6送信元への許可ルールがない。IPv6経路があれば「allowに該当しない=暗黙deny」ではなく「明示的にallow→順次評価→deny all」となるが、nginxの`allow/deny`は IPv4 allow ルールにIPv6送信元はマッチしないため、結果として `deny all` で蹴られる。

**評価**:

- OS側で `disable_ipv6 = 1` のためカーネルがIPv6を処理しない(第一防御)
- nginx の 443 listen は IPv4 のみ(`listen 443 ssl;`、`listen [::]:443` なし)(第二防御)
- nginx の `allow 160.79.104.0/21; deny all;` は IPv6 送信元を `deny all` で蹴る(第三防御)
- DNS AAAA レコードなし(クライアントが IPv6 解決しない)(第四防御)

**現状すり抜けは発生しない**。ただし将来 IPv6 を有効化する運用変更時には注意:

- mcp.conf に `listen [::]:443 ssl;` を追加すると、Anthropic の IPv6 からの正規通信もACLで蹴られる(可用性問題)
- 攻撃面ではなく可用性側に作用するため、安全側の挙動

### 2.6 mail プロセス kill によるレース攻撃

**攻撃**: 攻撃者が `/token` で access_token を受け取った瞬間に root 権限で `mail` プロセスや postfix を kill し、ローカルキューに残っている通知メールを削除する。

**評価**:

- 5秒の `setTimeout` の間に、s-nail はpostfixに引き渡し → postfix が外部リレー(さくらSMTPサーバ)に転送 → さくらSMTPがキューに保持
- 実測値: ローカル postfix → 外部リレーまで 0.13〜0.64秒(過去ログ)
- 5秒は外部リレーへの引き渡し完了に十分なマージン
- 攻撃者が `access_token` を受け取った時点では、メールは既にさくらSMTPサーバ上にあり、攻撃者の手の届かない別ホストにある
- サーバ側の postfix を破壊しても通知は止められない

**防御は機能している**。

### 2.7 client_id 偽装による検知逃れ

**攻撃**: 攻撃者が `client_id` フィールドに正規ユーザーの値(に似たもの)を入れて、通知メールを「自分の操作だ」と誤認させる。

**評価**:

- CLIENT_ID は**サーバ側に保存されていない**(`/token` ハンドラがエコーバックするのみ)
- 攻撃者はサーバを覗いても CLIENT_ID を取得できない
- 正規ユーザーがランダムな6〜8桁数字を使う限り、攻撃者の推測成功確率は10⁻⁶〜10⁻⁸
- 「6〜8桁数字」という制約だけは公知なので、攻撃者の探索空間は 10⁸ 通り

**防御は CLIENT_ID の選び方に依存**:

- 推奨: `node -e "console.log(require('crypto').randomInt(10000000, 100000000))"` 等で8桁ランダム生成
- 非推奨:
  - **今日の日付**(`20260524` 等): 攻撃者がユーザーの想定値を予想する際の最有力候補。ステルス侵入を狙う攻撃者は `client_id` をユーザーが見て自然な値に設定するため、日付は真っ先に試される
  - 誕生日(8桁、推測可能)
  - 電話番号下8桁(辞書化されている)
  - 連続数字(`12345678`)、ゾロ目(`88888888`)
  - 過去のサーバ構築で使った値(履歴漏洩リスク)

### 2.8 設定値・hash 漏洩によるtoken 取得可能性

**攻撃**: CLIENT_SECRET がセットアップスクリプトのテンプレート展開後に `/root/.sakuravps/<host>.sh` に平文で残る。また、`/etc/mcp-server/hash` に token の sha256 ハッシュが保存される。これらが何らかの経路で漏洩した場合、access_token を取得できるか。

**評価**: いずれの経路でも **access_token そのものは漏洩しない**。

- **スクリプト平文の CLIENT_SECRET**: token はセットアップ時に `randomUUID()` で動的生成され、スクリプトには含まれない。CLIENT_SECRET が漏れても、既に `/token` が消費済みであれば再発行できない(secretファイル既に削除済み)。再発行運用をしていない限り、CLIENT_SECRET 単体では access_token を取得できない
- **`/etc/mcp-server/hash`**: sha256 ハッシュなので、token の逆算は事実上不可能(2^256 通り)。hash があっても認証は通せない(`/mcp/sse` は `sha256(提示されたtoken)` と hash の比較なので、token そのものが必要)
- **VPS が侵害された場合**: 攻撃者は既に root 権限を持っているため、新しい secret/token を書き戻して任意の値を access_token として発行できる。この経路は侵害後の話なので「漏洩によるtoken 取得」とは別問題

**現状実害なし**。スクリプトの平文 CLIENT_SECRET は、再セットアップ時に新規生成すれば回避できる(古い値を使い回さない運用)。

### 2.9 メタデータエンドポイントの Host ヘッダインジェクション

**攻撃**: `/.well-known/oauth-authorization-server` がレスポンスの `issuer` / `authorization_endpoint` / `token_endpoint` を `X-Forwarded-Host` / `X-Forwarded-Proto` から組み立てる。攻撃者が偽装ヘッダを送れば、claude.ai を攻撃者制御のエンドポイントに誘導できる可能性。

**評価**:

- nginx 設定で `proxy_set_header X-Forwarded-Host $host;` `proxy_set_header X-Forwarded-Proto $scheme;` が `/.well-known/oauth-authorization-server` ロケーションに**明示的に設定されている**
- nginx の `proxy_set_header` は同名ヘッダがクライアントから来ても上書きする
- → クライアント由来の偽装ヘッダはバックエンドに到達しない

**防御は機能している**。注意点として、もし nginx 設定変更時にこれらの `proxy_set_header` を削除すると、Express の `req.headers["x-forwarded-host"]` がクライアント由来になりインジェクション成立する。

## 3. CLIENT_ID の性質: サーバも攻撃者も知らない秘密

CLIENT_ID は OAuth2 の慣例では「公開識別子」ですが、このシステムでは**秘密の合言葉**として再定義されています。

**従来のOAuth2 client_id**:

- 認可サーバに事前登録された識別子
- 公開情報として扱われる
- 主にロギング・利用統計目的

**このシステムでの client_id**:

- サーバ側には事前登録されない(`/etc/mcp-server/` に保存されない)
- ユーザーが Claude.ai コネクタに入力した値が、`/token` リクエストでサーバに届く
- サーバはその値をメール件名にエコーバックするのみ
- 正規ユーザー(設定者)と Claude.ai だけが知る情報

**閉ループ自己同定マーカー**:

```
[ユーザー] → 設定 → [Claude.aiコネクタ]
                       ↓ /token { client_id: <X> }
                    [MCPサーバ] (Xを保存せずエコーバック)
                       ↓ mail Subject: client_id=<X>
                    [ユーザーのメール] ← 受信
                       ↓ 目視照合
                    [正規ユーザー] (自分が設定した X と一致するか確認)
```

**攻撃者が知らない**:

- サーバには保存されないので、サーバを覗いても CLIENT_ID は取得できない
- ネットワーク上では Claude.ai → MCPサーバ の HTTPS 内に閉じている
- CLIENT_SECRET を破った攻撃者でも、CLIENT_ID は別途推測する必要がある

**この性質から導かれる運用上の指針**:

- CLIENT_ID を「メモしておく」必要がある(忘れたら検知できない)
- CLIENT_ID を「サーバ上のファイルに保存しない」(漏洩経路を作らない)
- CLIENT_ID を「ブログ・チャットで例示しない」(辞書攻撃の材料を増やさない)
- CLIENT_ID を「複数のサーバで使い回さない」(1台漏洩で全台波及)

## 4. 設計の時限性: SSH標準コネクタとの関係

このスクリプトは「**SSH標準コネクタが普及するまでの繋ぎ**」として位置付けています。

**前提となる業界予測**:

1. このスクリプトが普及する = 「Claude から VPS をリモート制御したい」ニーズが顕在化
2. ニーズが顕在化すれば、Anthropic または競合がSSHコネクタを標準実装する経済合理性が生まれる
3. 競争圧力(MCP, function calling, vision, computer use 等の歴史的パターン)で各社追随
4. VPS 側には SSH 公開鍵設定の仕組みが既存
5. 標準化後は新規ユーザーは標準SSHコネクタを使う

**「攻撃価値」と「標準化トリガー」が同じイベント(=普及)で発火する**ため、「大規模攻撃が経済的に成立するフェーズ」と「このスクリプトが代替される」がほぼ同期します。攻撃者にとっての「狙い時」が極めて短いか存在しないと評価しています。

**残存リスク**: 普及〜SSH標準化の間に1〜2年のギャップが生まれた場合、その期間は機会主義的な攻撃の対象になりうる。**この期間こそ、CLIENT_SECRET / CLIENT_ID の強度とメール通知ループの完全性が決定的に重要**。

## 5. 既存ユーザーの長期運用安全性

SSH 標準コネクタが普及した後も、既存ユーザーは何も変更せずに継続運用できます。

**継続安全性の根拠**:

| 要素 | 状態 |
|---|---|
| Bearer token認証 | `randomUUID()` 由来の122bit、総当たり 2^122 ≈ 5×10^36 通りで事実上不可能 |
| token 比較 | `crypto.timingSafeEqual` で定数時間 |
| HTTPS 証明書 | certbot による自動更新(90日ごと) |
| OS パッケージ | dnf-automatic (security) で自動更新 |
| カーネル | 週次 reboot で更新適用 |
| `/token` エンドポイント | 既に secret/token 消費済みで攻撃面なし |
| nginx ACL (Anthropic IP) | `/token` のみに適用、`/mcp/sse` には ACL なし(token認証で保護) |

**注意すべき外部要因**:

- Anthropic IPレンジの変更: 現在 `160.79.104.0/21` だが、Anthropicが拡張した場合は `/token` ACL を手動更新が必要。ただし `/token` は既に消費済みなので、再発行運用をする時のみ問題になる
- MCP プロトコル仕様変更: SDK バージョン更新で互換性が崩れる可能性。`npm install` の固定版でしのげる
- claude.ai 側の SSE 仕様変更: 接続切断が増える等の問題が発生しうる

**ベース実装が極めてシンプル**(Express + SSE + Bearer auth)なので、breaking change の影響を受けにくい設計です。

## 6. スクリプト改変時の注意点

このスクリプトを改変・フォークする場合の注意。

### 6.1 メール送信経路を変える場合(Slack通知等)

`spawn("mail", [...])` を `spawn("curl", [...])` 等に置き換える場合、以下に注意:

- 通知失敗時の挙動: 現在の設計では `mail` の exit code は無視され、5秒 setTimeout の後に token を返す。これは「攻撃者が通知を妨害するシグナルを攻撃者にリークしない」ための意図的な無視
- ただし副作用として、攻撃者が root を取得した後に `/bin/mail` を `exit(0)` のダミーバイナリで置換するなどして、後続のtoken発行時のメール送信を無効化できる(2.1 ステップ5参照)。元に戻すトリガーは、タイマー・ファイル監視・自分宛メールの配信完了検知など複数の選択肢がある。**サーバ側からはこの種の攻撃は検知できない**ので、ユーザー側の `client_id` 推測困難性が最終防衛線となる
- 通知遅延: 5秒は外部SMTPまでの引き渡し完了に十分な時間として設定。Slack Webhook 等を使う場合、エンドツーエンドのレイテンシが変わるので調整が必要
- `client_id` のサニタイズ: 通知先のメッセージング仕様によって sanitize ルールを変える必要(Slackなら `<` `>` `&` を escape、メールならspam語回避)

### 6.2 5秒遅延を変える場合

- 短くする(例: 1秒): 外部SMTPまでの引き渡しが完了しないリスク。攻撃者が token 取得直後に postfix を破壊した場合、通知が届かない可能性が高まる
- 長くする(例: 30秒): claude.ai 側のタイムアウト(通常30〜60秒)に抵触するリスク

設計値の5秒は「外部SMTP引き渡しに必要な時間(実測 0.13〜0.64秒)+ 安全マージン」として決定されています。

### 6.3 IP ACL レンジ更新

Anthropic が将来 IP レンジを拡張・変更した場合:

```nginx
# /etc/nginx/conf.d/mcp.conf
location /token {
    allow 160.79.104.0/21;       # 旧
    allow <新レンジ>;             # 追加
    deny all;
    proxy_pass http://127.0.0.1:3000/token;
}
```

最新 IP レンジは https://platform.claude.com/docs/en/api/ip-addresses で確認可能。

### 6.4 client_id サニタイズを変える場合

`+v` + `!cid` 判定は「数字のみ受理」と「throw 経路で token 発行も止まる」の両方を担保しています。これを緩める場合:

- 文字列を受理する → spam フィルタリスク復活
- `String()` 経由にする → `{toString: 1}` で throw する経路が復活、ただし throw 経路では token 発行されないため要件上は許容

`String()` の throw を吸収するなら、`typeof q.body.client_id === "string"` での事前判定が最も安全。

### 6.5 exec_command のタイムアウト変更

現在 30秒。長時間タスク(`apt upgrade` 等)を実行する場合は延長が必要。ただし claude.ai 側のSSE タイムアウト(60秒程度)を超えると応答が返らないため、`nohup ... &` でバックグラウンド化する運用が推奨。

## 7. トラブルシューティング: ログの所在

何か異常を感じた時に確認するログ。

| ログ | パス | 内容 |
|---|---|---|
| MCP セットアップログ | `/var/log/mcp-startup.log` | 初回起動時の構築ログ |
| MCP サーバログ | `/var/log/mcp-server.log` | Node.js の stdout/stderr |
| MCP systemd ログ | `journalctl -u mcp-server` | サービス再起動・クラッシュ |
| nginx access | `/var/log/nginx/access.log` | (MCPパスは access_log off なので /token 等のみ) |
| nginx error | `/var/log/nginx/error.log` | proxy エラー・SSL 問題 |
| postfix | `journalctl -u postfix` | メール送信成否・キュー状態 |
| postfix queue | `mailq` | 配送待ちメール |
| fail2ban | `journalctl -u fail2ban` | SSH ブルートフォース検知・バン記録 |
| 認証 (sshd 等) | `journalctl _COMM=sshd` | SSH ログイン履歴 |
| BIND | `journalctl -u named` | DNS クエリ・ゾーン転送 |
| certbot | `/var/log/letsencrypt/letsencrypt.log` | 証明書取得・更新 |

**異常検知時に最初に見るべきもの**:

1. `/var/log/nginx/access.log` で `/token` への接続元IPと時刻を確認
2. `journalctl -u postfix` でメール送信成否を確認
3. `/var/log/mcp-server.log` で /token ハンドラの実行記録(現状ではログ出力なしのため、変更必要なら追加)
4. `ls -la /etc/mcp-server/` で secret/token/hash の状態確認

## 8. Anthropic IPレンジ更新への対応

`/token` の nginx ACL は claude.ai の API IP レンジに依存しています。

**現状**: `160.79.104.0/21`

**確認方法**:

1. https://platform.claude.com/docs/en/api/ip-addresses を定期確認(年1回程度)
2. claude.ai のコネクタが突然 `/token` で 403 を返すようになったら、IP レンジ変更を疑う

**更新手順**:

```bash
# nginx 設定を編集
vi /etc/nginx/conf.d/mcp.conf
# location /token { ... } 内の allow 行を更新

# 設定テスト
nginx -t

# リロード(MCP経由なら nginx_reload ツールを使う)
systemctl reload nginx
```

**更新が必要になるシナリオ**:

- 既に消費済みの `/token` には影響しない(セットアップ時に1回交換するだけ)
- 新規セットアップ時、または `/token` 再発行運用をする時に必要
- 既存ユーザーが `/mcp/sse` で運用継続する分には影響しない(別の location で ACL なし)

## 9. tokenの再発行・リセット運用

> **警告**: 以下の操作に失敗すると、MCP接続ができなくなり、データを初期化してのOS再インストールが必要になる場合があります。内容を十分に理解した上でご利用ください。
>
> 特に `/etc/mcp-server/` の secret/token/hash の状態は `/token` ハンドラの動作と密に結合しており、中途半端な状態(例: secret は再作成したが hash と整合しない token を置いた)になると、以降すべての `/token` リクエストで 403 が返り、`/mcp/sse` も認証失敗で 401 になります。SSH 公開鍵を設定していない場合、リカバリ手段が OS 再インストールのみとなります。

### 9.1 経路A: MCP経由のブートストラップ(SSH不要・設計と整合)

既に1台目のClaude.aiアカウントで接続済みのMCP接続から、新しいsecret/tokenを設置して2台目以降を接続する手順。**自分のClaude.aiコネクタが既に動いている前提**です。

```
1. 既存のMCP接続から exec_command で新しいsecret/tokenを設置:

   NEW_SECRET="<2台目用のCLIENT_SECRET>"
   NEW_TOKEN=$(node -e "console.log(require('crypto').randomUUID())")
   echo "$NEW_SECRET" > /etc/mcp-server/secret
   echo "$NEW_TOKEN" > /etc/mcp-server/token
   chmod 600 /etc/mcp-server/secret /etc/mcp-server/token

2. 2台目のClaude.aiコネクタを登録(client_idは新規の6〜8桁数字):

   URL:           https://<DOMAIN>/mcp/sse
   client_id:     <2台目用の数字>
   client_secret: <NEW_SECRETに設定した値>

3. 2台目が接続すると、$NEW_TOKEN が access_token として発行され、
   hash が上書きされる。既存(1台目)のtokenは無効化される。

4. 1台目を再接続したい場合、同じ手順を1台目に対して繰り返す。
   この「片方が接続するたびに他方が無効化される」性質を利用して、
   実質的には「都度認証」運用になる。
```

`exec_command` 自体が root シェルなので、この経路は SSH の代替として機能します。SSH秘密鍵を共有せずに済むメリットがあります。

### 9.2 経路B: 攻撃シナリオを利用した token 共有

攻撃シナリオ 2.1「ステルス侵入」の手順を、正規ユーザーが意図的に踏むことで複数Claude.aiアカウントから**同じtokenを共有**するMCPサーバを構築できます。

```
1. 経路Aで、初回接続前に secret と任意の token 値を設置
2. 1台目のClaude.aiから接続 → 設置した token が access_token として発行される
3. 1台目接続のMCP内から、再度同じ secret/token を設置(自分自身に対するステルス再発行)
   echo "<同じCLIENT_SECRET>" > /etc/mcp-server/secret
   echo "<同じtoken値>" > /etc/mcp-server/token
   chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
4. 2台目のClaude.aiから同じ client_secret で接続
5. 結果: 両アカウントが同じtokenを共有 (hashも同一・両方が並行接続可能)
```

この運用は「正規ユーザーが自分自身に対してステルス侵入攻撃を実行する」のと技術的に同じです。複数台運用したい場合の正規手段として位置付けています。

### 9.3 経路C: SSH経由(従来型・SSH鍵設定済みなら使用可)

さくらVPS管理画面でSSH公開鍵を設定済みの場合、SSHで入って同じ操作ができます。

```bash
ssh root@<DOMAIN>
NEW_SECRET="<新しいCLIENT_SECRET>"
NEW_TOKEN=$(node -e "console.log(require('crypto').randomUUID())")
echo "$NEW_SECRET" > /etc/mcp-server/secret
echo "$NEW_TOKEN" > /etc/mcp-server/token
chmod 600 /etc/mcp-server/secret /etc/mcp-server/token
```

### 9.4 tokenのリセット(即時アクセス不可化)

```bash
rm /etc/mcp-server/hash
# 次のリクエストから 401 を返す
# 再接続には経路A/B/Cの手順を実行
```

`hash` ファイルが認証の根拠なので、これを消すと既存のBearer tokenはすべて無効化されます。
