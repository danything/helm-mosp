# k3s-mosp

[MosP勤怠管理](https://github.com/es-mind/MosP) の最新コードを定期的に取得し、Dockerイメージとしてビルドして GitHub Container Registry (GHCR) にpushするための構成です。

## 構成

- [`Dockerfile`](Dockerfile) — [es-mind/MosP](https://github.com/es-mind/MosP) のソースを取得し、Tomcat 9 (OpenJDK 17) 上で動作するイメージをビルドします。
- [`docker-entrypoint.sh`](docker-entrypoint.sh) — 起動時に環境変数 (`MOSP_DB_URL` / `MOSP_DB_USER` / `MOSP_DB_PASSWORD` / `MOSP_DB_DRIVER`) からDB接続設定を反映します。
- [`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml) — 毎月1日03:00 JSTにMosPの最新コミットを確認し、未ビルドであればイメージをビルドして `ghcr.io/<owner>/mosp` にpush、`k3s/deployment.yaml` のimageタグを新しいコミットSHAに書き換えてpushします(ArgoCDが検知して自動デプロイする想定)。
- [`k3s/`](k3s/) — [danything/k3s-mirakurun-epgstation](https://github.com/danything/k3s-mirakurun-epgstation) と同じ構成のk3sマニフェスト一式(下記参照)。

## イメージの使い方

```sh
docker run -d -p 8080:8080 \
  -e MOSP_DB_URL="jdbc:postgresql://<db-host>:5432/mospv4" \
  -e MOSP_DB_USER="usermosp" \
  -e MOSP_DB_PASSWORD="passmosp" \
  ghcr.io/<owner>/mosp:latest
```

## k3sクラスタ側の前提条件

[danything/k3s-mirakurun-epgstation](https://github.com/danything/k3s-mirakurun-epgstation) と同じ運用を前提にしており、`k3s/` には `mosp` namespace内のマニフェストしか含まれていません。適用前にクラスタ側に以下が用意されている必要があります。

- **StorageClass `local-path-retain`**: `k3s/pvc.yaml` の全PVCが参照。`reclaimPolicy: Retain` の local-path プロビジョナー。
- **`auth` namespaceとTraefik Middleware**: `k3s/ingress.yaml` が参照する `forward-auth`(OIDCによるログイン要求)Middlewareが `auth` namespaceに必要。MosPアプリ自体にもログイン機能はありますが、外部公開する`mp.doany.io`側はforward-authによる二重防御にしています。
- **Traefik のCRD/証明書設定**: `mydnschallenge` certResolver(Cloudflare DNS-01でのワイルドカード証明書取得)、および `providers.kubernetesCRD.allowCrossNamespace: true`(namespaceをまたいだMiddleware参照を許可)が有効になっていること。
- **Sealed Secrets controller**: `kube-system` namespaceの `sealed-secrets-controller`。`k3s/sealed-secret.yaml` は生成済み(`bootstrap/kubeseal.sh`でランダムパスワードをsealしたもの)。パスワードを再発行したい場合は、bootstrapリポジトリのホストで以下を実行して作り直してください。

  ```sh
  kubectl create secret generic mosp-secrets \
    --namespace mosp \
    --from-literal=db-password="$(openssl rand -base64 24)" \
    --dry-run=client -o yaml > /tmp/mosp-secrets.yaml
  ~/bootstrap/kubeseal.sh /tmp/mosp-secrets.yaml
  rm /tmp/mosp-secrets.yaml
  # 出力された mosp-secrets-sealed.yaml の中身で k3s/sealed-secret.yaml を上書き
  ```

- **ArgoCD**: ArgoCD Application自体はこのリポジトリにもbootstrap側にもマニフェストとして存在しない前提です。
- **DNS**: `mp.doany.io` がTraefikの外部IPを指すこと。
- **GHCRイメージの公開設定**: `ghcr.io/danything/mosp` をpullできること(imagePullSecrets未設定のためpublicパッケージである前提。設定済み)。

### 初回のDBセットアップ

MosPにはブラウザから使える初期セットアップウィザード(DB作成・初期管理者ユーザー作成)が組み込まれているため、`sql/*.sql` を手動で流し込む必要はありません。`db`・`mosp` の両Podが起動したら、アプリにアクセスして初期セットアップ画面の案内に従ってください。手順の詳細は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

## ライセンス

- 本リポジトリ（Dockerfile・GitHub Actionsワークフロー・entrypointスクリプト）は [GNU Affero General Public License v3.0 (AGPL-3.0-or-later)](LICENSE) の下で提供します。
- ビルドされるDockerイメージには [MosP勤怠管理](https://github.com/es-mind/MosP)（Copyright (C) esMind, LLC、同じく AGPL-3.0-or-later）のコンパイル済みコードが含まれます。MosP自体のライセンス条項は [es-mind/MosP の LICENSE](https://github.com/es-mind/MosP/blob/master/LICENSE) を参照してください。
- AGPLv3は、ネットワーク経由でプログラムを利用させる場合にも対応するソースコードの入手手段を利用者に提供することを求めます（第13条）。本イメージがビルドされたMosPのコミットSHAは、イメージ内の `COMMIT_SHA` ファイル、およびGitHub Actionsが払い出すイメージタグ（コミットSHAの先頭12桁）から追跡できます。
