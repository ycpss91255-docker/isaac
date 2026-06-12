# example/ros2 -- アプリ側 ROS 2 テンプレート

このディレクトリには、base リポジトリの ROS 2 サンプルの**アプリ側**が
入っています。Isaac driver（[`example/sim/`](../sim/)）はカメラ映像を配信
し、`/cmd_vel` からシャシーを駆動します。ここのパッケージはその消費側の
カウンターパート -- 別の ROS 2 Humble コンテナで動く通常の ROS 2 ノードで、
**カメラを購読**し、**`/cmd_vel` を配信**します。

これが「ROS 2 デフォルトの双方向トポロジー」を構造として体現したもの
（ADR-0017 第 6 節）です。フレームワークが Isaac 側のブリッジ配線を担い、
アプリのロジックはこちらの標準 ROS 2 パッケージに置きます。

言語を選べるよう、2 つのテンプレートを用意しています。

| パッケージ | Build type | 言語 | ノード |
|---|---|---|---|
| [`src/example_app_py`](src/example_app_py/) | `ament_python` | Python | `camera_subscriber`、`cmd_vel_publisher` |
| [`src/example_app_cpp`](src/example_app_cpp/) | `ament_cmake` | C++ | `camera_subscriber`、`cmd_vel_publisher` |

どちらも「最小限だが本物」です。colcon でビルドでき、`ament_lint` がクリーン
です。1 つコピーして名前を変え、ノードの中身を自分のロジックに置き換えて
ください。

## トピック

ノード名とデフォルトトピックは Isaac サンプル（[`example/sim/`](../sim/)）
が配信／購読するものと一致するので、同じ DDS ネットワーク上で両側がそのまま
つながります。

| 方向 | トピック | 型 | 設定元 |
|---|---|---|---|
| Isaac -> アプリ（inbound） | `/camera_bot/camera/color/image_raw` | `sensor_msgs/Image` | `example/sim/config/sensor/custom.yaml` |
| アプリ -> Isaac（outbound） | `/cmd_vel` | `geometry_msgs/Twist` | `example/sim/scene/scene.yaml` |

## 前提条件

- Docker（サンプルは公式 `ros:humble` イメージ内で実行するので、ホストに
  ROS 2 をインストールする必要はありません）。

## ビルド

このディレクトリ（`example/ros2/`）で実行します。

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble \
  bash -c 'source /opt/ros/humble/setup.bash && colcon build'
```

`colcon` は `src/` 配下の 2 パッケージを検出してビルドします。成果物は
`build/`、`install/`、`log/`（いずれも gitignore 済み）に出力されます。

## Lint とテスト

`ament_lint` は `colcon test`（標準 ROS 2 の流れ）で実行します。

```bash
docker run --rm -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  colcon build &&
  colcon test &&
  colcon test-result --all'
```

クリーンな実行は `0 errors, 0 failures` を報告します（C++ の `cppcheck`
linter は base イメージにオプションツールが無いため skip されます -- これは
skip であり failure ではありません）。

## サンプルに対して実行

まず Isaac サンプル（[`example/sim/`](../sim/) 参照）を、このコンテナと
DDS ネットワークを共有するホストで起動し、次を実行します。

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py camera_subscriber'
```

カメラフレームを受信するたびに `[FRAME OK]` のログが 1 行出ます。別の
コンテナで動作指令を配信します。

```bash
docker run --rm --net=host -v "$PWD":/ws -w /ws ros:humble bash -c '
  source /opt/ros/humble/setup.bash &&
  source install/setup.bash &&
  ros2 run example_app_py cmd_vel_publisher'
```

`[CMD_VEL OK]` の各行は、Isaac driver が受け取ってシャシーに適用する Twist
に対応します。C++ パッケージも同じ使い方です。
`ros2 run example_app_cpp camera_subscriber` /
`ros2 run example_app_cpp cmd_vel_publisher`。

Isaac <-> ament のコンテナ間の完全な往復（ノードが live の sim トピックを
実際に受信する）は GPU 統合テスト（#132）で検証します。ここのテンプレート
は `colcon build` + `ament_lint` でホスト検証され、GPU は不要です。

## 自分用にする

1. `src/example_app_py` または `src/example_app_cpp` を自分の名前にコピー
   します。
2. パッケージ名を変更します。ディレクトリ、`package.xml` の `name`、
   さらに（Python）`setup.py` の `package_name` ／内側のモジュール
   ディレクトリ、または（C++）`CMakeLists.txt` の `project()`。
3. `camera_topic` ／ `cmd_vel_topic` パラメータを自分のトピックに向けます
   （サンプルとつなぐならデフォルトのままで構いません）。
4. ノードの中身を自分のアプリロジックに置き換えます。

## ライセンス

Apache-2.0。[LICENSE](../../LICENSE) を参照してください。

## 翻訳

- [English](README.md)
- [繁體中文](README.zh-TW.md)
- [简体中文](README.zh-CN.md)
- [日本語](README.ja.md)
