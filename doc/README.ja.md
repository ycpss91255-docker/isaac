# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開発環境。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（旧名 `ycpss91255-docker/template`）をベースに構築。

イメージのスコープは Isaac Sim 本体に加え、同梱の ROS 2 bridge がコンテナ間通信できるための env 配線まで。NVIDIA Isaac Lab 2.3 も scene-spawn backend（`sim_utils` spawner、`UrdfConverter`、`AppLauncher`；ADR-0018）として image に baked。下流のアプリケーションノード（CoreSAM、AGV bring-up）と Noetic 互換用の ROS 1 / ROS 2 bridge は隣接する docker folder に配置。

本リポジトリは Isaac Sim ワークスペース（driver スクリプト、ADR、USD / URDF モデル）も [`src/`](../src/README.md) に同梱する。root の Dockerfile + base subtree がそのワークスペースを動かす開発環境。元々は `ycpss91255-research/isaac` と `ycpss91255-docker/isaac`（research が docker を submodule として包む構成）に分かれていたが、 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) に従い本リポジトリへ統合した。

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

Production stage（両 stage とも起動後は idle — driver スクリプトを exec で実行中の container に送り込む）：

```bash
make run -- -t headless -d                # pure sim, no streaming (ISAAC_LIVESTREAM=0)
make run -- -t stream -d         # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
make exec -- -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> 2 つの stage が [base #215](https://github.com/ycpss91255-docker/base/issues/215) により profile-gated compose service として auto-emit される：`headless`（pure sim、`ISAAC_LIVESTREAM=0`）、`stream`（sim + WebRTC、`ISAAC_LIVESTREAM=2`）。両者とも起動時は `CMD ["sleep","infinity"]` で idle（`runheadless.sh -v` ENTRYPOINT は無い）— container は起動したまま、`make exec -- -t <stage> <cmd>` で driver スクリプト（`/isaac-sim/python.sh <driver.py>`、`ISAAC_LIVESTREAM=2` を読んで stream を有効化）または一回限りの `/usr/local/bin/runheadless-host-config.sh` を送り込む；streaming 起動後は web-viewer が `:5173` で接続する。`make run -- -t <stage> -d` で起動。

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

# idle な stream コンテナ + host.yaml + web-viewer を起動。
# post-run hook（base #440）が host.yaml をコピーし viewer を起動する。
make run -- -t stream -d
# (マルチインスタンス: --instance <name> を追加；後述の Multi-Instance を参照)

# Isaac Sim をコンテナに起動 -- 明示的なステップ（run = infra、
# exec = workload）。driver スクリプトを使う場合：
make exec -- -t stream /isaac-sim/python.sh <driver.py>
# ...または driver なしのクイックストリームには livestream wrapper：
#   make exec -- -t stream /usr/local/bin/runheadless-host-config.sh

# Isaac Sim のロードを確認
docker logs -f $(. .env && echo "${USER_NAME}-${IMAGE_NAME}-stream")

# Chrome -> http://<host-ip>:5173 を開く
# そのまま映像ストリームが起動します（stream-only 自動起動。UI Option 選択画面なし）

# すべて停止（post-stop hook が web-viewer を削除する）
make stop
```

`config/host.yaml` は gitignored・per-machine。`network.public_ip` が両方の container にマウントされ、Isaac 側は `runheadless-host-config.sh` が読んで Kit `publicEndpointAddress` 引数に注入、web-viewer 側は entrypoint が読んで `SIGNALING_SERVER` に設定する。

マルチインスタンス時、`./run.sh --instance <name>` は `config/instances/<name>.{yaml,env}` を compose overlay として load し（base #465）、post-run hook がインスタンスごとにペアの web-viewer を起動する（後述の [Multi-Instance](#multi-instance) を参照）。さらに `network.public_ip` を `SIGNALING_SERVER` env として viewer container に渡す — defense in depth として、ローカルキャッシュの viewer image が `omniverse_web_viewer#12`（`/etc/host.yaml` を読む entrypoint）より古い場合でも正しい host IP を取得できる。`web_viewer/` submodule pointer 更新後は `owv:runtime` を手動 rebuild して新しい entrypoint を取り込むこと。

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

Dockerfile の `ARG ROS_DISTRO=humble` は `setup.conf [build]` と配線されている。build 時にこの値が `/etc/isaac/ros-distro` に書き込まれ、`script/isaac-ros-env-wrapper.sh` が `/usr/local/bin/` に install される。`headless` / `stream` stage は `ENTRYPOINT` をその wrapper に設定し、コンテナ起動毎に baked file から `ROS_DISTRO` と `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` を**無条件**で re-export する — そのため runtime の `-e ROS_DISTRO=...` flag は production path では無効。

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

`isaac_ws/src/script/` には M1 / M2 デモの in-kit Script Editor 版と standalone 版が同梱されている。standalone 版は `SimulationApp({"livestream": 2})` で独自の kit を boot する形式で、`make run -- -t stream` + `make exec -- -t stream /isaac-sim/python.sh <script>` で起動。Ctrl+C は SIGINT handler でクリーンに終了するため Script Editor UI は不要。

