**BitChat Tor Build Notes**

- Date: See repo history for the commit you pulled
- Output: `tor-nolzma.xcframework` (static, C-only)
- Platforms: iOS device (arm64), iOS simulator (arm64), macOS (arm64)
- Goal: Minimize binary size while retaining client functionality

**Overview**
- We built a minimal Tor static xcframework with LZMA disabled to reduce size and complexity.
- The artifact contains only the C libraries (Tor + libevent + OpenSSL) and their headers. Objective‑C wrappers (`TORThread`, `TORController`, etc.) are not compiled into this minimal artifact to keep size down.
- This xcframework is suitable for iOS and macOS targets that link the Objective‑C wrappers as source (or use CocoaPods to bring them in).

**Component Versions**
- Tor: 0.4.8.21
- libevent: 2.1.12
- OpenSSL: 3.6.0
- liblzma: not linked (intentionally disabled)

**Build Environment**
- Xcode with iOS and macOS SDKs
- Homebrew tools: `autoconf`, `automake`, `libtool`, `gettext`
- Install prerequisites from repo root: `brew bundle`

**Command Used**
- Minimal build (nolzma), size-optimized: `./build-minimal.sh`
  - Build script located at: `~/Documents/vibe/Tor.framework-build/build-minimal.sh`
  - Uses iCepa/Tor.framework as base, with custom size optimizations
  - Outputs to: `~/Documents/vibe/Tor.framework-build/tor-nolzma.xcframework`

**What Minimal Mode Does**
- Targets: `iphoneos/arm64`, `iphonesimulator/arm64`, `macosx/arm64`.
- Disables LZMA in Tor (`--enable-lzma=no`) and removes zstd.
- Aggressive OpenSSL trimming (removes ~3MB per slice):
  - Protocol: `no-ssl3 no-tls1 no-tls1_1 no-dtls`
  - Legacy ciphers: `no-des no-rc2 no-rc4 no-rc5 no-idea no-seed no-camellia no-aria no-bf no-cast`
  - Unused hashes: `no-md4 no-mdc2 no-whirlpool no-rmd160`
  - Post-quantum: `no-ml-dsa no-ml-kem no-slh-dsa no-lms`
  - Chinese standards: `no-sm2 no-sm3 no-sm4`
  - Certificate features: `no-cms no-ts no-cmp no-ct no-rfc3779`
  - Other: `no-gost no-ec2m no-siphash no-scrypt no-legacy no-dso no-dgram no-http`
  - See build script for full list
- Tor client-only: `--disable-module-relay --disable-module-dirauth --disable-module-pow`
- Compiles with size-first flags: `-Os -ffunction-sections -fdata-sections`; bitcode is not embedded.
- Statically links Tor, libevent, and OpenSSL into a single library per slice inside the framework.
- Copies public headers from Tor/libevent/OpenSSL into the framework `Headers` directory.

**Resulting Slices (approx sizes)**
- Folder size: ~67 MB (`tor-nolzma.xcframework`)
- Binaries (non-fat, measured on this build):
  - iOS arm64 (device): ~14 MB
  - iOS arm64 (simulator): ~13.8 MB
  - macOS arm64: ~13.8 MB

Note: Sizes vary slightly by Xcode/SDK versions and environment.

**Integrating in BitChat**
- Add `tor-nolzma.xcframework` to your app target(s). Xcode will select the correct slice for device/simulator/macOS.
- Link `libz.tbd` (Tor depends on zlib).
- Keep app link-time stripping enabled for best results:
  - Other Linker Flags: add `-dead_strip`
  - Avoid `-ObjC` if possible (prevents dead stripping)
  - Consider enabling ThinLTO/LTO in the app for further size gains
- Objective‑C API (wrappers):
  - Not included in this minimal xcframework. Use one of:
    - CocoaPods: `Tor/CTor-NoLZMA` subspec (brings `TORThread`, `TORController` sources + links the xcframework), or
    - Vendor the ObjC sources from `Tor/Classes/CTor` and `Tor/Classes/Core` directly into your project.

**Rebuilding**
- Ensure prerequisites: `brew install automake autoconf libtool gettext`
- Clone iCepa/Tor.framework to `~/Documents/vibe/Tor.framework-build/`
- Run: `cd ~/Documents/vibe/Tor.framework-build && ./build-minimal.sh`
- Logs: `build/*.log` and per-component logs like `build/libtor-nolzma-<sdk>-<arch>.log`
- Copy output to project: `cp -R tor-nolzma.xcframework /path/to/bitchat/localPackages/Tor/Frameworks/`

**LZMA Trade‑off (for reference)**
- We measured that enabling LZMA adds roughly ~0.25 MB per slice to the binary on this setup. For a 3‑slice xcframework, expect ~0.7–0.8 MB more overall.
- If you want the LZMA variant with the same minimal trimming: `./build-xcframework.sh -Md` (outputs `tor.xcframework`).

**Key Flags (for auditing)**
- OpenSSL `./Configure` (aggressive trimming):
  - `no-shared no-zlib no-comp no-ssl3 no-tls1 no-tls1_1 no-dtls`
  - `no-srp no-psk no-weak-ssl-ciphers no-engine no-ocsp no-cms no-ts`
  - `no-idea no-seed no-camellia no-aria no-bf no-cast no-des no-rc2 no-rc4`
  - `no-md4 no-mdc2 no-whirlpool no-rmd160 no-sm2 no-sm3 no-sm4`
  - `no-siphash no-scrypt no-legacy no-dso no-dgram no-http`
- libevent `./configure`: `--disable-openssl --disable-samples --disable-libevent-regress --enable-static --disable-shared`
- Tor `./configure` (highlights):
  - `--enable-pic --disable-module-relay --disable-module-dirauth --disable-module-pow --disable-unittests`
  - `--enable-static-openssl --enable-static-libevent`
  - `--disable-asciidoc --disable-manpage --disable-html-manual --disable-zstd`
  - `--enable-lzma=no` (in this build)
- Compiler flags: `-Os -ffunction-sections -fdata-sections`; no bitcode
- Linker flags: `-Wl,-dead_strip`
- Minimum OS: iOS 12.0, macOS 10.13

**Verification Tips**
- Check slices: `lipo -info tor-nolzma.xcframework/*/tor-nolzma.framework/tor-nolzma`
- Ensure headers present: `ls tor-nolzma.xcframework/*/tor-nolzma.framework/Headers`
- Link test: build a small app and add `-dead_strip`; confirm successful run and circuit establishment via control port.

**Notes**
- This minimal build avoids bundling large GeoIP resources. If you need GeoIP, embed the GeoIP bundle (or use the `Tor/GeoIP-NoLZMA` subspec) and set `TORConfiguration.geoipFile`/`geoip6File`.
- Static linking maximizes the app’s ability to dead‑strip unused code across the boundary.

