# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 5.1.0 Docker 開発環境。[`ycpss91255-docker/template`](https://github.com/ycpss91255-docker/template) をベースに構築。

イメージのスコープは Isaac Sim 本体に加え、同梱の ROS 2 bridge がコンテナ間通信できるための env 配線まで。下流のアプリケーションノード（CoreSAM、AGV bring-up）と Noetic 互換用の ROS 1 / ROS 2 bridge は隣接する docker folder に配置。

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
./setup.sh remove build.arg "ROS_DISTRO=humble"
./setup.sh add build.arg "ROS_DISTRO=jazzy"
./build.sh           # 新しい ARG で rebuild（影響 layer のみ、~10 秒）
./run.sh -t headless -d
```

jazzy パスは Isaac の 24.04 自動デフォルト（2029 年まで LTS）に揃う — 既知の caveat：jazzy on noble は Python 3.11/3.12 mix と Nav2 paths まわりが NVIDIA forum で追跡中、Isaac Sim 6.0 で解消見込み。

### コンテナ間 DDS の検証

`./run.sh -t headless -d`（humble override env 付き）後、WebRTC client で接続し、Script Editor → File → Open → `isaac_ws/src/script/ros2_test_pub.py` → Run。スクリプトは Play を自動押下し（publisher は timeline が再生中のみ発火）、`/isaac/test` に `std_msgs/String "hello N"` を publish 開始。

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
