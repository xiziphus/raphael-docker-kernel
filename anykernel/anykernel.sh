# AnyKernel3 config for the Antigravity Docker kernel (raphael).
#
# This is the recovery-flashable path. It matters because a KernelSU module
# cannot install itself on a device with no root -- and on 4.14, which is not
# GKI, KernelSU has to be compiled into the kernel, so there is no way to get
# root first. AnyKernel3 runs in recovery with its own bundled tools and does
# not need /data decrypted, which breaks that deadlock without a PC.
#
# Like the module, it patches the boot image already on the device: your
# ramdisk, DTB and security patch level are kept. It never ships someone
# else's.

properties() { '
kernel.string=Antigravity Docker Kernel for Redmi K20 Pro (raphael)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=raphael
device.name2=raphaelin
device.name3=
device.name4=
device.name5=
supported.versions=16
supported.patchlevels=
'; } # end properties

# Shell variables
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

# import functions/variables and setup patching - see for reference
. tools/ak3-core.sh;

# boot shell variables
BLOCK=$block;
IS_SLOT_DEVICE=$is_slot_device;
RAMDISK_COMPRESSION=$ramdisk_compression;
PATCH_VBMETA_FLAG=$patch_vbmeta_flag;

# Replace only the kernel. split_boot unpacks what is already installed,
# flash_boot repacks it with the new Image.gz and writes it back, so every
# other section of the boot image survives untouched.
split_boot;
flash_boot;
