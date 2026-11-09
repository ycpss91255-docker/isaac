# isaac

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

NVIDIA Isaac Sim 6.2.0 Docker 開発環境。[`ycpss91255-docker/base`](https://github.com/ycpss91255-docker/base)（旧名 `ycpss91255-docker/template`）をベースに構築。

イメージのスコープは Isaac Sim 本体に加え、同梱の ROS 2 bridge がコンテナ間通信できるための env 配線まで。NVIDIA Isaac Lab 3.0（`v3.0.0`）も scene-spawn backend（`sim_utils` spawner、`UrdfConverter`、`AppLauncher`；ADR-0018）として image に baked。下流のアプリケーションノード（CoreSAM、AGV bring-up）と Noetic 互換用の ROS 1 / ROS 2 bridge は隣接する docker folder に配置。

本リポジトリは Isaac Sim ワークスペース（driver スクリプト、ADR、USD / URDF モデル）も [`src/`](../src/README.md) に同梱する。root の Dockerfile + base subtree がそのワークスペースを動かす開発環境。元々は `ycpss91255-research/isaac` と `ycpss91255-docker/isaac`（research が docker を submodule として包む構成）に分かれていたが、 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) に従い本リポジトリへ統合した。

## 前提条件

- NVIDIA driver `>= 580`（Isaac Lab 3.0 は CUDA 13 版 PyTorch を導入；NVIDIA は Isaac Sim 6.2.0 を 595.58.03 で検証；本 repo は driver 610 で検証済み）
- GPU `>= RTX 4080`（または同等）、VRAM `>= 16 GB`
- Docker + nvidia-container-toolkit
- 約 50 GB の空き領域。build 後のイメージは約 31 GB で、そのうち 20.7 GB が NGC base image、約 10 GB が Isaac Lab と tooling；他の stage はこれらの layer を共有する。build には BuildKit cache 用の余裕が必要で、初回起動後に cache ディレクトリがさらに 5–10 GB 増加

NGC イメージ（`nvcr.io/nvidia/isaac-sim:6.2.0.1`、6.2.0 GA ビルド；`:6.2.0` を使わない理由は `Dockerfile` の `BASE_IMAGE` コメント参照）は公開取得可能、`docker login nvcr.io` 不要。

## Quick Start

fresh clone から、repo root で以下を実行：

```bash
./script/checkout_identity.sh isolate   # first time only — gives this checkout its own image tag + compose project
./script/init_isaac_dirs.sh             # first time only — runs ./script/setup.sh apply, creates the 10 host-owned cache dirs
just docker build                       # builds the devel stage (~31 GB image, see Prerequisites)
just docker run                         # interactive shell in the devel container
```

> cache ディレクトリは、container が mount する **前に** 存在し、自分の所有になっている必要がある。そうでないと docker daemon がそれらを **root** で作成し、Kit が cache を書き込めない。その結果 ROS 2 OmniGraph node を登録できず（`[Errno 13] ... kit/cache/ogn_generated`）、それでも exit 0 で終了する。`init_isaac_dirs.sh` がこれらを作成し、pre-run hook が毎回の `just docker run` の前に再実行する。すでに root 所有になっている場合、スクリプトは停止して `chown` による修正方法を表示する。

Production stage（両 stage とも起動後は idle — driver スクリプトを exec で実行中の container に送り込む）：

```bash
just docker run -t headless -d                # pure sim, no streaming (ISAAC_LIVESTREAM=0)
just docker run -t stream -d         # sim + WebRTC streaming (ISAAC_LIVESTREAM=2)
just docker exec -t stream /isaac-sim/python.sh <script>   # run a driver script
```

