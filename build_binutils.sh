#!/usr/bin/env bash

# safer bash
set -o errexit
set -o pipefail
set -o nounset

# Provide the version of binutils being built
binutils_version=${1}
if [[ -z "$binutils_version" ]]; then
  binutils_version=2.42
fi

start_time=$(date +%s)

# Additional makefile options.  E.g., "-j 4" for parallel builds.  Parallel
# builds are faster, however it can cause a build to fail if the project
# makefile does not support parallel build.
make_flags="-j $(nproc)"

# Architecture we are building for.
arch_flags="-march=x86-64"

# Target linux/gnu
build_target=x86_64-unknown-linux-gnu


install_dir=$PWD/stage/binutils-${binutils_version}
build_dir=$PWD/binutils-${binutils_version}_build
source_dir=$PWD/binutils-${binutils_version}_source
tarfile_dir=$PWD/binutils-${binutils_version}_taballs
gcc_tarfile_dir=$PWD/gcc_taballs
gcc_toolchain_dir="$PWD/gcc"

if git config --get user.name &>/dev/null && git config --get user.email &>/dev/null; then
  packageversion="$(git config --get user.name) <$(git config --get user.email)>"
else
  packageversion="$(hostname) $(date '+%Y/%m/%d %H:%M:%S')"
fi

__die()
{
    echo $*
    exit 1
}


__banner()
{
    echo "============================================================"
    echo $*
    echo "============================================================"
}


__untar()
{
    dir="$1";
    file="$2"
    case $file in
        *xz)
            tar xJ -C "$dir" -f "$file"
            ;;
        *bz2)
            tar xj -C "$dir" -f "$file"
            ;;
        *gz)
            tar xz -C "$dir" -f "$file"
            ;;
        *)
            __die "don't know how to unzip $file"
            ;;
    esac
}


__finish() {
  local exit_code=$?
  if [[ $exit_code -ge 124 ]]; then
    echo "this script($(basename $0)) timeout or interrupted by user($exit_code)."
    exit $exit_code
  fi
  date '+%Y/%m/%d %H:%M:%S'
  echo "total time: $(( $(date +%s) - $start_time ))s"
  echo "exit code: $exit_code"
  exit $exit_code
}


__download()
{
    urlroot=$1
    tarfile=$2
    output_dir=$tarfile_dir
    if [ $# -eq 3 ]; then
      output_dir=$3
    fi

    if [ ! -e "$output_dir/$tarfile" ]; then
        if command -V wget &>/dev/null; then
          wget --verbose "${urlroot}/$tarfile" --directory-prefix="$output_dir" || rm -f "$output_dir/$tarfile"
        elif command -V curl &>/dev/null; then
          curl -o "$output_dir/$tarfile" "${urlroot}/$tarfile" || rm -f "$output_dir/$tarfile"
        fi
    else
        echo "already downloaded: $tarfile  '$output_dir/$tarfile'"
    fi
}


# Set script to abort on any command that results an error status
trap '__finish' EXIT
trap 'echo "interrupted by user(SIGHUP,logout)"; exit 129' SIGHUP
trap 'echo "interrupted by user(SIGINT,Ctrl+C)"; exit 130' SIGINT
trap 'echo "interrupted by user(SIGQUIT,Ctrl+\)"; exit 131' SIGQUIT
trap 'echo "interrupted by user(SIGTERM,kill)"; exit 143' SIGTERM


#======================================================================
# Directory creation
#======================================================================


__banner Creating directories

# ensure workspace directories don't already exist
for d in  "$build_dir" "$source_dir" ; do
    if [ -d  "$d" ]; then
        __die "directory already exists - please remove and try again: $d"
    fi
done

for d in "$install_dir" "$build_dir" "$source_dir" "$tarfile_dir" "$gcc_tarfile_dir" "$gcc_toolchain_dir";
do
    test  -d "$d" || mkdir --verbose -p $d
done


#======================================================================
# Download source code
#======================================================================


# This step requires internet access.  If you dont have internet access, then
# obtain the tarfiles via an alternative manner, and place in the
# "$tarfile_dir"

__banner Downloading source code

binutils_tarfile=binutils-${binutils_version}.tar.xz

__download https://ftp.gnu.org/gnu/binutils $binutils_tarfile

gcc_tarfile=gcc-13.3.0-linux-x86_64-glibc-2.19+.tar.xz
__download https://github.com/shediao/gcc.build/releases/download/v0.0.1 $gcc_tarfile $gcc_tarfile_dir

for f in $binutils_tarfile
do
    if [ ! -f "$tarfile_dir/$f" ]; then
        __die tarfile not found: $tarfile_dir/$f
    fi
done


__banner Unpacking source code

__untar  "$source_dir"  "$tarfile_dir/$binutils_tarfile"

if [[ ! -x "$gcc_toolchain_dir/bin/gcc" ]]; then
  __untar  "$gcc_toolchain_dir"  "$tarfile_dir/$gcc_tarfile"
fi

#======================================================================
# Clean environment
#======================================================================


# Before beginning the configuration and build, clean the current shell of all
# environment variables, and set only the minimum that should be required. This
# prevents all sorts of unintended interactions between environment variables
# and the build process.

__banner Cleaning environment

# store USER, HOME and then completely clear environment
U=$USER
H=$HOME

regexp="^[0-9A-Za-z_]*$"
for i in $(env | awk -F"=" '{print $1}') ;
do
    if [[  $i =~ $regexp ]]; then
        unset $i || true   # ignore unset fails
    fi
done
unset regexp

# restore
export USER=$U
export HOME=$H
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin

echo sanitised shell environment follows:
env


#======================================================================
# Configure
#======================================================================


__banner Configuring source code

cd "${build_dir}"
export PATH="$gcc_toolchain_dir/bin:$PATH"
CC=$gcc_toolchain_dir/bin/gcc
CXX=$gcc_toolchain_dir/bin/g++
OPT_FLAGS="-O2 -Wall $arch_flags -static-libgcc -static-libstdc++"
CC="$CC" CXX="$CXX" CFLAGS="$OPT_FLAGS" \
    CXXFLAGS="`echo " $OPT_FLAGS " | sed 's/ -Wall / /g'`" \
    LDFLAGS="-static-libgcc -static-libstdc++" \
    $source_dir/binutils-${binutils_version}/configure --prefix=${install_dir} \
    --disable-nls \
    --disable-gprofng \
    --build=${build_target} \
    --target=${build_target} \
    --host=${build_target} \
    --with-pkgversion="$packageversion"


cd "$build_dir"

nice make $make_flags

# If desired, run the GCC test phase by uncommenting following line

#make check


#======================================================================
# Install
#======================================================================


__banner Installing

if [[ -d "$install_dir" ]]; then
  rm -rf "$install_dir"
  mkdir -p "$install_dir"
fi
nice make install-strip

tar_file_name="binutils-${binutils_version}-$(uname -s | tr A-Z a-z)-$(uname -m)"

glibc_version="$(/usr/bin/env LC_ALL=C ldd --version  | sed -n -e '1s/^ldd .* //p')"
glibc_version=${glibc_version## }
glibc_version=${glibc_version%% }
if [[ $glibc_version =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  tar_file_name="${tar_file_name}-glibc-${glibc_version}+"
fi

cd "$install_dir" && tar -cJvf ../${tar_file_name}.tar.xz ./

rm -rf "$build_dir"
rm -rf "$source_dir"

#======================================================================
# Completion
#======================================================================

__banner Complete

