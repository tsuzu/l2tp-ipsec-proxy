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

# IPSec の右側ID（オプション、デフォルトは%any）
RIGHTID=your.vpn.server.id

# PPP MTU/MRU（オプション、デフォルトは1410）
MTU=1410
MRU=1410

# gostプロキシポート（オプション、デフォルト: HTTP=8080, SOCKS=1080）
GOST_HTTP_PORT=8080
GOST_SOCKS_PORT=1080

# VPNをバイパスするCIDR（オプション、カンマ区切り）
# これらのネットワークは元のゲートウェイ経由でルーティングされます
BYPASS_CIDRS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# デバッグログ出力（オプション、デフォルト: false）
# "true" に設定すると詳細なデバッグログを有効化
DEBUG_LOGS=false
```

## プロキシサーバー (go-gost)

このコンテナには go-gost プロキシサーバーが含まれており、VPN経由でプロキシアクセスを提供します。

### プロキシの使用方法

HTTP プロキシ設定:
```
http_proxy=http://localhost:8080
https_proxy=http://localhost:8080
```

SOCKS5 プロキシ設定:
```
socks5://localhost:1080
```

### バイパスルーティング

`BYPASS_CIDRS` で指定されたネットワークはVPNをバイパスして、元のネットワーク経由でアクセスされます。これは以下のような場合に便利です：

- ローカルネットワークへのアクセス (192.168.0.0/16)
- 社内ネットワークへのアクセス (10.0.0.0/8)
- VPN経由にしたくない特定のネットワーク

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

### 速度が遅い場合（数十kbps程度）

パケット断片化が原因の可能性があります。以下を試してください：

1. **MTU/MRUを下げる**:
   ```bash
   # vpn.envで以下の値を試す
   MTU=1280
   MRU=1280
   ```

   段階的に試す推奨値：1400 → 1350 → 1280 → 1200

2. **診断コマンド**:
   ```bash
   # 現在のMTU確認
   docker-compose exec vpn-client ip link show ppp0

   # パケットロステスト（大きいパケット）
   docker-compose exec vpn-client ping -c 10 -s 1400 8.8.8.8

   # パケットロステスト（小さいパケット）
   docker-compose exec vpn-client ping -c 10 -s 1200 8.8.8.8
   ```

3. **MSS clamping（自動設定済み）**:
   connect.shで自動的にTCP MSSが調整されます。これによりTCP接続での断片化が防止されます。

4. **xl2tpdログの確認**:
   ```bash
   docker-compose exec vpn-client cat /var/log/xl2tpd.log | tail -50
   ```

   `recv packet from ... size = 64` のような小さいパケットサイズが頻出する場合、MTUを下げてください。

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
