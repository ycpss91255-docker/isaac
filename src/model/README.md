# Model Assets

Robot models (URDF and USD) that were previously committed under
`src/model/urdf/robot/` and `src/model/usd/robot/` have moved to a
dedicated repository:

  **[ycpss91255-docker/sim_asset](https://github.com/ycpss91255-docker/sim_asset)** (private)

The `sw/` and `object/` subdirectories remain here as placeholders for
SolidWorks source files and object assets respectively.

## Moved models

| Model | URDF | USD |
|-------|------|-----|
| omwr | `urdf/omwr/` | `usd/omwr/` |
| openbase | `urdf/openbase/` | `usd/openbase/` |
| forklift_blocky | -- | `usd/forklift_blocky/` |

## Test fixtures

The `openbase_minimal` URDF fixture used by the GPU model-import
integration test lives at `test/fixtures/urdf/openbase_minimal/` and is
self-contained (no dependency on the sim_asset repository).
