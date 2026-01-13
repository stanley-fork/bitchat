#!/bin/sh
# Minimal size-optimized build script for BitChat
# Builds arm64-only tor-nolzma.xcframework with aggressive size optimization

set -e

PATH=$PATH:/usr/local/bin:/usr/local/opt/gettext/bin:/usr/local/opt/automake/bin:/usr/local/opt/aclocal/bin:/opt/homebrew/bin:/opt/homebrew/opt/libtool/libexec/gnubin

OPENSSL_VERSION="openssl-3.6.0"
LIBEVENT_VERSION="release-2.1.12-stable"
TOR_VERSION="tor-0.4.8.21"

cd "$(dirname "$0")"
ROOT="$(pwd -P)"

BUILDDIR="$ROOT/build"
mkdir -p "$BUILDDIR"

echo "Build dir: $BUILDDIR"
echo "Building minimal tor-nolzma.xcframework (arm64-only, size-optimized)"
echo ""

# Size optimization flags
# Note: LTO (-flto=thin) disabled because it produces bitcode that xcodebuild can't read
# LTO would need to be applied at app link stage, not library build
SIZE_CFLAGS="-Os -ffunction-sections -fdata-sections"

build_libssl() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/openssl"
    LOG="$BUILDDIR/libssl-$SDK-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out OpenSSL project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$OPENSSL_VERSION" https://github.com/openssl/openssl.git >> "$LOG" 2>&1
    fi

    echo "- Build OpenSSL for $ARCH ($SDK) [size-optimized]"

    cd "$SOURCE"
    make distclean >> "$LOG" 2>&1 || true

    if [ "$SDK" = "iphoneos" ]; then
        PLATFORM_FLAGS="no-async zlib-dynamic enable-ec_nistp_64_gcc_128"
        CONFIG="ios64-xcrun"
    elif [ "$SDK" = "iphonesimulator" ]; then
        PLATFORM_FLAGS="no-async zlib-dynamic enable-ec_nistp_64_gcc_128"
        CONFIG="iossimulator-xcrun"
    elif [ "$SDK" = "macosx" ]; then
        PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
        CONFIG="darwin64-arm64-cc"
    fi

    # Tier 2: Aggressive OpenSSL trimming - remove unused ciphers, hashes, and features
    ./Configure \
        no-shared \
        no-zlib \
        no-comp \
        no-ssl3 \
        no-tls1 \
        no-tls1_1 \
        no-dtls \
        no-srp \
        no-psk \
        no-weak-ssl-ciphers \
        no-engine \
        no-ocsp \
        no-cms \
        no-ts \
        no-idea \
        no-seed \
        no-camellia \
        no-aria \
        no-bf \
        no-cast \
        no-des \
        no-rc2 \
        no-rc4 \
        no-md4 \
        no-mdc2 \
        no-whirlpool \
        no-rmd160 \
        no-sm2 \
        no-sm3 \
        no-sm4 \
        no-siphash \
        no-scrypt \
        no-legacy \
        no-dso \
        no-dgram \
        no-http \
        no-ml-dsa \
        no-ml-kem \
        no-slh-dsa \
        no-lms \
        no-cmp \
        no-ct \
        no-gost \
        no-rfc3779 \
        no-ec2m \
        no-rc5 \
        ${PLATFORM_FLAGS} \
        --prefix="$BUILDDIR/$SDK/libssl-$ARCH" \
        ${CONFIG} \
        CC="$(xcrun --sdk $SDK --find clang) -isysroot $(xcrun --sdk $SDK --show-sdk-path) -arch ${ARCH} -m$SDK-version-min=$MIN $SIZE_CFLAGS" \
        >> "$LOG" 2>&1

    make depend >> "$LOG" 2>&1
    make "-j$(sysctl -n hw.logicalcpu_max)" build_libs >> "$LOG" 2>&1
    make install_dev >> "$LOG" 2>&1
}

