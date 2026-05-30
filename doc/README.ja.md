# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開発環境。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（旧名 `ycpss91255-docker/template`）をベースに構築。

イメージのスコープは Isaac Sim 本体に加え、同梱の ROS 2 bridge がコンテナ間通信できるための env 配線まで。下流のアプリケーションノード（CoreSAM、AGV bring-up）と Noetic 互換用の ROS 1 / ROS 2 bridge は隣接する docker folder に配置。

## 前提条件

- NVIDIA driver `>= 580.65.06`（Isaac Sim 5.1 の最低要件）
- GPU `>= RTX 4080`（または同等）、VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- NGC イメージ用に約 20 GB の空き領域；初回起動後にキャッシュがさらに 5–10 GB 増加

NGC イメージ（`nvcr.io/nvidia/isaac-sim:5.1.0`）は公開取得可能、`docker login nvcr.io` 不要。

## Quick Start

> **初回のみ必須：** `make build` の **前に** `./script/init_isaac_dirs.sh` を実行。スキップすると docker daemon が **root** 権限で cache mount ポイントを mkdir し、コンテナ内の非 root ユーザーが書き込めず、Isaac Sim が起動できません。

```bash
./script/init_isaac_dirs.sh   # 初回のみ — host 所有の cache ディレクトリ 8 個を作成
make build                    # devel stage を build（約 16 GB のイメージ）
make run                      # devel コンテナで対話シェル
```

コンテナ内：

```bash
/isaac-sim/runheadless.sh -v   # WebRTC livestream — Isaac Sim WebRTC Streaming Client で接続（下記参照）
/isaac-sim/runapp.sh           # ローカル GUI（X11 必要；host 側で先に `xhost +local:docker`）
```

