# Native file dialog bridge

The app uses the NFDe v1.3.0 C ABI when a platform library is present. No
release packaging workflow or prebuilt NFDe library exists in this repository,
so the bridge is not bundled. The ROM drop path remains available and the app
reports the missing bridge when the picker is requested.

To build a desktop library, use the matching OS and architecture toolchain.
NFDe's GTK build on Linux needs `libgtk-3-dev`; its macOS build links AppKit and
UniformTypeIdentifiers. See the upstream v1.3.0 build notes for platform
requirements and Visual Studio setup:
<https://github.com/btzy/nativefiledialog-extended/tree/v1.3.0#building>.

```sh
git clone --depth 1 --branch v1.3.0 https://github.com/btzy/nativefiledialog-extended.git
cmake -S nativefiledialog-extended -B nativefiledialog-extended/build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DNFD_BUILD_TESTS=OFF
cmake --build nativefiledialog-extended/build --config Release
```

Copy the resulting shared library into the matching app-owned location:

| OS | Architecture | Path |
| --- | --- | --- |
| Linux | x64 | `app/native/linux/x64/libnfd.so` |
| Linux | arm64 | `app/native/linux/arm64/libnfd.so` |
| Windows | x64 | `app/native/windows/x64/nfd.dll` |
| Windows | arm64 | `app/native/windows/arm64/nfd.dll` |
| macOS | x64 | `app/native/macos/x64/libnfd.dylib` |
| macOS | arm64 | `app/native/macos/arm64/libnfd.dylib` |

Each release that includes a bridge must also ship [LICENSE](LICENSE). Verify
the C ABI and open/cancel/error cleanup on that exact packaged library before
claiming native-picker support. Android and iOS use drag-and-drop only.