build_libevent() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/libevent"
    LOG="$BUILDDIR/libevent-$SDK-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out libevent project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$LIBEVENT_VERSION" https://github.com/libevent/libevent.git >> "$LOG" 2>&1
    fi

    echo "- Build libevent for $ARCH ($SDK) [size-optimized]"

    cd "$SOURCE"
    make distclean 2>/dev/null 1>/dev/null || true

    if [ ! -f ./configure ]; then
        ./autogen.sh >> "$LOG" 2>&1
    fi

    CLANG="$(xcrun -f --sdk ${SDK} clang)"
    SDKPATH="$(xcrun --sdk ${SDK} --show-sdk-path)"
    DEST="$BUILDDIR/$SDK/libevent-$ARCH"

    ./configure \
        --disable-shared \
        --disable-openssl \
        --disable-libevent-regress \
        --disable-samples \
        --disable-doxygen-html \
        --enable-static \
        --disable-debug-mode \
        --prefix="$DEST" \
        CC="$CLANG -arch ${ARCH}" \
        CPP="$CLANG -E -arch ${ARCH}" \
        CFLAGS="-isysroot ${SDKPATH} -m$SDK-version-min=$MIN $SIZE_CFLAGS" \
        LDFLAGS="-isysroot ${SDKPATH} -L$DEST" \
        cross_compiling="yes" \
        ac_cv_func_clock_gettime="no" \
        >> "$LOG" 2>&1

    make -j$(sysctl -n hw.logicalcpu_max) >> "$LOG" 2>&1
    make install >> "$LOG" 2>&1
}

