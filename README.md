# L2TP over IPSec VPN Client (Docker)

DockerコンテナでL2TP over IPSec VPNクライアントを実行します。

## 機能

- IPSec (strongSwan) による暗号化トンネル
- L2TP (xl2tpd) によるトンネリング
- PSK (Pre-Shared Key) 認証
- ユーザー名/パスワード認証
- IPSec rightid の明示的指定が可能

## 環境変数

`../vpn.env` ファイルに以下の環境変数を設定してください：

```bash
# VPNサーバーのIPアドレス（必須）
VPN_SERVER_IP=your.vpn.server.ip

# IPSec Pre-Shared Key（必須）
PSK=your_psk_key

# L2TP ユーザー名（必須）
USER=your_username

# L2TP パスワード（必須）
PASS=your_password

# IPSec の右側ID（オプション、デフォルトはVPN_SERVER_IP）
RIGHTID=your.vpn.server.id

# PPP MTU/MRU（オプション、デフォルトは1410）
MTU=1410
MRU=1410
```

## 使用方法

### Docker Composeを使用する場合（推奨）

```bash
# コンテナをビルドして起動
docker-compose up -d

# ログを確認
docker-compose logs -f

# 接続状態を確認
docker-compose exec vpn-client ip addr show ppp0

# 停止
docker-compose down
```

### Dockerコマンドを使用する場合

```bash
# イメージをビルド
docker build -t l2tp-ipsec-vpn .

# コンテナを起動
docker run -d \
  --name l2tp-ipsec-vpn \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --device=/dev/ppp \
  --privileged \
  --env-file ../vpn.env \
  -v /lib/modules:/lib/modules:ro \
  l2tp-ipsec-vpn

# ログを確認
docker logs -f l2tp-ipsec-vpn

# 停止
docker stop l2tp-ipsec-vpn
docker rm l2tp-ipsec-vpn
```

## トラブルシューティング

### 接続が確立されない場合

1. ログを確認：
```bash
docker-compose logs -f
```

2. IPSec接続状態を確認：
```bash
docker-compose exec vpn-client ipsec status
```

3. xl2tpdログを確認：
```bash
docker-compose exec vpn-client cat /var/log/xl2tpd.log
```

### よくある問題

- **`/dev/ppp` が見つからない**: ホストシステムで `modprobe ppp_generic` を実行してください
- **権限エラー**: `privileged: true` と適切なケーパビリティが設定されているか確認してください
- **IPSec接続タイムアウト**: `RIGHTID` の値を確認してください（VPNサーバーの証明書のCNやサーバー設定によって異なる場合があります）

## セキュリティ上の注意

- `vpn.env` ファイルには機密情報が含まれるため、適切に管理してください
- ファイルのパーミッションを制限することを推奨します：`chmod 600 ../vpn.env`
- Gitリポジトリにコミットする場合は `.gitignore` に追加してください

## 必要な権限

このコンテナは以下の権限が必要です：

- `NET_ADMIN`: ネットワークインターフェースの管理
- `NET_RAW`: RAWソケットの使用
- `privileged`: IPSecとPPPの完全な機能を使用するため
- `/dev/ppp`: PPPデバイスへのアクセス

## ファイル構成

```
.
├── Dockerfile                      # コンテナイメージ定義
├── docker-compose.yml              # Docker Compose設定
├── connect.sh                      # VPN接続スクリプト
├── ipsec.conf.template             # IPSec設定テンプレート
├── ipsec.secrets.template          # IPSec秘密鍵テンプレート
├── xl2tpd.conf.template            # xl2tpd設定テンプレート
├── options.l2tpd.client.template   # PPPオプションテンプレート
└── README.md                       # このファイル
```
