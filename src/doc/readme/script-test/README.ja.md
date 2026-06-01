# Standalone scripts smoke

`isaac_ws/src/script/*_standalone.py` の統合 smoke テスト。各スクリプトは `./exec.sh -t standalone /isaac-sim/python.sh <script>` 経由で実行したとき、タイムアウト内に対応する "ready marker" 文字列を出力しなければいけません。Runner はスクリプトを起動し、stdout を marker でポーリング、見つけ次第ジョブを片付け、各 case の PASS / FAIL を報告します。

**[English](../../../script/test/README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 使い方

```bash
# フル matrix(~6-10 min)
./isaac_ws/src/script/test/standalone_smoke.sh

# 単一 case(スクリプト編集時の高速イテレーション)
./isaac_ws/src/script/test/standalone_smoke.sh --only cmd_vel

# CI / strict モード: SKIP は FAIL 扱い
./isaac_ws/src/script/test/standalone_smoke.sh --strict
```

前提:

- `./run.sh -t standalone -d` が成功すること(container が起きていない場合 smoke が自動で起動します)
- リポジトリには `isaac_ws/src/model/usd/robot/openbase/openbase.usda` が track されており、USD 依存 case はそれを直接使います。もし checkout 不完全や誤削除で当該ファイルが無ければ、repo 内の URDF ソースから再生成してください:

  ```bash
  cd isaac_ws/src/docker
  ./exec.sh -t standalone /isaac-sim/python.sh \
      /home/yunchien/work/src/script/import_urdf.py \
      /home/yunchien/work/src/model/urdf/robot/openbase/openbase_minimal.urdf \
      /tmp/openbase_generated.usda
  ```

  追跡対象の USD を上書きしたい場合は、生成された `openbase_generated.usda` を `model/usd/robot/openbase/openbase.usda` に移動してください。追跡 USD が無いと依存 case は SKIP(`--strict` では FAIL)になります。

## Cases

| Script | Marker phrase | Timeout | USD? |
|--------|---------------|--------:|:----:|
| `ros2_test_pub_standalone.py` | `standalone publishing` | 150s | no |
| `ros2_test_sub_standalone.py` | `standalone subscribed to` | 150s | no |
| `cmd_vel_planar_standalone.py` | `standalone subscribed` | 180s | yes |
| `move_openbase_planar_standalone.py` | `[tick` | 180s | yes |

Marker は受け取った stdout+stderr ストリームに対する regex マッチ。各 standalone スクリプトはコア setup 完了(rclpy subscriber 起動、または最初の `[tick]`)時にタグ付き行を 1 回だけ出力します。

## Exit codes

| Code | 意味 |
|-----:|------|
| 0 | 全 case PASS(SKIP は許容、`--strict` を除く)|
| 1 | 1 件以上 FAIL |
| 2 | Pre-flight 失敗(docker dir が無い / standalone container 起動不可)|

## 失敗デバッグ

FAIL 時、runner は当該スクリプトの stdout+stderr 末尾 20 行を stderr に出力します。よくあるパターン:

- `ModuleNotFoundError: No module named 'rclpy'` — `enable_extension("isaacsim.ros2.bridge")` 呼び出し漏れ、または `import rclpy` の後に呼び出している
- `AttributeError: 'NoneType' object has no attribute 'GetPrimAtPath'` — `ctx.open_stage()` は戻ったが、OPENED-spin loop が stage 充填を待っていない
- `Failed to open: <USD path>` — USD が無い / 読めない。host 側のパスを確認
- タイムアウトまで marker を一度も検出せず — kit は起動したがスクリプトのメインループが print に到達していない。marker 行より前に exception が出ていないか確認

## なぜ integration、unit ではないのか

Standalone scripts は kit + livestream + rclpy subscriber を起動します。純粋な Python unit test は「スクリプトが実際に ROS subscriber loop に到達し、USD がロードされ、bridge が生きている」ことを置き換えられません。Marker 文字列が契約 — スクリプトがそれを print できる、即ち SimulationApp init、ROS 2 bridge extension load、rclpy import、ノード生成、USD load + OPENED 遷移がすべて成立しています。

## なぜこのディレクトリ、`isaac_ws/src/docker/test/` ではないのか

`isaac_ws/src/docker/test/` は docker repo(`ycpss91255-docker/isaac`)に属し、container image / wrapper をテストします。container 内で動くスクリプトはテストしません。Standalone scripts は `isaac_ws/src/script/`(本 repo `ycpss91255/isaac`)に住み、smoke はそれと一緒に置かれていて、移動時も一緒に動きます。
