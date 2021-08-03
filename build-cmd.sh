#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(pwd)"
stage="$(pwd)/stage"

mkdir -p $stage

# Load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

OPENJPEG_SOURCE_DIR="openjpeg"

VERSION_HEADER_FILE="$stage/include/openjpeg/opj_config_private.h"

build=${AUTOBUILD_BUILD_ID:=0}

# Create the staging folders
mkdir -p "$stage/lib"/{debug,release}
mkdir -p "$stage/include/openjpeg"
mkdir -p "$stage/LICENSES"

pushd "$OPENJPEG_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        # ------------------------ windows, windows64 ------------------------
        windows*)
            load_vsvars

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                archflags="/arch:SSE2"
            else
                archflags=""
            fi

            mkdir -p "build"
            pushd "build"
                cmake -E env CFLAGS="$archflags" CXXFLAGS="$archflags /std:c++17 /permissive-" \
                cmake .. -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$AUTOBUILD_WIN_VSPLATFORM" -DCMAKE_INSTALL_PREFIX=$stage -DLTO=ON
            
                cmake --build . --config Debug --clean-first
                cmake --build . --config Release --clean-first

                cp bin/Release/openjp2{.dll,.lib,.pdb} "$stage/lib/release"
                cp bin/Debug/openjp2{.dll,.lib,.pdb} "$stage/lib/debug"

                cp src/lib/openjp2/opj_config.h "$stage/include/openjpeg"

                # version will be (e.g.) "1.4.0"
                version=`sed -n -E 's/#define OPJ_PACKAGE_VERSION "([0-9])[.]([0-9])[.]([0-9]).*/\1.\2.\3/p' "src/lib/openjp2/opj_config_private.h"`
                # shortver will be (e.g.) "230": eliminate all '.' chars
                # since the libs do not use micro in their filenames, chop off shortver at minor
                short="$(echo $version | cut -d"." -f1-2)"
                shortver="${short//.}"

                echo "${version}" > "${stage}/VERSION.txt"
            popd

            cp src/lib/openjp2/openjpeg.h "$stage/include/openjpeg"
            cp src/lib/openjp2/opj_stdint.h "$stage/include/openjpeg"
        ;;
        darwin*)
            # Setup osx sdk platform
            SDKNAME="macosx"
            export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)
            export MACOSX_DEPLOYMENT_TARGET=10.13

            # Setup build flags
            ARCH_FLAGS="-arch x86_64"
            SDK_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
            DEBUG_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -O0 -g -msse4.2 -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Ofast -ffast-math -g -msse4.2 -fPIC -DPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"
            DEBUG_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"
            RELEASE_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"

            mkdir -p "$stage/include/openjpeg"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_debug"
            pushd "build_debug"
                CFLAGS="$DEBUG_CFLAGS" \
                CXXFLAGS="$DEBUG_CXXFLAGS" \
                CPPFLAGS="$DEBUG_CPPFLAGS" \
                LDFLAGS="$DEBUG_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$DEBUG_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$DEBUG_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="0" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
                    -DCMAKE_MACOSX_RPATH=YES -DCMAKE_INSTALL_PREFIX=$stage

                cmake --build . --config Debug

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi

                cp -a bin/Debug/libopenjp2*.a* "${stage}/lib/debug/"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$RELEASE_CFLAGS" \
                CXXFLAGS="$RELEASE_CXXFLAGS" \
                CPPFLAGS="$RELEASE_CPPFLAGS" \
                LDFLAGS="$RELEASE_LDFLAGS" \
                cmake .. -GXcode -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$RELEASE_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$RELEASE_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="fast" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_DEAD_CODE_STRIPPING=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
                    -DCMAKE_MACOSX_RPATH=YES -DCMAKE_INSTALL_PREFIX=$stage

                cmake --build . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cp -a bin/Release/libopenjp2*.a* "${stage}/lib/release/"

                cp src/lib/openjp2/opj_config.h "$stage/include/openjpeg"

                # version will be (e.g.) "1.4.0"
                version=`sed -n -E 's/#define OPJ_PACKAGE_VERSION "([0-9])[.]([0-9])[.]([0-9]).*/\1.\2.\3/p' "src/lib/openjp2/opj_config_private.h"`
                # shortver will be (e.g.) "230": eliminate all '.' chars
                # since the libs do not use micro in their filenames, chop off shortver at minor
                short="$(echo $version | cut -d"." -f1-2)"
                shortver="${short//.}"

                echo "${version}" > "${stage}/VERSION.txt"
            popd

            cp src/lib/openjp2/openjpeg.h "$stage/include/openjpeg"
            cp src/lib/openjp2/opj_stdint.h "$stage/include/openjpeg"
        ;;
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS
        
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
            SIMD_FLAGS="-msse -msse2 -msse3 -mssse3 -msse4 -msse4.1 -msse4.2 -mcx16 -mpopcnt -mpclmul -maes"
            DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC -DPIC $SIMD_FLAGS"
            RELEASE_COMMON_FLAGS="$opts -O3 -flto=thin -ffast-math -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 $SIMD_FLAGS"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC -D_FORTIFY_SOURCE=2"
            COMMON_LDFLAGS="-fuse-ld=lld"
 
            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Debug
            mkdir -p "build_debug"
            pushd "build_debug"
                CFLAGS="$DEBUG_CFLAGS" \
                CXXFLAGS="$DEBUG_CXXFLAGS" \
                CPPFLAGS="$DEBUG_CPPFLAGS" \
                    cmake ../ -G"Ninja" \
                        -DCMAKE_BUILD_TYPE=Debug \
                        -DCMAKE_C_FLAGS="$DEBUG_CFLAGS" \
                        -DCMAKE_CXX_FLAGS="$DEBUG_CXXFLAGS" \
                        -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS"
                        -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS"
                        -DCMAKE_INSTALL_PREFIX="$stage/install_debug"

                cmake --build . --config Debug --parallel $AUTOBUILD_CPU_COUNT -v
                cmake --install . --config Debug

                mkdir -p ${stage}/lib/debug
                mv ${stage}/install_debug/lib/*.so* ${stage}/lib/debug
                mv ${stage}/install_debug/lib/*.a* ${stage}/lib/debug
            popd

            # Release
            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$RELEASE_CFLAGS" \
                CXXFLAGS="$RELEASE_CXXFLAGS" \
                CPPFLAGS="$RELEASE_CPPFLAGS" \
                    cmake ../ -G"Ninja" \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS="$RELEASE_CFLAGS" \
                        -DCMAKE_CXX_FLAGS="$RELEASE_CXXFLAGS" \
                        -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS"
                        -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS"
                        -DCMAKE_INSTALL_PREFIX="$stage/install_release"

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                cmake --install . --config Release

                mkdir -p ${stage}/lib/release
                mv ${stage}/install_release/lib/*.so* ${stage}/lib/release
                mv ${stage}/install_release/lib/*.a* ${stage}/lib/release

                # version will be (e.g.) "1.4.0"
                version=`sed -n -E 's/#define OPJ_PACKAGE_VERSION "([0-9])[.]([0-9])[.]([0-9]).*/\1.\2.\3/p' "src/lib/openjp2/opj_config_private.h"`
                # shortver will be (e.g.) "230": eliminate all '.' chars
                # since the libs do not use micro in their filenames, chop off shortver at minor
                short="$(echo $version | cut -d"." -f1-2)"
                shortver="${short//.}"

                echo "${version}" > "${stage}/VERSION.txt"
            popd

            cp $stage/include/openjpeg-2.4/*.h "$stage/include/openjpeg"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp LICENSE "$stage/LICENSES/openjpeg.txt"
popd
