# TODO: the GADS native library for Android, Web, macOS and iOS

A brief for a Claude Code session running on the developer's own machine (Windows). Work on the
branch `claude/kind-lovelace-8rgsvw` of `M-Rocchinotti/godot-surface-displacement`; commit and
push there; do not open a pull request unless asked.

## Status (2026-10-09, Windows build host)

Done and verified at build level:

- **Android** arm64 + x86_64 `.so` built with NDK `28.1.13356709` (API 24) and **Web** wasm32
  (threaded) built with Emscripten **4.0.20** (matches the 4.7.2 web templates). All five
  committed binaries plus the two new Android ones and the Web one share source hash
  `550b27f6e07c8b97` (no native source was changed, so the Linux/Windows binaries did not need
  rebuilding and WSL was not required).
- `tools/build_native.py` has `android`, `web`, `web_nothreads`, `macos`, `ios` targets.
- `gads.gdextension` lists `android.arm64`, `android.x86_64` and `web.threads.wasm32`.
- Desktop logic tests pass (163/0), including the build-hash and native/GDScript parity checks.
- The demo exports to Web; Godot packages **only** `libgads.web...wasm32.wasm` into the threaded
  export, confirming the `web.threads.wasm32` tag matches. The demo overlay now shows "GADS:
  native library" / "GADS: GDScript fallback".

Pending (need hardware this build host does not have):

- **In-browser run of the Web export.** This host is headless for the GUI (browsers run on a
  separate machine that cannot reach this host's localhost, and a threaded build needs a secure
  context). Serve `build/web/` with COOP/COEP and open it on a machine with a browser; confirm the
  overlay reads "native library" and the Cliff scene's Tessellation view re-tessellates.
- **Android on-device run.** No device/emulator attached. Install the exported APK on a phone (or
  a Forward+-capable emulator) and run the same checks.
- **macOS / iOS** libraries: build on a Mac (`python tools/build_native.py macos ios`) and add
  `macos` / `ios` lines to `gads.gdextension`; left out here so a Mac export does not try to load
  a missing library. The nothreads Web variant (`web_nothreads`) is not built: it needs a native
  source change, which would force a rebuild of every platform (Linux via WSL).

## Why

GADS is a Godot 4.7 addon (`addons/gads/`). Its fast paths are a C++ GDExtension in `native/`
(the adaptive tessellator, procedural maps, erosion, terrain chunk builder), built with
godot-cpp into `addons/gads/native/bin/`. It ships today for **Windows x86_64, Linux x86_64 and
Linux ARM64** only (`addons/gads/native/gads.gdextension`).

Elsewhere GADS falls back to GDScript ports (`GADSTessellatorGD`, `GADSProceduralGD`): they bake,
generate and erode, 10-40 times slower, but **runtime view-dependent tessellation** (re-tessellating
a mesh around the moving camera: `GADSMeshInstance3D.view_dependent`, the manager's
`prop_geometry`, the Cliff demo scene) and **vector displacement** stay native-only, because a
GDScript refresh would take ~20 s. Building the same native library for the missing platforms
gives them everything at full speed. No GDScript change is needed for that: `GADSMeshBaker`,
`GADSProcedural` and `GADSTerrain3D` use the native classes whenever `ClassDB.class_exists()`
finds them.

## Goal

1. `python tools/build_native.py android` builds Android arm64 (and x86_64 for emulators).
2. `python tools/build_native.py web` builds the Web (wasm32) library.
3. `python tools/build_native.py macos` and `ios` build on a Mac (macOS universal, iOS arm64).
4. `addons/gads/native/gads.gdextension` lists every new library; the built ones are committed.
5. The demo, exported to Android and to the Web, reports the native library loaded and runs the
   Cliff scene's runtime tessellation.
6. Docs say which platforms ship the native library and how to build the others.

## Steps

### 0. Set up

- `git fetch && git checkout claude/kind-lovelace-8rgsvw && git pull`
- Python 3.10+, `pip install scons`, git, a C++ toolchain for the host (Visual Studio Build
  Tools on Windows: the existing `python tools/build_native.py windows` must still work).
- Godot 4.7.x editor (4.7.2 was used) and its export templates. Tell `tools/godot.py` where Godot
  is: environment variable `GODOT_BIN`, or one line in `tools/.godot_path` (git-ignored).
- Read first: `tools/build_native.py`, `native/SConstruct`, `addons/gads/native/gads.gdextension`,
  `native/src/tess/parallel.h`, and the README section "Building the native library".

### 1. Extend `tools/build_native.py`

godot-cpp (pinned at commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, cloned into
`native/godot-cpp` on first use) already knows these platforms; add targets that pass the right
SCons arguments, as `linux_arm64` does:

