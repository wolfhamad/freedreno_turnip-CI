#!/bin/bash -e

# Builds Mesa's v3dv (Raspberry Pi 5 Vulkan driver) for Android with the NDK,
# applies v3dv-descriptor-indexing-diag.patch, and packs the result as a raw
# HAL library, a Magisk module and an adrenotools package.
#
# Optional environment variables:
#   MESA_REF    Mesa branch or tag to build        (default: main)
#   SDKVER      Android SDK/API level              (default: 36)
#   HAL_NAME    value of ro.hardware.vulkan        (default: broadcom)
#   NDKVER      NDK release name                   (default: android-ndk-r29)
#   LIBDRM_REF  libdrm branch or tag               (default: main)
#   PATCHFILE   patch to apply to Mesa             (default: ./v3dv-descriptor-indexing-diag.patch)

# The shebang's -e is ignored when the script is started as "bash ./script",
# so set it here too: any failing command must stop the build.
set -e

# Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl flex bison zip git ccache"
repodir="$(pwd)"
workdir="$repodir/v3dv_workdir"
magiskdir="$workdir/v3dv_module"
prefix="$workdir/deps-prefix"
mesadir="$workdir/mesa-main"
libdrmdir="$workdir/libdrm-src"

patchfile="${PATCHFILE:-$repodir/v3dv-descriptor-indexing-diag.patch}"
ndkver="${NDKVER:-android-ndk-r29}"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="${SDKVER:-36}"
halname="${HAL_NAME:-broadcom}"
mesaref="${MESA_REF:-main}"
libdrmref="${LIBDRM_REF:-main}"

mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/$mesaref/mesa-$mesaref.zip"
libdrmsrc="https://gitlab.freedesktop.org/mesa/libdrm/-/archive/$libdrmref/libdrm-$libdrmref.zip"

libname="vulkan.$halname.so"

# There are several functions here, simply comment to disable.
run_all(){
	check_deps
	prepare_workdir
	setup_toolchain
	build_libdrm
	apply_patch
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
}

# Runs a command with its output in a log file; prints the log tail on failure.
run_logged(){
	local log="$1"
	shift
	if ! "$@" &> "$log"; then
		echo -e "$red Command failed: $* $nocolor"
		tail -n 80 "$log"
		exit 1
	fi
}

