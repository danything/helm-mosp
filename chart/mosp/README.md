# mosp Helm chart

[MosP勤怠管理](https://github.com/es-mind/MosP) をTomcat + PostgreSQLでKubernetes上に動かすためのHelm chartです。[danything/k3s-mosp](https://github.com/danything/k3s-mosp) が実際にビルドしているイメージ(`ghcr.io/danything/mosp`)をデフォルトで使用します。

## インストール

```sh
helm install mosp ./chart/mosp \
  --namespace mosp --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=kintai.example.com \
  --set persistence.storageClassName=<自分のStorageClass>
```

Ingressを使わない場合は `kubectl port-forward` や `NodePort`/`LoadBalancer` のServiceを別途用意してアクセスしてください。

初回アクセス時、MosP自体のブラウザ上の初期セットアップウィザードでDB作成・最初の管理者ユーザー作成を行います(このchartはDBスキーマの初期化は行いません)。手順は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

## values

| キー | デフォルト | 説明 |
|---|---|---|
| `image.repository` | `ghcr.io/danything/mosp` | MosPイメージ |
| `image.tag` | `latest` | イメージタグ |
| `timezone` | `Asia/Tokyo` | 各コンテナの `TZ` |
| `service.port` | `8080` | mosp Serviceの公開ポート |
| `postgresql.image.repository` / `.tag` | `postgres` / `13` | MosPの[推奨環境](https://www.e-s-mind.com/environment/)に合わせてPostgreSQL 13系を既定にしている |
| `postgresql.user` | `mosp` | DBユーザー名 |
| `postgresql.database` | `mospv4` | DB名 |
| `postgresql.existingSecret` | `""` | 空ならchartがパスワードを自動生成してSecretを作成(`helm upgrade`時も既存値を維持)。既存Secretを使う場合はここに名前を指定 |
| `postgresql.existingSecretKey` | `db-password` | 上記Secretのキー名 |
| `persistence.storageClassName` | `""` | 空ならクラスタのデフォルトStorageClassを使用 |
| `persistence.db.size` | `5Gi` | DB用PVCサイズ |
| `persistence.logs.enabled` | `true` | MosPのログ(`webapps/ROOT/logs`)を永続化するか |
| `persistence.logs.size` | `1Gi` | ログ用PVCサイズ |
| `resources` | `{}` | 両コンテナ共通のresources |
| `extraEnv` | `[]` | mospコンテナへの追加環境変数 |
| `ingress.enabled` | `false` | Traefik `IngressRoute` を作るか |
| `ingress.host` | `mosp.example.com` | 公開ホスト名 |
| `ingress.entryPoints` | `[websecure]` | Traefikのentrypoint |
| `ingress.certResolver` | `""` | 空ならtlsブロックを出力しない |
| `ingress.middlewares` | `[]` | 例: `[{name: forward-auth, namespace: auth}]` |

## 制約

- `ingress.*` はTraefikの `IngressRoute` CRD専用。NGINX Ingress等を使う場合は `templates/ingress.yaml` を書き換えてください。
- ArgoCDでの運用を想定し、PVCには `argocd.argoproj.io/sync-options: Prune=false,Delete=false` を付与しています(Application削除時にデータが消えないように)。
