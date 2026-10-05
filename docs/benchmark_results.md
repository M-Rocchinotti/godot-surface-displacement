# Surface Displacement benchmark

*Measured before the rename to GADS: "Epic" below is today's Ultra preset, unchanged.*

GPU: NVIDIA GeForce GTX 1080 | 1.4.312 | 1920x1080, V-Sync off, 3 x (150 warm-up + 300 sampled frames), median

Baseline (ORMMaterial3D, same textures and texel density, normal mapping only): viewport GPU 1.408 ms (6 runs before and after the rows, spread 0.030)

| Preset | features | viewport GPU ms | added ms | target ms | spread | result |
|---|---|---|---|---|---|---|
| Off | all of the preset | 1.496 | 0.088 | - | 0.010 | - |
| Low | all of the preset | 1.879 | 0.471 | 0.5 | 0.003 | PASS |
| Medium | all of the preset | 2.556 | 1.149 | 1.2 | 0.025 | PASS |
| High | all of the preset | 2.985 | 1.577 | 2.0 | 0.004 | PASS |
| Epic | all of the preset | 4.266 | 2.858 | 3.0 | 0.014 | PASS |
| Epic | no scatter | 4.248 | 2.841 | - | 0.004 | - |
| Epic | no near field | 2.648 | 1.241 | - | 0.004 | - |
| Epic | no near field, no self shadow | 2.303 | 0.896 | - | 0.002 | - |
| Medium | + depth write | 2.928 | 1.521 | - | 0.004 | - |

Budget check: all presets within budget

GPU state: before: GPU utilisation 1 % max over 180 s, no other rendering Godot/Unreal process; tolerated while idle: UnrealEditor.exe. During: other rendering engines started: none. After: utilisation 0 %.
