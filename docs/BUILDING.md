# Building the kernel

You do not need to build anything to use this project — install the release
zip. This is for changing the kernel.

## The source tree

```
https://github.com/raphael-resources/android_kernel_xiaomi_sm8150   branch 16.2
```

**Not LineageOS.** A pristine 4.14 tree compiles, boots, and then bootloops at
`bpfloader` — see [ANDROID-NOTES.md](ANDROID-NOTES.md). Verify any tree before
spending an hour on it:

```sh
grep -c 'BPF_PROG_TYPE_' include/uapi/linux/bpf.h   # must be >= 36
test -f kernel/bpf/btf.c                            # must exist
```

`run-builder.sh` refuses to start if either check fails.

Note the commit the shipped kernel was built from is orphaned — the branch was
force-pushed after the ROM was released. Identify the tree by fingerprint
(`Makefile` version quadruple, `CONFIG_LOCALVERSION="-perf"`), not by sha.

## Toolchain

AOSP clang. `clang-r522817` (18.0.1) is known good:

```sh
git clone --depth 1 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
    -b main clang && ls clang/clang-r522817
```

The ROM itself was built with clang 21 (`r563880c`), which is not published on
that branch. Clang 18 builds this tree cleanly.

## Host requirements

A **case-sensitive** filesystem. 4.14's netfilter alone ships both
`xt_CONNMARK.h` and `xt_connmark.h`; on a case-insensitive volume one silently
overwrites the other on checkout. On macOS, create an APFS (case-sensitive)
sparse image — `build-env.sh` does this.

Docker Desktop needs 32 GB+ allocated to its VM if you enable LTO.

## Build

```sh
source kernel/build/build-env.sh     # attaches the sparse image, sizes the VM
./kernel/build/run-builder.sh
```

The build seeds `.config` from the device's own `/proc/config.gz`
(`kernel/base/`) rather than a defconfig, then merges
`kernel/container.config`. It refuses to proceed if any requested flag was
dropped, and reports every symbol that changed which you did *not* ask for —
that check exists because `olddefconfig` once silently enabled
`CONFIG_SPECULATIVE_PAGE_FAULT` on a daily driver.

Output is `Image.gz`. Package it:

```sh
tools/make-zip.sh path/to/Image.gz
```

## Getting your own base config

```sh
adb shell 'su -c "cat /proc/config.gz"' | gunzip > my-base.config
```

Use it in place of `kernel/base/infinityx-3.11.config` if you are on a
different ROM build.

## Why dtbs are not built

Every xiaomi overlay in this tree opens with a bare `&tlmm {`, and the bundled
dtc 1.4.4 has no grammar production letting a `devicetree` *begin* with a
reference — `dtc-parser.y` requires `'/' nodedef` first. The ROM's own build
supplies a newer external dtc via `DTC_EXT`.

It does not matter here: the boot image's DTB is the device's own, and the
`dtbo` partition is never touched. `Image.gz` has no `dtbs` dependency.
