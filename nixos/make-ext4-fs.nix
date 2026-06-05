# Custom ext4 filesystem image builder.
# Same as NixOS upstream make-ext4-fs.nix, but runs mkfs.ext4 -d WITHOUT fakeroot
# to avoid SELinux xattr issues. fakeroot intercepts getxattr for security.selinux
# and returns ENODATA, causing mkfs.ext4 -d to fail.
{
  pkgs,
  lib,
  storePaths,
  compressImage ? false,
  zstd,
  populateImageCommands ? "",
  volumeLabel,
  uuid ? "44444444-4444-4444-8888-888888888888",
  e2fsprogs,
  libfaketime,
  perl,
  fakeroot,
}:

let
  sdClosureInfo = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "ext4-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs = [
    e2fsprogs.bin
    libfaketime
    perl
    fakeroot
  ]
  ++ lib.optional compressImage zstd;

  buildCommand = ''
    ${if compressImage then "img=temp.img" else "img=$out"}
    (
    mkdir -p ./files
    ${populateImageCommands}
    )

    echo "Preparing store paths for image..."

    # Create nix/store
    mkdir -p ./rootImage/nix/store

    # Copy store paths using cp -r (no -a, to avoid SELinux xattr propagation).
    if ! xargs -I % cp -r --reflink=auto % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths 2>/dev/null; then
      xargs -I % cp -r % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths
    fi

    (
      GLOBIGNORE=".:.."
      shopt -u dotglob
      for f in ./files/*; do
          cp -r --reflink=auto "$f" ./rootImage/ 2>/dev/null || cp -r "$f" ./rootImage/
      done
    )

    # Also include a manifest of the closures in a format suitable for nix-store --load-db
    cp ${sdClosureInfo}/registration ./rootImage/nix-path-registration

    echo "Root image prepared: $(find ./rootImage | wc -l) files, $(du -sh ./rootImage | cut -f1)"

    # Calculate size
    numInodes=$(find ./rootImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * $numInodes + 4096 * $numDataBlocks))

    mebibyte=$(( 1024 * 1024 ))
    if (( bytes % mebibyte )); then
      bytes=$(( ( bytes / mebibyte + 1) * mebibyte ))
    fi

    truncate -s $bytes $img

    # Use -E no_copy_xattrs to avoid SELinux xattr issues on Fedora.
    # The fakeroot wrapper ensures files are owned by root in the image.
    faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 -L ${volumeLabel} -U ${uuid} -E no_copy_xattrs -d ./rootImage $img

    export EXT2FS_NO_MTAB_OK=yes
    if ! fsck.ext4 -n -f $img; then
      echo "--- Fsck failed ---"
      cat errorlog
      return 1
    fi

    # shrink to fit
    resize2fs -M $img

    new_size=$(dumpe2fs -h $img | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print (count*size+16*2**20)/size}')

    resize2fs $img $new_size

    if [ ${toString compressImage} ]; then
      echo "Compressing image"
      zstd -T$NIX_BUILD_CORES -v --no-progress ./$img -o $out
    fi
  '';
}
