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

            mkdir -p "build"
            pushd "build"
                cmake .. -G "Ninja Multi-Config" -DCMAKE_INSTALL_PREFIX=$stage -DCMAKE_C_STANDARD=17 \
                    -DBUILD_CODEC=OFF
            
                cmake --build . --config Debug
                cmake --build . --config Release

                cp bin/Release/openjp2{.dll,.lib,.pdb} "$stage/lib/release"
                cp bin/Debug/openjp2{.dll,.lib,.pdb} "$stage/lib/debug"

                cp src/lib/openjp2/opj_config.h "$stage/include/openjpeg"

                # version will be (e.g.) "2.4.0"
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
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            mkdir -p "$stage/include/openjpeg"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -G Ninja -DBUILD_CODEC=OFF -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_x86"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi
            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -G Ninja -DBUILD_CODEC=OFF -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=arm64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_arm64"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                # version will be (e.g.) "1.4.0"
                version=`sed -n -E 's/#define OPJ_PACKAGE_VERSION "([0-9])[.]([0-9])[.]([0-9]).*/\1.\2.\3/p' "src/lib/openjp2/opj_config_private.h"`
                # shortver will be (e.g.) "230": eliminate all '.' chars
                # since the libs do not use micro in their filenames, chop off shortver at minor
                short="$(echo $version | cut -d"." -f1-2)"
                shortver="${short//.}"

                echo "${version}" > "${stage}/VERSION.txt"
            popd

            # create fat libs
            lipo -create ${stage}/release_x86/lib/libopenjp2.a ${stage}/release_arm64/lib/libopenjp2.a -output ${stage}/lib/release/libopenjp2.a

            # copy includes
            cp -a $stage/release_x86/include/openjpeg-*/*.h $stage/include/openjpeg/


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
        
            # Default target per autobuild build --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"

            # Release
            mkdir -p "build"
            pushd "build"
                CFLAGS="$opts_c" \
                CXXFLAGS="$opts_cxx" \
                    cmake ../ -G"Ninja" \
                        -DCMAKE_BUILD_TYPE=Release -DBUILD_CODEC=OFF \
                        -DCMAKE_C_FLAGS="$opts_c" \
                        -DCMAKE_CXX_FLAGS="$opts_cxx" \
                        -DCMAKE_INSTALL_PREFIX="$stage/install_release"

                cmake --build . --config Release
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

            cp $stage/install_release/include/openjpeg-*/*.h "$stage/include/openjpeg"
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp LICENSE "$stage/LICENSES/openjpeg.txt"
popd
