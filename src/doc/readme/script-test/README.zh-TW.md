# Standalone scripts smoke

整合 smoke 測試 `isaac_ws/src/script/*_standalone.py`。每支 script 在透過 `./exec.sh -t standalone /isaac-sim/python.sh <script>` 跑起來後,必須在 timeout 內印出對應的 "ready marker" 字串。Runner 啟動 script、輪詢 stdout 找 marker,看到就收掉,回報每個 case 是 PASS / FAIL。

**[English](../../../script/test/README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 用法

```bash
# 完整 matrix(~6-10 min)
./isaac_ws/src/script/test/standalone_smoke.sh

# 單一 case(改 script 時快速 iterate)
./isaac_ws/src/script/test/standalone_smoke.sh --only cmd_vel

# CI / strict 模式:SKIP 視為 FAIL
./isaac_ws/src/script/test/standalone_smoke.sh --strict
```

前置條件:

- `./run.sh -t standalone -d` 跑得起來(container 沒起時 smoke 會自動帶起)
- 倉內已 track `isaac_ws/src/model/usd/robot/openbase/openbase.usda`,USD 相關 case 直接吃。如果該檔不見了(checkout 不完整 / 意外刪掉),從 repo 內 URDF 源檔重新產:

  ```bash
  cd isaac_ws/src/docker
  ./exec.sh -t standalone /isaac-sim/python.sh \
      /home/yunchien/work/src/script/import_urdf.py \
      /home/yunchien/work/src/model/urdf/robot/openbase/openbase_minimal.urdf \
      /tmp/openbase_generated.usda
  ```

  真的要覆寫 in-repo USD,再把 `openbase_generated.usda` 搬到 `model/usd/robot/openbase/openbase.usda`。in-repo USD 不在的話相關 case 會 SKIP(`--strict` 下會 FAIL)。

## Cases

| Script | Marker phrase | Timeout | USD? |
|--------|---------------|--------:|:----:|
| `ros2_test_pub_standalone.py` | `standalone publishing` | 150s | no |
| `ros2_test_sub_standalone.py` | `standalone subscribed to` | 150s | no |
| `cmd_vel_planar_standalone.py` | `standalone subscribed` | 180s | yes |
| `move_openbase_planar_standalone.py` | `[tick` | 180s | yes |

Marker 用 regex 比對在收到的 stdout+stderr 串上。每支 standalone script 都會在核心 setup 完成(rclpy subscriber 活、或第一次 `[tick]`)時恰好印出一次該 tag 行。

## Exit codes

| Code | 意義 |
|-----:|------|
| 0 | 全部 PASS(SKIP 容許,除非 `--strict`)|
| 1 | 至少 1 個 FAIL |
| 2 | Pre-flight 失敗(docker dir 不在 / standalone container 起不來)|

## 失敗除錯

FAIL 時 runner 會把該 script 的 stdout+stderr 最後 20 行印到 stderr。常見模式:

- `ModuleNotFoundError: No module named 'rclpy'` — `enable_extension("isaacsim.ros2.bridge")` 沒呼叫,或在 `import rclpy` 之後才呼叫
- `AttributeError: 'NoneType' object has no attribute 'GetPrimAtPath'` — `ctx.open_stage()` 回傳了,但 OPENED-spin loop 沒等到 stage 填好
- `Failed to open: <USD path>` — USD 不在或不可讀;檢查 host-side 路徑
- 跑到 timeout 都沒看到 marker — kit 起來但 script 主 loop 沒走到 print;檢查 marker 行以上是否有 exception

## 為什麼用 integration 不用 unit

Standalone scripts 會起 kit + livestream + rclpy subscriber。純 Python unit test 無法取代「script 真的有走到 ROS subscriber loop,USD 載入完,bridge alive」這件事。Marker 字串就是契約 — script 印得出來,等於 SimulationApp init、ROS 2 bridge extension load、rclpy import、node 建立、USD load + OPENED transition 全成立。

## 為什麼放這個目錄,不放 isaac_ws/src/docker/test/

`isaac_ws/src/docker/test/` 屬於 docker repo(`ycpss91255-docker/isaac`),測的是 container image / wrapper,不是跑在 container 內的 script。Standalone scripts 住在 `isaac_ws/src/script/`(本 repo `ycpss91255/isaac`);smoke 跟著它們放一起,搬家也跟著走。