> 3 つの stage が [base #215](https://github.com/ycpss91255-docker/base/issues/215) により profile-gated compose service として auto-emit される：`headless`（ENTRYPOINT `runheadless.sh -v`、WebRTC livestream）、`gui`（ENTRYPOINT `runapp.sh`、X11）、`standalone`（ENTRYPOINT なし、idle — `make exec -- -t standalone /isaac-sim/python.sh <script>` と組み合わせて standalone Python workflow に使用、スクリプト内で `SimulationApp({"livestream": 2})` が自前の kit + WebRTC server を boot）。使用例：`make run -- -t <stage> -d`。上記の手動 launcher も ad-hoc 用途では引き続き使用可能。

## WebRTC livestream への接続

Isaac Sim 5.1 は NVCF（`omni.services.livestream.nvcf`）livestream プロトコルを使用。デスクトップ client またはブラウザベースのビューアで接続：

1. [NVIDIA ドキュメント — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html) から **Isaac Sim WebRTC Streaming Client (1.1.5)** をダウンロード。1.1.5 は 5.1 の最新版です。
2. `stream` 実行中、client を起動し Server: `<server-ip>` を入力（同一マシン: `localhost`、リモート: server の LAN IP）。**`:8011` などの port サフィックスを付けないこと** — client が signaling / data port を内部で管理しており、port を付けると誤った経路に入って黒画面になります。
3. Connect をクリック。初回 shader compile に 1–3 分かかってから viewport が描画されます。

### Browser-based viewer (omniverse_web_viewer)

[`omniverse_web_viewer`](https://github.com/ycpss91255-docker/omniverse_web_viewer) リポジトリが、サイドカーコンテナとしてブラウザベースの client を提供。本リポジトリの `web_viewer/` にサブモジュールとして同梱。

```bash
# 初回：サブモジュール初期化 + per-host config 作成
git submodule update --init --recursive web_viewer
cp config/host.yaml.example config/host.yaml
# config/host.yaml を編集：network.public_ip にこのマシンの LAN IP を設定

# ワンコマンド起動（Isaac + Isaac Sim + web-viewer）
make -f Makefile.local run-stream

# Isaac Sim のロードを確認（runheadless 出力は /proc/1/fd/1 にリダイレクト済み）
docker logs -f $(. .env && echo "${USER_NAME}-${IMAGE_NAME}-stream")

# Chrome -> http://<host-ip>:5173 を開く
# "UI for any streaming app" を選択 -> Next

# 停止
make -f Makefile.local stop-stream
```

`config/host.yaml` は gitignored・per-machine。`network.public_ip` が両方の container にマウントされ、Isaac 側は `runheadless-host-config.sh` が読んで Kit `publicEndpointAddress` 引数に注入、web-viewer 側は entrypoint が読んで `SIGNALING_SERVER` に設定する。

マルチインスタンス時、`run_instance.sh` は同じ `config/host.yaml` を読み、インスタンスごとにペアの web-viewer を起動する（後述の [Multi-Instance](#multi-instance) を参照）。

要件：Chrome または Chromium（Firefox 非互換）。Isaac Sim インスタンスごとに 1 つのインタラクティブ client のみ接続可能。

注意：

- streaming kit app は `8011`（NVCF signaling、FastAPI/uvicorn）、`49100`（self-host WebRTC）、`8211`（kit API / streaming viewer）を同時に listen。1.1.5 client が正しい方を選ぶので **port を書かないこと**
- **同時に 1 つの client のみ接続可能**（NVIDIA 制限）。2 つ目の接続は拒否されます
- `setup.conf` で `network_mode: host` が設定済みのため、コンテナ内の listen port = host の port。Host ファイアウォールで `8011/tcp` と `49100/tcp` を許可（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` に `video` が必須 — なければ nvidia-container-runtime が NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`）を mount せず、server 接続成功でも encode できない → 黒画面。現在の `setup.conf` には追加済み
- Server 側で listener を確認：`ss -tln | grep -E ':8011|:49100'` で 2 つの `LISTEN` が見えるはず

## ROS 2 bridge（内蔵、build-time distro）

Isaac Sim 5.1 は Humble と Jazzy 両方の内部 ROS 2 ライブラリを `/isaac-sim/exts/isaacsim.ros2.bridge/{humble,jazzy}/` に同梱しており、両方とも kit 内蔵インタプリタと一致する Python 3.11 rclpy。**本イメージは build-time に distro を hard-bake する** — `setup.conf [build] arg_N=ROS_DISTRO=<value>` 経由で指定（デフォルト `humble`、CoreSAM 整合）。

bridge extension `isaacsim.ros2.bridge` はデフォルトの kit experience（`isaacsim.exp.full.kit` → `isaac.startup.ros_bridge_extension`）経由で自動 load。`runheadless.sh` / `runapp.sh` に `--enable` launch flag は不要。

`setup.conf [environment]` で配線済みの env（distro-agnostic）：

| 変数 | 値 | 理由 |
|------|-----|------|
| `ROS_DOMAIN_ID` | `0` | 小規模チームのデフォルト；同一 host を複数ユーザーで共有する場合は変更 |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | 明示的に FastDDS 指定、host から継承しない |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4 のみの profile（コンテナ間 DDS が信頼可能、SHM の不安定さなし）|

### Distro 選択（build-time, hard-baked）

Dockerfile の `ARG ROS_DISTRO=humble` は `setup.conf [build]` と配線されている。build 時にこの値が `/etc/isaac/ros-distro` に書き込まれ、`script/isaac-ros-env-wrapper.sh` が `/usr/local/bin/` に install される。`headless` / `gui` stage は `ENTRYPOINT` をその wrapper に設定し、コンテナ起動毎に baked file から `ROS_DISTRO` と `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` を**無条件**で re-export する — そのため runtime の `-e ROS_DISTRO=...` flag は production path では無効。

`devel` stage は同じ値を Dockerfile `ENV` 経由で soft-bake する（interactive shell ではデフォルトで取得；開発者は `export ROS_DISTRO=...` で実験可能）。

jazzy に切り替えるには：

```bash
make setup -- remove build.arg "ROS_DISTRO=humble"
make setup -- add build.arg "ROS_DISTRO=jazzy"
make build           # 新しい ARG で rebuild（影響 layer のみ、~10 秒）
make run -- -t headless -d
```

jazzy パスは Isaac の 24.04 自動デフォルト（2029 年まで LTS）に揃う — 既知の caveat：jazzy on noble は Python 3.11/3.12 mix と Nav2 paths まわりが NVIDIA forum で追跡中、Isaac Sim 6.0 で解消見込み。

### コンテナ間 DDS の検証

`make run -- -t headless -d`（humble override env 付き）後、WebRTC client で接続し、Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run。スクリプトは Play を自動押下し（publisher は timeline が再生中のみ発火）、`/isaac/test` に `std_msgs/String "hello N"` を publish 開始。

同一 host の別 terminal で：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic list &&
             ros2 topic echo /isaac/test --once'
```

期待動作：`/isaac/test` が topic list に現れ、`echo` で hello メッセージが出力される。

host → Isaac の方向は、Script Editor で `ros2_test_sub.py` を実行し、隣接コンテナから pub：

```bash
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble \
    bash -c 'source /opt/ros/humble/setup.bash &&
             ros2 topic pub /host/test std_msgs/String "{data: hello-from-host}" --once'
```

kit terminal に `[ros2_test_sub] /host/test <- 'hello-from-host'` と出力されるはず。

> jazzy に整合した Isaac インスタンスを動かす場合は、両側を `ros:jazzy` + `/opt/ros/jazzy/setup.bash` に切り替える — IDL hash を一致させるため、両側の distro を揃える必要がある。

### Standalone Python workflow（Script Editor 代替手段）

`isaac_ws/src/script/` には M1 / M2 デモの in-kit Script Editor 版と standalone 版が同梱されている。standalone 版は `SimulationApp({"livestream": 2})` で独自の kit を boot する形式で、`make run -- -t standalone` + `make exec -- -t standalone /isaac-sim/python.sh <script>` で起動。Ctrl+C は SIGINT handler でクリーンに終了するため Script Editor UI は不要。

| In-kit（Script Editor → File → Open → Run） | Standalone（`make exec -- -t standalone /isaac-sim/python.sh <path>`） |
|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py` |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py` |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py` |
| （in-kit 版なし） | `cmd_vel_planar_standalone.py` — `/cmd_vel` (geometry_msgs/Twist) を subscribe → OpenBase 平面移動 |

使用 pattern：

```bash
make run -- -t standalone -d   # idle kit コンテナ（runheadless ENTRYPOINT なし）
make exec -- -t standalone /isaac-sim/python.sh /home/yunchien/work/src/script/<name>_standalone.py
# Browser: localhost:8211/streaming/webrtc-client で stage を見る
# exec session で Ctrl+C → script クリーン終了、コンテナは idle のまま
make stop                      # 後片付け
```

`headless` と `standalone` stage は **同時起動不可** — 両者とも WebRTC port 8211 を bind する。セッション毎に 1 つ選択。

## Cache レイアウト

すべての Isaac Sim runtime state は host 側の `${WS_PATH}/isaac-sim/`（つまり `isaac_ws/isaac-sim/`）に永続化：

| Host | Container | 用途 |
|------|-----------|------|
| `isaac-sim/kit/cache` | `/isaac-sim/kit/cache` | Kit framework cache |
| `isaac-sim/kit/data` | `/isaac-sim/kit/data` | Kit app data（`user.config.json`、pipapi envs）|
| `isaac-sim/kit/logs` | `/isaac-sim/kit/logs` | Kit app logs |
| `isaac-sim/ov/cache` | `/home/${USER_NAME}/.cache/ov` | Omniverse cache（主に shader build 成果物）|
| `isaac-sim/ov/data` | `/home/${USER_NAME}/.local/share/ov/data` | Omniverse data |
| `isaac-sim/ov/logs` | `/home/${USER_NAME}/.nvidia-omniverse/logs` | Omniverse logs |
| `isaac-sim/pip` | `/home/${USER_NAME}/.cache/pip` | pip cache |
| `isaac-sim/nvidia/glcache` | `/home/${USER_NAME}/.cache/nvidia/GLCache` | GL shader cache |
| `isaac-sim/nvidia/computecache` | `/home/${USER_NAME}/.nv/ComputeCache` | CUDA compute cache |
| `isaac-sim/documents` | `/home/${USER_NAME}/Documents` | User Documents（USD scenes 等）|

2026-05-21 以前の layout（`cache/{kit,ov,pip,glcache,computecache}`、flat `logs/`、flat `data/`）はアップグレード後の初回 `./script/init_isaac_dirs.sh` 実行で新しい namespaced path に自動 migrate されます（issue #21 fix-A）。既存の shader / pip / compute cache は mv で保持されます。

初回 headless 起動時は shader compile に 1–3 分かかります；以降は cache hit で `< 30 秒` 起動。

## コンテナ User

コンテナは host UID と整合した非 root ユーザーで実行（`USER_NAME` は `.env` から読み取り、デフォルト UID 1000）。このユーザーはイメージの `isaac-sim` group に追加され、`/isaac-sim/*`（mode `0750`）が読み取り可能。`/home/${USER_NAME}/work`（host 側 `${WS_PATH}` に mount）経由で書いたファイルは host 側 owner を保持、`chown` 不要。

## EULA

`ACCEPT_EULA=Y` と `PRIVACY_CONSENT=Y` は `setup.conf [environment]` 経由で注入。注意：Isaac Sim 5.1 は privacy consent を `OMNI_ENV_PRIVACY_CONSENT` から読む（旧版と環境変数名が異なる）；現在設定している `PRIVACY_CONSENT=Y` は無害だが実際には作用しません。telemetry opt-in したい場合は正しい変数名を設定してください。

## Smoke Tests

詳細は [doc/test/TEST.md](test/TEST.md) を参照。

## Python テストツールキット（devel-test ステージ）

`devel-test` ステージには `pytest`、`pyyaml`、`pytest-cov` が Isaac Sim 同梱の Python（`/isaac-sim/python.sh`）にインストールされており、consumer repos がコンテナ内で Python unit / integration test を実行できる。runtime `devel` ステージにはこれらの依存を入れないため、軽量なまま — テストツールのサイズコストは `devel-test` だけで負担する。

使い方：

```bash
make build -- -t devel-test                                     # devel-test ステージをビルド
make exec -- -t devel-test /isaac-sim/python.sh -m pytest test/unit/
make exec -- -t devel-test /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

システムの `python3` ではこれらのパッケージはインストールできない（Isaac base image の PEP 668 が `pip` をブロック）— 必ず `/isaac-sim/python.sh -m pytest ...` を使い、`pytest ...` は使わない。
