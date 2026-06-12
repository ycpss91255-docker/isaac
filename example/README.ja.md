# example/ -- base repo の実行可能サンプル（オンボーディング手順）

このディレクトリは base repo が同梱する唯一の実行可能サンプルであり、
同時に scaffold テンプレートも兼ねます（ADR-0017）。新規開発者や agent に
渡されるのはこれです。ゼロから live な camera topic まで到達し、さらに自分の
ロボットへ差し替えるまでを、**framework のソースを読まずに**行えます。

- [`sim/`](sim/) -- Isaac 側：`camera_bot` URDF、3 ファイル scene、
  per-sensor の `custom.yaml`、`example_driver.py`（camera stream を発行し、
  `/cmd_vel` でシャシを駆動）。
- [`ros2/`](ros2/) -- アプリ側：camera を購読し `/cmd_vel` を発行する最小限の
  ROS 2 パッケージ。[`ros2/README.ja.md`](ros2/README.ja.md) を参照。

## オンボーディング手順（M5 パス）

オンボーディング成功の指標は、workspace を scaffold し、起動し、ロボットを
差し替え、sensor を差し替えること —— すべてこの `example/` 内のファイルを
編集するだけで行い、`framework/` のソースは決して読まない、というものです。
以下の 3 つのタスクは agent-proxy gate が検証する内容そのものです
（`doc/onboarding/agent-proxy-gate.md`）。

### 1. 最初の topic（scaffold -> run）

consumer workspace を scaffold します。base サンプルが `src/isaac/` に
事前展開されているため、そのまま動きます：

```bash
script/new-workspace.sh my-robot-ws
cd my-robot-ws
just setup && just build && just run
```

`just run` で example driver が起動し、camera topic
`/camera_bot/camera/color/image_raw` が現れます。別の ROS 2 container から
確認します：

```bash
docker run --rm --net=host ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  ros2 topic echo --once /camera_bot/camera/color/image_raw'
```

最初の frame が M1「time-to-first-topic」マイルストーンです。

### 2. URDF の差し替え（自分のロボットへ）

ロボットモデルは [`sim/model/camera_bot.urdf`](sim/model/camera_bot.urdf)
です（2 つの link：`base_link` シャシ + `camera_link` マウント点）。別の
最小ロボットに差し替えるには：

1. 自分の URDF を `sim/model/<your_robot>.urdf` に置きます。`base_link`
   （`/cmd_vel` で動く本体）と camera をマウントする link を残します。
2. 一度だけ USD に再 import します（importer は独自の SimulationApp で動く
   ため出力 USD は commit します）：`just import-model sim/model/<your_robot>.urdf`。
3. [`sim/scene/robot.yaml`](sim/scene/robot.yaml) を新しいモデルへ向けます：
   `source_urdf` と `model` を自分のファイルに、`robot.name` を自分の
   ロボット名に設定します。

再度 `just run` —— あなたのロボットが起動し、camera topic は引き続き発行
されます。

### 3. sensor の差し替え（in scope）

camera は per-sensor YAML
[`sim/config/sensor/custom.yaml`](sim/config/sensor/custom.yaml) で設定
します。以下はすべて in-scope の編集です —— ファイルを編集し、再実行し、
framework のコードには一切触れません：

- **解像度 / fps**：`sensors[0].resolution`（例 `[640, 480]`）または
  `sensors[0].fps` を編集。
- **Topic override**：`ros.topic_prefix` を変更（発行 topic と `ros2/` 内の
  対応する subscriber が追従）。
- **2 台目の camera を追加**：`sensors:` の下にもう一つ entry を append し、
  新しい `name` と独自の `resolution` / `fov` を与えます。各 entry が独自の
  `UsdGeom.Camera` と独自の image topic を生成します。

## スコープ外 / 未実装

schema の形状は初日から固定されていますが、framework はサンプルが使う
サブセットのみを実装します（ADR-0017、決定 C：「インターフェース凍結、
実装は漸進」）。**lidar** や **imu** sensor の追加は **意図的な
out-of-scope 境界**です：host 側の YAML 検証はそれらの category を受け付け
ますが、Isaac 側の build path は本当に必要になるまで
**`NotImplementedError` を raise** します。これは設計どおりであり bug では
ありません —— 上記の in-scope な sensor swap の明確な境界です。

| Sensor swap | ステータス |
|---|---|
| camera 解像度 / fps / topic override / 2 台目の camera | in scope（現在動作） |
| **lidar** / **imu** sensor category | **out of scope -- `NotImplementedError` を raise** |
| ZED X ステレオ（`type: zed`） | out of scope -- `NotImplementedError` を raise（Stereolabs extension が必要） |

lidar や imu が必要な場合、それは framework の feature request（issue を
作成）であり、オンボーディング中に `framework/` のソースを編集して解消す
べきものではありません。

## License

Apache-2.0。[LICENSE](../LICENSE) を参照。

## 翻訳

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