| In-kit（Script Editor → File → Open → Run） | Standalone（`make exec -- -t stream /isaac-sim/python.sh <path>`） |
|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py` |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py` |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py` |
| （in-kit 版なし） | `cmd_vel_planar_standalone.py` — `/cmd_vel` (geometry_msgs/Twist) を subscribe → OpenBase 平面移動 |

使用 pattern：

```bash
make run -- -t stream -d   # idle kit コンテナ（runheadless ENTRYPOINT なし）
make exec -- -t stream /isaac-sim/python.sh /home/yunchien/work/src/script/<name>_standalone.py
# Browser: localhost:8211/streaming/webrtc-client で stage を見る
# exec session で Ctrl+C → script クリーン終了、コンテナは idle のまま
make stop                      # 後片付け
```

`headless` と `stream` stage は **同時起動不可**（kit プロセスは一度に 1 つのみ） — 両者とも WebRTC port 8211 を bind する。セッション毎に 1 つ選択。

## Multi-Instance

複数の Isaac Sim インスタンスを同一 GPU 上で実行できる。各インスタンスは衝突を避けるため独立した port と cache ディレクトリを持つ。

### 前提条件

- 同一 GPU をインスタンス間で共有（VRAM はすべての稼働 sim を収容できる必要がある）
- `setup.conf` の `pid=host`（GPU プロセス可視性のために必須）
- 起動をずらす — 次を起動する前に各インスタンスが "is loaded" を報告するまで待つ
- 各インスタンスは独立した cache ディレクトリを持つ必要がある（共有すると破損を招く）

### 使い方

```bash
# Author per-instance overlays from the committed template (ports + cache).
# These live in config/instances/<name>.{yaml,env} (base #465 convention)
# and are gitignored except the example template.
cp config/instances/example.env  config/instances/warehouse.env
cp config/instances/example.yaml config/instances/warehouse.yaml
# edit warehouse.env: bump the ports for a second concurrent instance

# Start instances (stagger — wait for "is loaded" between launches).
# The pre-run hook creates the cache tree; the post-run hook copies
# host.yaml in and starts the per-instance web-viewer.
./run.sh -t stream -d --instance warehouse
# ... wait for "is loaded" ...
./run.sh -t stream -d --instance factory

# Launch Isaac Sim into a specific instance (container is
# ${USER_NAME}-isaac-stream-<name>):
./exec.sh -t stream --instance warehouse /isaac-sim/python.sh <script>

# Tear down (the post-stop hook also removes the per-instance web-viewer)
./stop.sh --instance warehouse
./stop.sh --instance factory
```

### Port レイアウト

各インスタンスには固有の port セットが割り当てられ、`config/instances/<name>.env`（`example.env` からコピー）に手動で記述する：

| Port | 用途 | Instance 1（デフォルト） | Instance 2 | Step |
|------|------|---------------------|------------|------|
| Signal | NVCF livestream signaling（`--/app/livestream/port`） | 49100 | 49200 | +100 |
| Media | WebRTC media（`--/app/livestream/fixedHostPort`） | 47998 | 48098 | +100 |
| API | Kit HTTP API（`--/exts/omni.services.transport.server.http/port`） | 8011 | 8012 | +1 |
| Viewer | omniverse_web_viewer（`SERVE_PORT`） | 5173 | 5174 | +1 |

`config/instances/example.env` はデフォルトインスタンスの値を同梱し、インスタンスごとの offset を inline で記載している。自動割り当てジェネレータは存在しない：同時実行するインスタンスごとにテンプレートをコピーして port を step 分だけ増やす。overlay `<name>.yaml` は port を container env に流し込み（これにより `runheadless-host-config.sh` が対応する Kit 引数を組み立てる）、cache mount を remap する。

### Cache 分離

各インスタンスは runtime state を共有デフォルト path ではなく自身の `INSTANCE_CACHE_DIR`（デフォルト `instance/<name>`、docker repo root からの相対）配下に保存する。pre-run hook（`script/hooks/pre/run.sh`）が `run.sh --instance <name>` 実行時にこのディレクトリツリーを自動作成する。**インスタンス間で cache ディレクトリを共有してはならない** — 同一 shader cache や kit data ディレクトリへの並行書き込みは破損とクラッシュを招く。

### 接続

各インスタンスを、そのインスタンスの signal port を指す専用の `omniverse_web_viewer` とペアにするか、native WebRTC client を使う（インスタンスごとに 1 client）。

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

GPU integration test（Isaac Sim の実起動が必要なもの、例: camera → ROS 2 headless smoke、#127）は `test` compose service で実行する。この service の NVIDIA GPU reservation は `setup.conf` の `[stage:devel-test]` override（`deploy.gpu_mode = force`、base #493）に由来する:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

合否判定は stdout の marker 行（`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`）であり、return code ではない — Kit の `app.close` は `_exit(0)` を呼ぶ。詳細は [doc/test/TEST.md](test/TEST.md) を参照。