| Target | SCons arguments | Needs |
|---|---|---|
| `android` | `platform=android arch=arm64` (and a second run with `arch=x86_64`) | Android NDK; `ANDROID_HOME` (or `ANDROID_NDK_ROOT`) set. godot-cpp's `tools/android.py` names the NDK version it expects: install that one (Android Studio > SDK Manager > SDK Tools > NDK). |
| `web` | `platform=web` (threads on by default; consider also `threads=no`) | Emscripten: `emsdk install latest && emsdk activate latest`, then run from a shell with `emsdk_env` sourced so `emcc` is on PATH. |
| `macos` | `platform=macos arch=universal` | A Mac with Xcode command line tools. |
| `ios` | `platform=ios arch=arm64` | A Mac with Xcode. |

Keep the existing `target=template_release optimize=speed debug_symbols=no` arguments. Update the
script's docstring with the new targets and what each needs.

### 2. Register the libraries in `gads.gdextension`

Add a `[libraries]` line per new build. **Do not guess the feature tags and file names**: copy
them from godot-cpp's own test project at the pinned commit
(`native/godot-cpp/test/project/example.gdextension`, and `native/godot-cpp/test/SConstruct` for
how the macOS framework / iOS library is laid out), substituting `libgads` and
`res://addons/gads/native/bin/`. Expect entries like `android.arm64`, `android.x86_64`,
`web.wasm32` (and a `nothreads` variant if built), `macos`, `ios`.

### 3. Native code for the Web

`native/src/tess/parallel.h` runs work on `std::thread`. A threaded Web build works only when the
game is exported with thread support (and served with the COOP/COEP headers). For a `threads=no`
build, make `parallel_for` run serially there (e.g. `#if defined(__EMSCRIPTEN__) &&
!defined(__EMSCRIPTEN_PTHREADS__)` -> one thread). Search `native/src` for any other `std::thread`
use. Keep native results identical (the tests compare the GDScript ports with the native code).

**Important:** the library embeds a hash of `native/src` and `native/thirdparty`
(`GADSTessellator.get_build_hash()`), and the logic tests compare it with the sources. If any
native source changes, **every committed binary must be rebuilt** so they all carry the same hash:
Windows here; Linux x86_64 and ARM64 from Linux or WSL (`python tools/build_native.py linux
linux_arm64`, the ARM64 one needs `g++-aarch64-linux-gnu`); Android and Web from step 1. If a
platform cannot be rebuilt locally, say so in the hand-off instead of committing mismatched
binaries.

### 4. Verify

- Desktop: `python tests/run_all.py` (about 45 min, 14 suites, all passed before this work).
  At least run the logic tests: `python tools/godot.py --headless --script tests/run_logic_tests.gd`.
- Android: export the demo (`demo/demo_main.tscn`) with the Android preset (debug keystore is
  fine) and run it on a phone or emulator. Check `GADSMeshBaker.is_available()` is true (it is
  `get_capabilities()["native_library"]` on the scene's GADSManager), and that the Cliff scene
  shows runtime tessellation (the demo's "Tessellation" debug view).
- Web: export with the Web preset with **Extensions Support** (and Thread Support for a threaded
  build) enabled; serve it with `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp` (a few-line Python server; Godot's
  "Run in Browser" also serves them). Same checks as Android.
- Mobile and Web run the Low preset by default (`GADSManager.platform_caps`); check runtime
  tessellation budgets (`view_max_triangles`, `runtime_triangle_budget`) keep a phone at an
  acceptable frame rate, and lower the defaults for those platforms if not.
- `python tests/run_standalone_check.py`: the shipped addon archive still loads.

### 5. Docs

Update the platform list and fallback notes in `README.md` (Requirements, "Building the native
library", Limitations, the Features line "Bakes everywhere"), `addons/gads/README.md`,
`CHANGELOG.md` (an entry under 0.2.0 Added), `docs/ARCHITECTURE.md` if build details change,
and the GDScript doc comments that name the shipped platforms (`grep -rn Windows addons/gads`:
`gads_mesh_instance_3d.gd` line 24, `gads_mesh_baker.gd` line 59). Remove "macOS and Windows ARM builds" from the README Roadmap once done.

### 6. macOS and iOS without a Mac (optional)

They can only be compiled on macOS. Options: a Mac later (`python tools/build_native.py macos
ios`), or a GitHub Actions job on a `macos-*` runner triggered by hand (`workflow_dispatch`).
Note: the repository is private and its free Actions minutes ran out (CI jobs fail within seconds
without starting); macOS minutes count ten times. Prefer the Mac.

## Notes

- Commit messages in the repository's style (short subject, a paragraph on why).
- Do not change the GDScript fallbacks' behaviour or `GADSTessellatorGD.VERSION`.
- The `.os` / `.o` object files and `native/godot-cpp` are git-ignored; only the libraries in
  `addons/gads/native/bin/` are committed.
- Done means: the new targets build, their libraries are committed and listed, the desktop tests
  still pass, Android and Web exports run the demo natively, and the docs match.
