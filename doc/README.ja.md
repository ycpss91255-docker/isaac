# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開発環境。[`ycpss91255-docker/template`](https://github.com/ycpss91255-docker/template) をベースに構築。

イメージのスコープは Isaac Sim 本体のみ。ROS 2 bridge、下流アプリケーション、その他の重ね合わせツールは隣接する docker folder（例：`isaac-ros/`）に配置。

## 前提条件

- NVIDIA driver `>= 580.65.06`（Isaac Sim 5.1 の最低要件）
- GPU `>= RTX 4080`（または同等）、VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- NGC イメージ用に約 20 GB の空き領域；初回起動後にキャッシュがさらに 5–10 GB 増加

NGC イメージ（`nvcr.io/nvidia/isaac-sim:5.1.0`）は公開取得可能、`docker login nvcr.io` 不要。

## Quick Start

> **初回のみ必須：** `./build.sh` の **前に** `./script/init_isaac_dirs.sh` を実行。スキップすると docker daemon が **root** 権限で cache mount ポイントを mkdir し、コンテナ内の非 root ユーザーが書き込めず、Isaac Sim が起動できません。

```bash
./script/init_isaac_dirs.sh   # 初回のみ — host 所有の cache ディレクトリ 8 個を作成
./build.sh                    # devel stage を build（約 16 GB のイメージ）
./run.sh                      # devel コンテナで対話シェル
```

コンテナ内：

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — Isaac Sim WebRTC Streaming Client で接続（下記参照）
/isaac-sim/runapp.sh           # ローカル GUI（X11 必要；host 側で先に `xhost +local:docker`）
```

> `run.sh -t {headless|gui}` ショートカットは [template issue #215](https://github.com/ycpss91255-docker/template/issues/215) で進行中。実装前は上記の手動 launcher を使用。

## WebRTC livestream への接続

Isaac Sim 5.1 は NVCF（`omni.services.livestream.nvcf`）livestream プロトコルを使用し、**旧版のブラウザビューアは廃止**。デスクトップ client のみで接続：

1. [NVIDIA ドキュメント — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html) から **Isaac Sim WebRTC Streaming Client (1.1.5)** をダウンロード。1.1.5 は 5.1 の最新版です。
2. コンテナ内で `runheadless.sh -v` 実行中、client を起動し Server: `<server-ip>` を入力（同一マシン: `localhost`、リモート: server の LAN IP）。**`:8011` などの port サフィックスを付けないこと** — client が signaling / data port を内部で管理しており、port を付けると誤った経路に入って黒画面になります。
3. Connect をクリック。初回 shader compile に 1–3 分かかってから viewport が描画されます。

注意：

- streaming kit app は `8011`（NVCF signaling、FastAPI/uvicorn）と `49100`（self-host WebRTC）の両方を listen。1.1.5 client が正しい方を選ぶので **port を書かないこと**
- **同時に 1 つの client のみ接続可能**（NVIDIA 制限）。2 つ目の接続は拒否されます
- `setup.conf` で `network_mode: host` が設定済みのため、コンテナ内の listen port = host の port。Host ファイアウォールで `8011/tcp` と `49100/tcp` を許可（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` に `video` が必須 — なければ nvidia-container-runtime が NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`）を mount せず、server 接続成功でも encode できない → 黒画面。現在の `setup.conf` には追加済み
- Server 側で listener を確認：`ss -tln | grep -E ':8011|:49100'` で 2 つの `LISTEN` が見えるはず

## Cache レイアウト

すべての Isaac Sim runtime state は host 側の `${WS_PATH}/isaac-sim/`（つまり `isaac_ws/isaac-sim/`）に永続化：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/cache/kit` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/cache/ov` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主に shader build 成果物）|
| `isaac-sim/cache/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/cache/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/cache/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

初回 headless 起動時は shader compile に 1–3 分かかります；以降は cache hit で `< 30 秒` 起動。

## コンテナ User

コンテナは host UID と整合した非 root ユーザーで実行（`USER_NAME` は `.env` から読み取り、デフォルト UID 1000）。このユーザーはイメージの `isaac-sim` group に追加され、`/isaac-sim/*`（mode `0750`）が読み取り可能。`/home/${USER_NAME}/work`（host 側 `${WS_PATH}` に mount）経由で書いたファイルは host 側 owner を保持、`chown` 不要。

## EULA

`ACCEPT_EULA=Y` と `PRIVACY_CONSENT=Y` は `setup.conf [environment]` 経由で注入。注意：Isaac Sim 5.1 は privacy consent を `OMNI_ENV_PRIVACY_CONSENT` から読む（旧版と環境変数名が異なる）；現在設定している `PRIVACY_CONSENT=Y` は無害だが実際には作用しません。telemetry opt-in したい場合は正しい変数名を設定してください。

## Smoke Tests

詳細は [doc/test/TEST.md](test/TEST.md) を参照。