build_libtor_nolzma() {
    SDK=$1
    ARCH=$2
    MIN=$3

    SOURCE="$BUILDDIR/tor"
    LOG="$BUILDDIR/libtor-nolzma-$SDK-$ARCH.log"
    DEST="$BUILDDIR/$SDK/libtor-nolzma-$ARCH"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out Tor project"
        cd "$BUILDDIR"
        git clone --recursive --shallow-submodules --depth 1 --branch "$TOR_VERSION" https://gitlab.torproject.org/tpo/core/tor.git >> "$LOG" 2>&1
    fi

    echo "- Build libtor-nolzma for $ARCH ($SDK) [size-optimized, client-only]"

    cd "$SOURCE"
    make distclean 2>/dev/null 1>/dev/null || true

    # Apply patch if exists
    if [ -f "$ROOT/Tor/mmap-cache.patch" ]; then
        git checkout . 2>/dev/null || true
        git apply --quiet "$ROOT/Tor/mmap-cache.patch" 2>/dev/null || true
    fi

    if [ ! -f ./configure ]; then
        sed -i'.backup' -e 's/all,error/no-obsolete,error/' autogen.sh
        ./autogen.sh >> "$LOG" 2>&1
        rm autogen.sh && mv autogen.sh.backup autogen.sh
    fi

    CLANG="$(xcrun -f --sdk ${SDK} clang)"
    SDKPATH="$(xcrun --sdk ${SDK} --show-sdk-path)"

    # Tier 1 + 2: Client-only, minimal Tor build with aggressive size optimization
    ./configure \
        --enable-silent-rules \
        --enable-pic \
        --disable-module-relay \
        --disable-module-dirauth \
        --disable-module-pow \
        --disable-tool-name-check \
        --disable-unittests \
        --enable-static-openssl \
        --enable-static-libevent \
        --disable-asciidoc \
        --disable-system-torrc \
        --disable-linker-hardening \
        --disable-dependency-tracking \
        --disable-manpage \
        --disable-html-manual \
        --disable-gcc-warnings-advisory \
        --enable-lzma=no \
        --disable-zstd \
        --with-libevent-dir="$BUILDDIR/$SDK/libevent-$ARCH" \
        --with-openssl-dir="$BUILDDIR/$SDK/libssl-$ARCH" \
        --prefix="$DEST" \
        CC="$CLANG -arch ${ARCH} -isysroot ${SDKPATH}" \
        CPP="$CLANG -E -arch ${ARCH} -isysroot ${SDKPATH}" \
        CFLAGS="$SIZE_CFLAGS -m$SDK-version-min=$MIN" \
        CPPFLAGS="-Isrc/core -I$BUILDDIR/$SDK/libssl-$ARCH/include -I$BUILDDIR/$SDK/libevent-$ARCH/include -m$SDK-version-min=$MIN" \
        LDFLAGS="-lz -Wl,-dead_strip" \
        cross_compiling="yes" \
        ac_cv_func__NSGetEnviron="no" \
        ac_cv_func_clock_gettime="no" \
        ac_cv_func_getentropy="no" \
        >> "$LOG" 2>&1

    sleep 2
    rm -f src/lib/cc/orconfig.h >> "$LOG" 2>&1
    cp orconfig.h "src/lib/cc/" >> "$LOG" 2>&1

    make libtor.a -j$(sysctl -n hw.logicalcpu_max) V=1 >> "$LOG" 2>&1

    mkdir -p "$DEST/lib" >> "$LOG" 2>&1
    mkdir -p "$DEST/include" >> "$LOG" 2>&1
    mv libtor.a "$DEST/lib" >> "$LOG" 2>&1
    rsync --archive --include='*.h' -f 'hide,! */' --prune-empty-dirs src/* "$DEST/include" >> "$LOG" 2>&1
    cp orconfig.h "$DEST/include/" >> "$LOG" 2>&1
    mv micro-revision.i "$DEST" >> "$LOG" 2>&1
}

create_framework_nolzma() {
    SDK=$1

    LOG="$BUILDDIR/framework.log"
    NAME="tor-nolzma"

    rm -rf "$BUILDDIR/$SDK/$NAME.framework" >> "$LOG" 2>&1

    echo "- Create framework for $SDK (arm64-only)"

    LIBS=("$BUILDDIR/$SDK/libssl-arm64/lib/libssl.a" \
        "$BUILDDIR/$SDK/libssl-arm64/lib/libcrypto.a" \
        "$BUILDDIR/$SDK/libevent-arm64/lib/libevent.a" \
        "$BUILDDIR/$SDK/libtor-nolzma-arm64/lib/libtor.a")

    HEADERS=("$BUILDDIR/$SDK/libssl-arm64/include"/* \
        "$BUILDDIR/$SDK/libevent-arm64/include"/* \
        "$BUILDDIR/$SDK/libtor-nolzma-arm64/include"/*)

    if [ "$SDK" = "macosx" ]; then
        # macOS frameworks need versioned bundle structure
        mkdir -p "$BUILDDIR/$SDK/$NAME.framework/Versions/A/Headers" >> "$LOG" 2>&1
        mkdir -p "$BUILDDIR/$SDK/$NAME.framework/Versions/A/Resources" >> "$LOG" 2>&1

        libtool -static -o "$BUILDDIR/$SDK/$NAME.framework/Versions/A/$NAME" "${LIBS[@]}" >> "$LOG" 2>&1
        cp -r "${HEADERS[@]}" "$BUILDDIR/$SDK/$NAME.framework/Versions/A/Headers" >> "$LOG" 2>&1

        # Create symlinks
        cd "$BUILDDIR/$SDK/$NAME.framework"
        ln -s A Versions/Current
        ln -s Versions/Current/Headers Headers
        ln -s Versions/Current/Resources Resources
        ln -s Versions/Current/$NAME $NAME

        # Create Info.plist for macOS
        cat > Versions/A/Resources/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tor-nolzma</string>
    <key>CFBundleIdentifier</key>
    <string>org.torproject.tor-nolzma</string>
    <key>CFBundleName</key>
    <string>tor-nolzma</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.8.21</string>
    <key>CFBundleVersion</key>
    <string>408.21</string>
    <key>MinimumOSVersion</key>
    <string>10.13</string>
</dict>
</plist>
PLIST
        cd "$ROOT"
    else
        # iOS frameworks are flat
        mkdir -p "$BUILDDIR/$SDK/$NAME.framework/Headers" >> "$LOG" 2>&1
        libtool -static -o "$BUILDDIR/$SDK/$NAME.framework/$NAME" "${LIBS[@]}" >> "$LOG" 2>&1
        cp -r "${HEADERS[@]}" "$BUILDDIR/$SDK/$NAME.framework/Headers" >> "$LOG" 2>&1

        # Determine min OS version for Info.plist
        if [ "$SDK" = "iphoneos" ] || [ "$SDK" = "iphonesimulator" ]; then
            MIN_OS="12.0"
        else
            MIN_OS="10.13"
        fi

        # Create Info.plist for iOS
        cat > "$BUILDDIR/$SDK/$NAME.framework/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tor-nolzma</string>
    <key>CFBundleIdentifier</key>
    <string>org.torproject.tor-nolzma</string>
    <key>CFBundleName</key>
    <string>tor-nolzma</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.8.21</string>
    <key>CFBundleVersion</key>
    <string>408.21</string>
    <key>MinimumOSVersion</key>
    <string>$MIN_OS</string>
</dict>
</plist>
PLIST
    fi
}

create_xcframework_nolzma() {
    LOG="$BUILDDIR/framework.log"
    NAME="tor-nolzma"

    echo "- Create xcframework for $NAME (arm64-only)"

    rm -rf "$ROOT/$NAME.xcframework" "$ROOT/$NAME.xcframework.zip" >> "$LOG" 2>&1

    xcodebuild -create-xcframework \
        -framework "$BUILDDIR/iphoneos/$NAME.framework" \
        -framework "$BUILDDIR/iphonesimulator/$NAME.framework" \
        -framework "$BUILDDIR/macosx/$NAME.framework" \
        -output "$ROOT/$NAME.xcframework" >> "$LOG" 2>&1

    echo ""
    echo "=== Build Complete ==="
    echo "Output: $ROOT/$NAME.xcframework"
    echo ""

    # Show sizes
    echo "Binary sizes:"
    ls -lh "$ROOT/$NAME.xcframework/ios-arm64/$NAME.framework/$NAME" 2>/dev/null || true
    ls -lh "$ROOT/$NAME.xcframework/ios-arm64-simulator/$NAME.framework/$NAME" 2>/dev/null || true
    ls -lh "$ROOT/$NAME.xcframework/macos-arm64/$NAME.framework/$NAME" 2>/dev/null || true

    echo ""
    du -sh "$ROOT/$NAME.xcframework"
}

# Build for iOS device (arm64)
echo "=== Building for iOS device (arm64) ==="
build_libssl      iphoneos        arm64   12.0
build_libevent    iphoneos        arm64   12.0
build_libtor_nolzma iphoneos      arm64   12.0
create_framework_nolzma iphoneos

# Build for iOS simulator (arm64 only - no Intel)
echo ""
echo "=== Building for iOS simulator (arm64) ==="
build_libssl      iphonesimulator arm64   12.0
build_libevent    iphonesimulator arm64   12.0
build_libtor_nolzma iphonesimulator arm64 12.0
create_framework_nolzma iphonesimulator

# Build for macOS (arm64 only - no Intel)
echo ""
echo "=== Building for macOS (arm64) ==="
build_libssl      macosx          arm64   10.13
build_libevent    macosx          arm64   10.13
build_libtor_nolzma macosx        arm64   10.13
create_framework_nolzma macosx

# Create xcframework
echo ""
echo "=== Creating XCFramework ==="
create_xcframework_nolzma

echo ""
echo "Done! To verify:"
echo "  lipo -info $ROOT/tor-nolzma.xcframework/*/tor-nolzma.framework/tor-nolzma"
