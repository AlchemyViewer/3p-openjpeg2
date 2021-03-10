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

OPENJPEG_SOURCE_DIR="openjpeg2"

VERSION_HEADER_FILE="$OPENJPEG_SOURCE_DIR/libopenjpeg/openjpeg.h"

build=${AUTOBUILD_BUILD_ID:=0}

# version will be (e.g.) "1.4.0"
version=`sed -n -E 's/#define OPENJPEG_VERSION "([0-9])[.]([0-9])[.]([0-9]).*/\1.\2.\3/p' "${VERSION_HEADER_FILE}"`
# shortver will be (e.g.) "230": eliminate all '.' chars
#since the libs do not use micro in their filenames, chop off shortver at minor
short="$(echo $version | cut -d"." -f1-2)"
shortver="${short//.}"

echo "${version}.${build}" > "${stage}/VERSION.txt"

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

                cp bin/Release/openjpeg{.dll,.lib,.pdb} "$stage/lib/release"
                cp bin/Debug/openjpeg{.dll,.lib,.pdb} "$stage/lib/debug"
            popd
            cp libopenjpeg/openjpeg.h "$stage/include/openjpeg-1.5"
            cp libopenjpeg/opj_stdint.h "$stage/include/openjpeg-1.5"
        ;;
        "darwin64")
            cmake . -GXcode -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                -DBUILD_SHARED_LIBS:BOOL=ON -DBUILD_CODEC:BOOL=ON -DUSE_LTO:BOOL=ON \
                -DCMAKE_OSX_DEPLOYMENT_TARGET=10.8 -DCMAKE_INSTALL_PREFIX=$stage
            xcodebuild -configuration Release -sdk macosx10.11 \
                -target openjpeg -project openjpeg.xcodeproj
            xcodebuild -configuration Release -sdk macosx10.11 \
                -target install -project openjpeg.xcodeproj
            install_name_tool -id "@executable_path/../Resources/libopenjpeg.dylib" "${stage}/lib/libopenjpeg.5.dylib"

            cp "${stage}"/lib/libopenjpeg.* "${stage}/lib/release/"
            cp "libopenjpeg/openjpeg.h" "${stage}/include/openjpeg-1.5"
            cp "libopenjpeg/opj_stdint.h" "${stage}/include/openjpeg-1.5"
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
            unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
            DEBUG_COMMON_FLAGS="$opts -Og -msse2 -g -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$opts -O3 -msse2 -ffast-math -g -fPIC -DPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"

            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi

            autoreconf -fvi

            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"

            # Debug first
            export PKG_CONFIG_PATH="$stage/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$DEBUG_CFLAGS" CXXFLAGS="$DEBUG_CXXFLAGS" CPPFLAGS="$DEBUG_CPPFLAGS" \
                ./configure --enable-png=no --enable-lcms1=no --enable-lcms2=no --enable-tiff=no \
                    --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include" --libdir="\${prefix}/lib/debug"
            make -j$JOBS
            make install DESTDIR="$stage"

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make test
            # fi

            # clean the build artifacts
            make distclean

            # Release last
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"

            CFLAGS="$RELEASE_CFLAGS" CXXFLAGS="$RELEASE_CXXFLAGS" CPPFLAGS="$RELEASE_CPPFLAGS" \
                ./configure --enable-png=no --enable-lcms1=no --enable-lcms2=no --enable-tiff=no \
                    --prefix="\${AUTOBUILD_PACKAGES_DIR}" --includedir="\${prefix}/include" --libdir="\${prefix}/lib/release"
            make -j$JOBS
            make install DESTDIR="$stage"

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make test
            # fi

            # clean the build artifacts
            make distclean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp LICENSE "$stage/LICENSES/openjpeg.txt"
popd