> 2 つの stage が [base #215](https://github.com/ycpss91255-docker/base/issues/215) により profile-gated compose service として auto-emit される：`headless`（pure sim、`ISAAC_LIVESTREAM=0`）、`stream`（sim + WebRTC、`ISAAC_LIVESTREAM=2`）。両者とも起動時は `CMD ["sleep","infinity"]` で idle（`runheadless.sh -v` ENTRYPOINT は無い）— container は起動したまま、`just docker exec -t <stage> <cmd>` で driver スクリプト（`/isaac-sim/python.sh <driver.py>`、`ISAAC_LIVESTREAM=2` を読んで stream を有効化）または一回限りの `/usr/local/bin/runheadless-host-config.sh` を送り込む；streaming 起動後は web-viewer が `:5173` で接続する。`just docker run -t <stage> -d` で起動。

### Headless：Isaac を起動してシーンを実行する

`example/` の camera_bot シーンは headless で動作し、ROS 2 camera topic を publish し `/cmd_vel` を subscribe する。container の working directory は repo root（`~/work` に mount）なので、スクリプトのパスは repo からの相対パス。以下の手順は Isaac Sim 6.2.0（RTX 5090）で検証済み：

```bash
just docker build -t headless
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; EXAMPLE_TICK_BUDGET=100000 exec /isaac-sim/python.sh example/sim/example_driver.py'
# prints [CAMERA GRAPH OK] and [BOOT OK] in about 30 s

# In a second terminal: the camera topic, from a sibling ROS 2 container
docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 ros:humble bash -c \
  'source /opt/ros/humble/setup.bash && ros2 topic echo --once /camera_bot/camera/color/image_raw --field header'
# frame_id: camera_bot_camera_color_optical_frame

just docker stop
```

`EXAMPLE_TICK_BUDGET` を指定しない場合、driver は 1800 update（headless で約 2 分）後に自動で停止し、`[EXIT CLEAN]` を出力する。Kit は session log を host 側の `isaac-sim/kit/logs/Kit/<app>/<version>/kit_<timestamp>.log` に書き込む。最新のものを追うには：

```bash
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"
```

container の `docker logs` には idle の main process（`sleep infinity`）しか出ず、exec で送り込んだスクリプトの出力は表示されない。

> quote された `bash -c '...'` を含むコマンドは `just docker exec` ではなく `./script/exec.sh` を経由する。base v0.42.0 では `just` recipe が引数を再分割するため、quote したコマンドや `>` が host 側で実行されてしまう。base は v0.43.0-rc5（base PR #1298）で修正済みだが、本 repo はまだ v0.42.0 を pin している（#297）。

### driver スクリプトの停止

対話的な `just docker exec` での Ctrl+C はスクリプトに届き、その SIGINT handler が Kit を shutdown する。しかし exec client が TTY でない場合や、client が kill された場合（terminal を閉じた、`timeout`、CI）、signal はスクリプトに届かず、**Kit は container 内で動き続ける**。確実に停止するには、上の例の `echo $$ > /tmp/isaac-driver.pid` のように、スクリプト起動時に PID を記録しておく。その上で、その process の子（`python.sh` が起動した Python）に SIGINT を送る：

```bash
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
```

素の `pkill -f <script>` は使わないこと。container は `pid: host` で動作しているため、その pattern は host や他の container の process にもマッチする。すべてを停止したい場合は、`just docker stop` でこの checkout の container を削除すれば、内部で動いている Kit もまとめて停止する。

### checkout ごとに 1 つの image と 1 つの compose project

以前は同じ host 上のこの repo のすべての checkout が同じ image tag（`<hub>/isaac:<stage>`）と同じ compose project（`<hub>-isaac`）に解決されていた。そのため `just docker build` が別の checkout の build した image を prune し、`just docker stop` / `run` が別の checkout の container を削除していた（上流：[base#1550](https://github.com/ycpss91255-docker/base/issues/1550)、[base#1551](https://github.com/ycpss91255-docker/base/issues/1551)、[base#1552](https://github.com/ycpss91255-docker/base/issues/1552)）。base が修正するまでは：

- `./script/checkout_identity.sh isolate` が `[image] rule_1 = string:isaac-<dir>-<hash>` を gitignore 済みの `.setup.conf.local` に書き込む。image tag・compose project・container 名はすべてこれに従う。`./script/checkout_identity.sh show` でこの checkout の解決結果を表示できる。
- pre build / run / stop hook は共有名のままでは実行を拒否する。`ISAAC_ALLOW_SHARED_IDENTITY=1` で上書きできる（CI の build ステップが使用）。
- `just docker run` は既存の image を再 build しない（base#1552）。変更を pull したら `just docker run -t <stage>` の前に `just docker build -t <stage>` を実行する。
- isolate 前に起動した container は共有 project に残る。`docker compose -p <hub>-isaac ps -a` で一覧し、自分のものを名前で停止する。`ISAAC_ALLOW_SHARED_IDENTITY=1 just docker stop` は共有 project 全体（別の checkout の container を含む）を停止する。

## WebRTC livestream への接続

Isaac Sim 6.2.0 は NVCF（`omni.services.livestream.nvcf`）livestream プロトコルを使用。デスクトップ client またはブラウザベースのビューアで接続：

1. [NVIDIA ドキュメント — manual livestream clients](https://docs.isaacsim.omniverse.nvidia.com/6.2.0/installation/manual_livestream_clients.html) から **Isaac Sim WebRTC Streaming Client** をダウンロード。NVIDIA ドキュメントがそこに記載する、お使いの Isaac Sim バージョンに対応した client バージョンを使用してください。
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
just docker run -t stream -d

# Isaac Sim をコンテナに起動 -- 明示的なステップ（run = infra、
# exec = workload）。driver スクリプトを使う場合：
just docker exec -t stream /isaac-sim/python.sh <driver.py>
# ...または driver なしのクイックストリームには livestream wrapper：
#   just docker exec -t stream /usr/local/bin/runheadless-host-config.sh

# Watch Isaac Sim load: Kit's session log on the host (docker logs only
# shows the container's idle main process)
tail -f "$(ls -t isaac-sim/kit/logs/Kit/*/*/kit_*.log | head -1)"

# Chrome -> http://<host-ip>:5173 を開く
# そのまま映像ストリームが起動します（stream-only 自動起動。UI Option 選択画面なし）

# すべて停止（post-stop hook が web-viewer を削除する）
just docker stop
```

`config/host.yaml` は gitignored・per-machine。`network.public_ip` が両方の container にマウントされ、Isaac 側は `runheadless-host-config.sh` が読んで Kit `publicEndpointAddress` 引数に注入、web-viewer 側は entrypoint が読んで `SIGNALING_SERVER` に設定する。

post-run hook はさらに `network.public_ip` を `SIGNALING_SERVER` env として viewer container に渡す — defense in depth として、ローカルキャッシュの viewer image が `omniverse_web_viewer#12`（`/etc/host.yaml` を読む entrypoint）より古い場合でも正しい host IP を取得できる。`web_viewer/` submodule pointer 更新後は `owv:runtime` を手動 rebuild して新しい entrypoint を取り込むこと。

要件：Chrome または Chromium（Firefox 非互換）。稼働中の Isaac Sim ごとに 1 つのインタラクティブ client のみ接続可能。

注意：

- streaming kit app は `8011`（NVCF signaling、FastAPI/uvicorn）、`49100`（self-host WebRTC）、`8211`（kit API / streaming viewer）を同時に listen。WebRTC Streaming Client が正しい方を選ぶので **port を書かないこと**
- **同時に 1 つの client のみ接続可能**（NVIDIA 制限）。2 つ目の接続は拒否されます
- `setup.conf` で `network_mode: host` が設定済みのため、コンテナ内の listen port = host の port。Host ファイアウォールで `8011/tcp` と `49100/tcp` を許可（`sudo ufw allow 8011/tcp && sudo ufw allow 49100/tcp`）
- `setup.conf [deploy] gpu_capabilities` に `video` が必須 — なければ nvidia-container-runtime が NVENC libs（`libnvidia-encode.so` / `libnvcuvid.so`）を mount せず、server 接続成功でも encode できない → 黒画面。現在の `setup.conf` には追加済み
- Server 側で listener を確認：`ss -tln | grep -E ':8011|:49100'` で 2 つの `LISTEN` が見えるはず

### 決定論的 stream-source producer（GHCR image、isaac#223）

CI とブラウザベースの視覚 e2e（[`omniverse_web_viewer#48`](https://github.com/ycpss91255-docker/omniverse_web_viewer/issues/48)、Tier B browser-frames smoke isaac#173 が消費）向けに、デスクトップ Isaac session を立ち上げずに*確実に非ブラック*な WebRTC ソースを提供する、pull 可能で版号を pin した producer image。起動時に決定論的な「空だが光のある」シーン — dome + distant key light を 12×12 チェッカーボード床に当て、カメラは `eye=[15,-15,11]` にフレーミング — をレンダリングし、永久に livestream するので、ブラウザはいつ接続しても再現可能なフレームを見る。シーン全体はプログラムで生成（外部 asset なし）、image は自己完結。

- **Image**：`ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>`（pin した immutable tag — `:latest` ではない）。`producer` Dockerfile stage から build。
- **Driver**：`src/script/stream_source_producer.py`、`/opt/isaac-producer/stream_source_producer.py` に bake され、image `CMD` が起動。
- **公開**：`Publish Stream-Source Producer (GHCR)` workflow の手動起動のみ（`workflow_dispatch`、input `tag`、デフォルト `0.0.1`）。push/tag trigger は無いので、merge で自動公開されない。

実行：

```bash
# --network=host でコンテナの WebRTC listen port = host の port。
# PUBLIC_IP はこの host の LAN IP（リモートブラウザがダイヤルする先）；
# ISAAC_SIGNAL_PORT はデフォルト signaling port（49100）を上書き。
docker run --rm --network=host --gpus all \
  -e PUBLIC_IP=<host-lan-ip> \
  -e ISAAC_SIGNAL_PORT=49100 \
  ghcr.io/ycpss91255-docker/isaac-stream-source:0.0.2

# その後ブラウザ / omniverse_web_viewer で <host-lan-ip> に接続（上記参照）。
```

Isaac Sim 6.2.0 から build した producer image はまだ公開されていない。最新は 6.0.1 上で build した `0.0.2` なので、下の表もそこで終わっている。公開は publish workflow の手動 `workflow_dispatch` で行い、表は image 自身の label から更新される。

### バージョンと Isaac Sim の対応

producer image のバージョンは単純に増加し、Isaac Sim のバージョンを符号化しません。あるイメージがどの Isaac Sim 上でビルドされたかは、イメージ自身に尋ねてください。

<!-- producer-versions:start -->
| Tag | Isaac Sim | Source |
|---|---|---|
| `0.0.1` | 5.1.0 | declared (predates the label) |
| `0.0.2` | 6.0.1 | declared (predates the label) |

Generated by `script/ci/sync_producer_versions.py`; do not edit by hand.

The table is a convenience view. The authority is the image itself --
ask it directly when it matters:

```bash
docker inspect ghcr.io/ycpss91255-docker/isaac-stream-source:<tag> \
  --format '{{index .Config.Labels "org.opencontainers.image.base.name"}}'
```
<!-- producer-versions:end -->

必須：NVENC フレームエンコード用の NVIDIA GPU runtime（`--gpus all`）、`--network=host`、非 localhost client には `PUBLIC_IP`。`ISAAC_SIGNAL_PORT` は任意（デフォルト `49100`）。driver は `--public-ip` / `--port` / `--run-seconds N`（`N>0` で smoke run を区切る；デフォルトは永久実行）も受け付ける。

## ROS 2 bridge（内蔵、build-time distro）

Isaac Sim 6.2.0 は Humble と Jazzy 両方の内部 ROS 2 ライブラリを `/isaac-sim/exts/isaacsim.ros2.core/{humble,jazzy}/` に同梱しており（5.1 では `isaacsim.ros2.bridge/` に配置。6.0 で単一の bridge ext が `isaacsim.ros2.core` + `isaacsim.ros2.nodes` などに分割された）、両方とも kit 内蔵インタプリタと一致する Python 3.12 rclpy。**本イメージは build-time に distro を hard-bake する** — `setup.conf [build] arg_N=ROS_DISTRO=<value>` 経由で指定（デフォルト `humble`、CoreSAM 整合）。

bridge extension は base `IsaacDriver` が Kit BOOT 時に有効化する（`BOOT_EXTENSIONS` -> `--enable isaacsim.ros2.bridge` kit args）。これは Isaac Sim 6.x で headless camera -> ROS 2 publish に必須（isaac#248；6.2.0 で再検証：runtime 有効化は依然 app を終了させる）。driver パスでは追加の launch flag は不要。

`setup.conf [environment]` で配線済みの env（distro-agnostic）：

| 変数 | 値 | 理由 |
|------|-----|------|
| `ROS_DOMAIN_ID` | `0` | 小規模チームのデフォルト；同一 host を複数ユーザーで共有する場合は変更 |
| `RMW_IMPLEMENTATION` | `rmw_fastrtps_cpp` | 明示的に FastDDS 指定、host から継承しない |
| `FASTRTPS_DEFAULT_PROFILES_FILE` | `/isaac-sim/fastdds.xml` | UDPv4 のみの profile（コンテナ間 DDS が信頼可能、SHM の不安定さなし）|

### Distro 選択（build-time, hard-baked）

Dockerfile の `ARG ROS_DISTRO=humble` は `setup.conf [build]` と配線されている。build 時にこの値が `/etc/isaac/ros-distro` に書き込まれ、`script/isaac-ros-env-wrapper.sh` が `/usr/local/bin/` に install される。`headless` / `stream` stage は `ENTRYPOINT` をその wrapper に設定し、コンテナ起動毎に baked file から `ROS_DISTRO` と `LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.core/${ROS_DISTRO}/lib` を**無条件**で re-export する — そのため runtime の `-e ROS_DISTRO=...` flag は production path では無効。

`devel` stage は同じ値を Dockerfile `ENV` 経由で soft-bake する（interactive shell ではデフォルトで取得；開発者は `export ROS_DISTRO=...` で実験可能）。

jazzy に切り替えるには：

```bash
just docker setup remove build.arg "ROS_DISTRO=humble"
just docker setup add build.arg "ROS_DISTRO=jazzy"
just docker build           # 新しい ARG で rebuild（影響 layer のみ、~10 秒）
just docker run -t headless -d
```

jazzy パスは Isaac の 24.04 自動デフォルト（2029 年まで LTS）に揃う — 既知の caveat：jazzy on noble は Python 3.11/3.12 mix と Nav2 paths まわりが NVIDIA forum で追跡中。本 repo では jazzy パスを Isaac Sim 6.2.0 で再検証していない；検証済みのデフォルトは humble。

### コンテナ間 DDS の検証

`just docker run -t headless -d`（humble override env 付き）後、WebRTC client で接続し、Script Editor → File → Open → `~/work/src/script/ros2_test_pub.py`（container 内に mount された repo の `src/script/`）→ Run。スクリプトは Play を自動押下し（publisher は timeline が再生中のみ発火）、`/isaac/test` に `std_msgs/String "hello N"` を publish 開始。

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

`src/script/` には M1 / M2 デモの in-kit Script Editor 版と standalone 版が同梱されている。standalone 版は `SimulationApp` で独自の Kit を boot し、stage の `ISAAC_LIVESTREAM`（`headless` は 0、`stream` は 2）に従う。`cmd_vel_planar_standalone.py` は常に Kit を headless で動かす。1 つの standalone process 内で livestream と ROS 2 bridge を併用すると Kit が crash したため（IsaacSim#228）。各 standalone スクリプトは `--run-seconds N` を受け付け、エラー時は exit 1 で終了する（以前は exit 0 だった）。

| In-kit（Script Editor → File → Open → Run） | Standalone（`just docker exec -t headless /isaac-sim/python.sh src/script/<name>`） | 6.2.0 で検証（headless） |
|---|---|---|
| `ros2_test_pub.py` | `ros2_test_pub_standalone.py`：`/isaac/test` を毎秒 1 回 publish | `ros2 topic hz` 1.000 |
| `ros2_test_sub.py` | `ros2_test_sub_standalone.py`：受信した `/host/test` メッセージを毎回出力 | 3/3 受信 |
| `move_openbase_planar.py` | `move_openbase_planar_standalone.py`：固定の `CMD_VX/VY/WZ` で平面移動 | x +0.5 m/s、z は 0 のまま |
| （in-kit 版なし） | `cmd_vel_planar_standalone.py`：`/cmd_vel`（geometry_msgs/Twist）を subscribe し、OpenBase を平面内で移動 | 指令 0 では静止、`linear.x: 0.5` で x +0.5 m/s、z は 0 のまま |

使用 pattern：

```bash
just docker run -t headless -d
./script/exec.sh -t headless bash -c \
  'echo $$ > /tmp/isaac-driver.pid; exec /isaac-sim/python.sh src/script/<name>_standalone.py'
# stop it (see "Stopping a driver script"):
./script/exec.sh -t headless bash -c 'pkill -INT -P "$(cat /tmp/isaac-driver.pid)"'
just docker stop                           # cleanup
```

共有 host では ROS domain 0 上に他の `/cmd_vel` publisher が存在することがあり、それらも OpenBase を動かしてしまう。自分の run には専用の domain を割り当てること。例えば `bash -c 'ROS_DOMAIN_ID=77 exec /isaac-sim/python.sh ...'` とし、隣接 container にも同じ `-e ROS_DOMAIN_ID=77` を指定する。

## Cache レイアウト

すべての Isaac Sim runtime state は host 側の `${WS_PATH}/isaac-sim/` に永続化される。`WS_PATH` は repo root に解決されるため、checkout 内の `isaac-sim/` がこれに当たる。gitignore 済みで、`.dockerignore` により docker build context からも除外されている：

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

Kit は `isaac-sim/documents/Kit/shared/screenshots` がまだ存在しない場合、mode 000 で作成する。`init_isaac_dirs.sh` はこれを 0755 で事前作成し、mode 000 になっているものは修復する。

container は health status を報告しない（`HEALTHCHECK NONE`）。NGC base image の check は Kit log を `App is loaded` で grep するが、これらの container は設計上 Kit なしで idle するため、すべて `unhealthy` と判定されていた。

初回 headless 起動時は shader compile に 1–3 分かかります；以降は cache hit で `< 30 秒` 起動。

## コンテナ User

コンテナは host UID と整合した非 root ユーザーで実行（`USER_NAME` は `.env` から読み取り、デフォルト UID 1000）。このユーザーはイメージの `isaac-sim` group に追加され、`/isaac-sim/*`（mode `0750`）が読み取り可能。`/home/${USER_NAME}/work`（host 側 `${WS_PATH}` に mount）経由で書いたファイルは host 側 owner を保持、`chown` 不要。

## EULA

`ACCEPT_EULA=Y` と `PRIVACY_CONSENT=Y` は `setup.conf [environment]` 経由で注入。注意：Isaac Sim 6.x は privacy consent を `OMNI_ENV_PRIVACY_CONSENT` から読む（この名前は 5.1 で採用され、5.1 より前の版とは異なる）；現在設定している `PRIVACY_CONSENT=Y` は無害だが実際には作用しません。telemetry opt-in したい場合は正しい変数名を設定してください。

## Smoke Tests

詳細は [doc/test/TEST.md](test/TEST.md) を参照。

## Python テストツールキット（devel-test ステージ）

`devel-test` ステージには `pytest`、`pyyaml`、`pytest-cov` が Isaac Sim 同梱の Python（`/isaac-sim/python.sh`）にインストールされており、consumer repos がコンテナ内で Python unit / integration test を実行できる。runtime `devel` ステージにはこれらの依存を入れないため、軽量なまま — テストツールのサイズコストは `devel-test` だけで負担する。

使い方：

```bash
just docker build -t devel-test                                     # devel-test ステージをビルド
just docker exec -t devel-test /isaac-sim/python.sh -m pytest test/unit/
just docker exec -t devel-test /isaac-sim/python.sh -m pytest --cov=<pkg> test/
```

システムの `python3` ではこれらのパッケージはインストールできない（Isaac base image の PEP 668 が `pip` をブロック）— 必ず `/isaac-sim/python.sh -m pytest ...` を使い、`pytest ...` は使わない。

GPU integration test（Isaac Sim の実起動が必要なもの、例: camera → ROS 2 headless smoke、#127）は `test` compose service で実行する。この service の NVIDIA GPU reservation は `setup.conf` の `[stage:devel-test]` override（`deploy.gpu_mode = force`、base #493）に由来する:

```bash
just docker run -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_camera_ros2_headless.py
```

合否判定は stdout の marker 行（`[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]`）であり、return code ではない — Kit の `app.close` は `_exit(0)` を呼ぶ。詳細は [doc/test/TEST.md](test/TEST.md) を参照。