# Downloads a zip, extracts it and renames its top directory.
fetch_zip(){
	local url="$1" zipfile="$2" dest="$3" tmp
	tmp="$(mktemp -d "$workdir/extract.XXXXXX")"
	curl -fL --retry 3 "$url" --output "$zipfile"
	unzip -q -o "$zipfile" -d "$tmp"
	rm -rf "$dest"
	mv "$tmp"/* "$dest"
	rmdir "$tmp"
}

check_deps(){
	echo "Checking system for required Dependencies ..."
	local deps_missing=0
	for deps_chk in $deps; do
		if command -v "$deps_chk" >/dev/null 2>&1; then
			echo -e "$green - $deps_chk found $nocolor"
		else
			echo -e "$red - $deps_chk not found, can't continue. $nocolor"
			deps_missing=1
		fi
	done

	if ! python3 -c "import mako, yaml" 2>/dev/null; then
		echo "Installing python Mako/PyYAML dependencies (if missing) ..."
		pip install --break-system-packages mako pyyaml &> /dev/null || true
		if ! python3 -c "import mako, yaml" 2>/dev/null; then
			echo -e "$red - python mako/yaml modules not found $nocolor"
			deps_missing=1
		fi
	fi

	if [ "$deps_missing" == "1" ]; then
		echo "Please install missing dependencies" && exit 1
	fi

	if ! [ -f "$patchfile" ]; then
		echo -e "$red Patch file not found: $patchfile $nocolor" && exit 1
	fi
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
	mkdir -p "$workdir"
	cd "$workdir"

	echo "Downloading android-ndk from google server ..." $'\n'
	curl -fL --retry 3 "https://dl.google.com/android/repository/$ndkver-linux.zip" --output "$ndkver-linux.zip"
	echo "Extracting android-ndk ..." $'\n'
	unzip -q -o "$ndkver-linux.zip"

	echo "Downloading mesa source ($mesaref) ..." $'\n'
	fetch_zip "$mesasrc" mesa-src.zip "$mesadir"

	echo "Downloading libdrm source ($libdrmref) ..." $'\n'
	fetch_zip "$libdrmsrc" libdrm-src.zip "$libdrmdir"
}

setup_toolchain(){
	cd "$workdir"

	# Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin" "$prefix/lib/pkgconfig"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating meson cross/native files ..." $'\n'
	cat <<EOF >"$workdir/android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '-Wno-error=c++11-narrowing']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	cat <<EOF >"$workdir/native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

# v3dv needs libdrm and the NDK doesn't ship it, so build it statically into
# a private prefix that Mesa's meson finds through pkg-config.
build_libdrm(){
	echo "Building libdrm for android ..." $'\n'
	cd "$libdrmdir"

	run_logged "$workdir/libdrm_meson_log" \
		meson setup build-android-aarch64 \
		--cross-file "$workdir/android-aarch64.txt" \
		--native-file "$workdir/native.txt" \
		--prefix "$prefix" \
		--libdir lib \
		-Dbuildtype=release \
		-Ddefault_library=static \
		-Dintel=disabled \
		-Dradeon=disabled \
		-Damdgpu=disabled \
		-Dnouveau=disabled \
		-Dvmwgfx=disabled \
		-Dvc4=disabled \
		-Detnaviv=disabled \
		-Dexynos=disabled \
		-Domap=disabled \
		-Dtegra=disabled \
		-Dudev=false \
		-Dcairo-tests=disabled \
		-Dvalgrind=disabled \
		-Dman-pages=disabled

	run_logged "$workdir/libdrm_ninja_log" ninja -C build-android-aarch64 install
}

# Applies the descriptor-indexing / diagnostics patch to the Mesa tree.
apply_patch(){
	echo "Applying $(basename "$patchfile") to mesa ..." $'\n'
	cd "$mesadir"
	if ! git apply --check "$patchfile"; then
		echo -e "$red The patch no longer applies to Mesa '$mesaref'. $nocolor"
		echo "Re-create the patch against this Mesa version, or build an older MESA_REF."
		exit 1
	fi
	git apply --verbose "$patchfile"
}

build_lib_for_android(){
	cd "$mesadir"

	echo "Generating build files ..." $'\n'
	run_logged "$workdir/meson_log" \
		meson setup build-android-aarch64 \
		--cross-file "$workdir/android-aarch64.txt" \
		--native-file "$workdir/native.txt" \
		-Dbuildtype=release \
		-Dplatforms=android \
		-Dplatform-sdk-version="$sdkver" \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=broadcom \
		-Dllvm=disabled \
		-Db_lto=true \
		-Dstrip=true

	echo "Compiling build files ..." $'\n'
	run_logged "$workdir/ninja_log" ninja -C build-android-aarch64

	if ! [ -a "$mesadir"/build-android-aarch64/src/broadcom/vulkan/libvulkan_broadcom.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi

	echo "Shared library dependencies of the built driver:" $'\n'
	"$ndk/llvm-readelf" -d "$mesadir"/build-android-aarch64/src/broadcom/vulkan/libvulkan_broadcom.so | grep -E 'NEEDED|SONAME|RPATH|RUNPATH' || true
}

port_lib_for_magisk(){
	echo "Using patchelf to match soname ..." $'\n'
	cp "$mesadir"/build-android-aarch64/src/broadcom/vulkan/libvulkan_broadcom.so "$workdir/$libname"
	cd "$workdir"
	patchelf --set-soname "$libname" "$libname"

	echo "Prepare magisk module structure ..." $'\n'
	p1="system/vendor/lib64/hw"
	mkdir -p "$magiskdir"
	cd "$magiskdir"
	mkdir -p "$p1"

	meta="META-INF/com/google/android"
	mkdir -p "$meta"

	cat <<EOF >"$meta/update-binary"
#################
# Initialization
#################

umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3

. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

	cat <<EOF >"$meta/updater-script"
#MAGISK
EOF

	cat <<EOF >"module.prop"
id=v3dv
name=v3dv (descriptor indexing diagnostic)
version=$(cat "$mesadir"/VERSION)
versionCode=1
author=wolfhamad (based on freedreno_turnip-CI)
description=Mesa v3dv Vulkan driver for Raspberry Pi 5. Diagnostic build, not a stock driver.
EOF

	cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$p1/$libname 0 0 0644 u:object_r:same_process_hal_file:s0
EOF

	echo "Copy necessary files from work directory ..." $'\n'
	cp "$workdir/$libname" "$magiskdir/$p1"

	echo "Packing files in to magisk module ..." $'\n'
	zip -r "$workdir"/v3dv.zip ./* &> /dev/null

	if ! [ -a "$workdir"/v3dv.zip ]; then
		echo -e "$red-Packing failed!$nocolor" && exit 1
	else
		echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/v3dv.zip
	fi
}

port_lib_for_adrenotools(){
	cd "$workdir"

	echo "Preparing meta.json" $'\n'
	cat <<EOF > "meta.json"
{
  "schemaVersion": 1,
  "name": "v3dv-descriptor-indexing-diag",
  "description": "$(date)",
  "author": "wolfhamad",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$(cat "$mesadir"/VERSION)",
  "minApi": $sdkver,
  "libraryName": "$libname"
}
EOF

	zip -9 "$workdir"/v3dv_adrenotools.zip "$libname" meta.json &> /dev/null

	if ! [ -a "$workdir"/v3dv_adrenotools.zip ]; then
		echo -e "$red-Packing v3dv_adrenotools.zip failed!$nocolor" && exit 1
	else
		echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/v3dv_adrenotools.zip
	fi
}

run_all
