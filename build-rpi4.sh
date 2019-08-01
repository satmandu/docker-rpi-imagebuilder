#!/bin/bash -e

# This script is executed within the container as root. The resulting image &
# logs are written to /output after a succesful build.  These directories are 
# mounted as docker volumes to allow files to be exchanged between the host and 
# the container.

kernel_branch=rpi-4.19.y
kernelgitrepo="https://github.com/raspberrypi/linux.git"
#branch=bcm2711-initial-v5.2
#kernelgitrepo="https://github.com/lategoodbye/rpi-zero.git"
# This should be the image we want to modify.
base_url="http://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/"
base_image="eoan-preinstalled-server-arm64+raspi3.img.xz"
base_image_url="${base_url}/${base_image}"
# This is the base name of the image we are creating.
new_image="eoan-preinstalled-server-arm64+raspi4"
# Comment out the following if apt is throwing errors silently.
# Note that these only work for the chroot commands.
silence_apt_flags="-o Dpkg::Use-Pty=0 -qq < /dev/null > /dev/null "
silence_apt_update_flags="-o Dpkg::Use-Pty=0 < /dev/null > /dev/null "
image_compressors=("lz4" "xz")
#image_compressors=("lz4")


#DEBUG=1
GIT_DISCOVERY_ACROSS_FILESYSTEM=1

# Set Time Stamp
now=`date +"%m_%d_%Y_%H%M%Z"`

# Create debug output folder.
[[ $DEBUG ]] && ( mkdir -p /output/$now/ ; chown $USER:$GROUP /output/$now/ )
#[[ $DEBUG ]] && chown $USER:$GROUP /output/$now/

# Logging Setup
TMPLOG=/tmp/build.log
touch $TMPLOG
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>$TMPLOG 2>&1

# Use ccache.
PATH=/usr/lib/ccache:$PATH
CCACHE_DIR=/cache/ccache
mkdir -p $CCACHE_DIR
# Change these settings if you need them to be different.
ccache -M 0 > /dev/null
ccache -F 0 > /dev/null
# Show ccache stats.
echo "Build ccache stats:"
ccache -s

# Create work directory.
workdir=/build/source
mkdir -p $workdir
#cp -a /source-ro/ $workdir

# Source cache is on the cache volume.
src_cache=/cache/src_cache
mkdir -p $src_cache

# Apt cache is on the cache volume.
apt_cache=/cache/apt_cache
# This is needed or apt has issues.
mkdir -p $apt_cache/partial 

# Make sure inotify-tools is installed.
apt-get -o dir::cache::archives=$apt_cache install inotify-tools lsof xdelta -qq

# Utility Functions

function abspath {
    echo $(cd "$1" && pwd)
}

inotify_touch_events () {
    # Since inotifywait seems to need help in docker. :/
    while [ ! -f "/tmp/export_log.done" ]
    do
        touch /tmp/*
        sleep 1
    done
}

waitfor () {
    local waitforit
    # waitforit file is written in the function "endfunc"
    touch /tmp/wait.${FUNCNAME[1]}_for_${1}
    while read waitforit; do if [ "$waitforit" = ${1}.done ]; then break; \
    fi; done \
   < <(inotifywait  -e create,open,access --format '%f' --quiet /tmp --monitor)
    printf "%${COLUMNS}s\n" "++ ${FUNCNAME[1]} no longer waiting for ${1} to finish.++"
    rm -f /tmp/wait.${FUNCNAME[1]}_for_${1}
}

startfunc () {
    touch /tmp/${FUNCNAME[1]}.start
    echo "-- ${FUNCNAME[1]} start."
}

endfunc () {
    mv /tmp/${FUNCNAME[1]}.start /tmp/${FUNCNAME[1]}.done
    # inotifywait is having issues in docker.
    touch /tmp/*
    # debugging
   # [[ $DEBUG ]] && ( [[ -d "/output/$now/" ]] && ( env > /output/$now/${FUNCNAME[1]}.env ; chown $USER:$GROUP /output/$now/${FUNCNAME[1]}.env ))
   # [[ $DEBUG ]] && chown $USER:$GROUP /output/$now/${FUNCNAME[1]}.env
    echo "++ ${FUNCNAME[1]} done."
}


git_check () {
    local git_base="$1"
    local git_branch="$2"
    [ ! -z "$2" ] || git_branch="master"
    local git_output=`git ls-remote ${git_base} refs/heads/${git_branch}`
    local git_hash
    local discard 
    read git_hash discard< <(echo "$git_output")
    echo $git_hash
}

local_check () {
    local git_path="$1"
    local git_branch="$2"
    [ ! -z "$2" ] || git_branch="HEAD"
    local git_output=`git -C $git_path rev-parse ${git_branch} 2>/dev/null`
    echo $git_output
}


# Standalone get with git function
# get_software_src () {
# startfunc
# 
#     git_get "gitrepo" "local_path" "git_branch"
# 
# endfunc
# }

git_get () {
    local git_repo="$1"
    local local_path="$2"
    local git_branch="$3"
    [ ! -z "$3" ] || git_branch="master"
    mkdir -p $src_cache/$local_path
    mkdir -p $workdir/$local_path
    
    local remote_git=$(git_check "$git_repo" "$git_branch")
    local local_git=$(local_check "$src_cache/$local_path" "$git_branch")
    
    #[[ $git_branch ]] && git_extra_flags= || git_extra_flags="-b $branch"
    [ -z $git_branch ] && git_extra_flags= || git_extra_flags=" -b $git_branch "
    local git_flags=" --quiet --depth=1 "
    local clone_flags=" $git_repo $git_extra_flags "
    local pull_flags="origin/$git_branch"
    printf "%${COLUMNS}s\n"  "${FUNCNAME[1]} remote hash: $remote_git"
    #echo $remote_git > /tmp/remote.git
    printf "%${COLUMNS}s\n"  "${FUNCNAME[1]}  local hash: $local_git"
    #echo $local_git > /tmp/local.git
    if [ ! "$remote_git" = "$local_git" ]; then
        printf "%${COLUMNS}s\n"  "* ${FUNCNAME[1]} refreshing cache files from git. *"
        
        
        cd $src_cache
        [ ! -d "$src_cache/$local_path/.git" ] && rm -rf $src_cache/$local_path \
        && mkdir -p $src_cache/$local_path
        
        git clone $git_flags $clone_flags $local_path &>> /tmp/${FUNCNAME[1]}.git.log || true
        cd $src_cache/$local_path
        git fetch --all $git_flags &>> /tmp/${FUNCNAME[1]}.git.log || true
        git reset --hard $pull_flags $git_flags 2>> /tmp/${FUNCNAME[1]}.git.log || \
        ( rm -rf $src_cache/$local_path ; cd $src_cache ; git clone $git_flags $clone_flags $local_path ) 2>> /tmp/${FUNCNAME[1]}.git.log
        
        printf "%${COLUMNS}s\n"  "* ${FUNCNAME[1]} Last Commit: *"
        git log -1 --quiet 2> /dev/null
        #ls $cache_path/$local_path
    fi
    printf "%${COLUMNS}s\n"  "* ${FUNCNAME[1]} copying files from cache. *"
    echo ""
    rsync -a $src_cache/$local_path $workdir/
}


# Main functions

download_base_image () {
startfunc
    echo "* Downloading ${base_image} ."
    wget_fail=0
    wget -nv ${base_image_url} -O ${base_image} || wget_fail=1
endfunc
}

checkfor_base_image () {
startfunc
    echo "* Checking for downloaded ${base_image} ."
    cd $workdir
    if [ ! -f /${base_image} ]; then
        download_base_image
    else
        echo "* Downloaded ${base_image} exists."
    fi
    # Symlink existing image
    if [ ! -f $workdir/${base_image} ]; then 
        ln -s /$base_image $workdir/
    fi   
endfunc
}

extract_and_mount_image () {
    waitfor "checkfor_base_image"
startfunc    
    echo "* Extracting: ${base_image} to ${new_image}.img"
    xzcat $workdir/$base_image > $workdir/$new_image.img
    [[ $XDELTA ]] && cp $workdir/$new_image.img $workdir/old_image.img
    #echo "* Increasing image size by 200M"
    #dd if=/dev/zero bs=1M count=200 >> $workdir/$new_image.img
    echo "* Clearing existing loopback mounts."
    losetup -d /dev/loop0 &>/dev/null || true
    dmsetup remove_all
    losetup -a
    cd $workdir
    echo "* Mounting: ${new_image}.img"

    kpartx -avs ${new_image}.img
    #e2fsck -f /dev/loop0p2
    #resize2fs /dev/loop0p2
    mount /dev/mapper/loop0p2 /mnt
    mount /dev/mapper/loop0p1 /mnt/boot/firmware
    # Guestmount is at least an order of magnitude slower than using loopback device.
    #guestmount -a ${new_image}.img -m /dev/sda2 -m /dev/sda1:/boot/firmware --rw /mnt -o dev
endfunc
}

setup_arm64_chroot () {
    waitfor "extract_and_mount_image"
startfunc    
    echo "* Setup ARM64 chroot"
    cp /usr/bin/qemu-aarch64-static /mnt/usr/bin
    

    mount -t proc proc     /mnt/proc/
#    mount -t sysfs sys     /mnt/sys/
#    mount -o bind /dev     /mnt/dev/
    mount -o bind /dev/pts /mnt/dev/pts
    mount --bind $apt_cache /mnt/var/cache/apt
 #   chmod -R 777 /mnt/var/lib/apt/
 #   setfacl -R -m u:_apt:rwx /mnt/var/lib/apt/ 
    mkdir /mnt/ccache || ls -aFl /mnt
    mount --bind $CCACHE_DIR /mnt/ccache
    mount --bind /run /mnt/run
    mkdir -p /run/systemd/resolve
    cp /etc/resolv.conf /run/systemd/resolve/stub-resolv.conf
    rsync -avh --devices --specials /run/systemd/resolve /mnt/run/systemd > /dev/null
    
    mkdir -p /mnt/build
    mount -o bind /build /mnt/build
    echo "* ARM64 chroot setup is complete." 
    
    echo "* Starting apt update."
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    update 2>/dev/null | grep packages | cut -d '.' -f 1 
    echo "* Apt update done."
    echo "* Downloading software for apt upgrade."
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    upgrade -d -qq 2>/dev/null
    echo "* Apt upgrade download done."
    #echo "* Starting chroot apt update."
    #chroot /mnt /bin/bash -c "/usr/bin/apt update 2>/dev/null \
    #| grep packages | cut -d '.' -f 1"
    #echo "* Chroot apt update done."

    echo "* Downloading software for building portions of kernel natively on chroot."
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    install -d -qq --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils 2>/dev/null
    echo "* Downloading wifi & networking tools."
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=$apt_cache \
    -d install wireless-tools wireless-regdb crda \
    net-tools network-manager -qq 2>/dev/null
    echo "* Apt upgrading image in chroot."
    echo "* There may be some errors here due to" 
    echo "* installation happening in a chroot."
    chroot /mnt /bin/bash -c "/usr/bin/apt-get upgrade -y $silence_apt_flags" &>> /tmp/${FUNCNAME[0]}.install.log
    echo "* Image apt upgrade done."
    echo "* Installing native kernel build software to image."
    chroot /mnt /bin/bash -c "/usr/bin/apt-get install -y --no-install-recommends \
               build-essential \
               bc \
               bison \
               ccache \
               cdbs \
               cmake \
               cpio \
               devscripts \
               dkms \
               dpkg-dev \
               equivs \
               fakeroot \
               flex \
               gawk \
               gcc \
               cpp \
               g++  \
               git \
               kpartx \
               lz4 \
               libelf-dev \
               libncurses-dev \
               libssl-dev \
               qemu-user-static \
               patch \
               rsync \
               sudo \
               wget \
               xz-utils $silence_apt_flags"
    echo "* Native kernel build software installed."
    echo "* Installing wifi & networking tools to image."
    chroot /mnt /bin/bash -c "/usr/bin/apt-get \
    install wireless-tools wireless-regdb crda \
    net-tools network-manager -y $silence_apt_flags" &>> /tmp/${FUNCNAME[0]}.install.log
    echo "* Wifi & networking tools installed."
endfunc
}


rpi_firmware () {
    git_get "https://github.com/Hexxeh/rpi-firmware" "rpi-firmware"
    waitfor "extract_and_mount_image"
startfunc    
    cd $workdir
    echo "* Installing current RPI firmware."
    cp rpi-firmware/bootcode.bin /mnt/boot/firmware/
    cp rpi-firmware/*.elf /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dat /mnt/boot/firmware/
    cp rpi-firmware/*.dtb /mnt/boot/firmware/
    cp rpi-firmware/overlays/*.dtbo /mnt/boot/firmware/overlays/
endfunc
}

build_kernel () {
    git_get "$kernelgitrepo" "rpi-linux" "$kernel_branch"
startfunc    
    echo "* Building $kernel_branch kernel."
    kernelrev=`git -C $workdir/rpi-linux rev-parse --short HEAD`
    cd $workdir/rpi-linux
    mkdir $workdir/kernel-build
    
    [ ! -f arch/arm64/configs/bcm2711_defconfig ] && \
    wget https://raw.githubusercontent.com/raspberrypi/linux/rpi-5.2.y/arch/arm64/configs/bcm2711_defconfig \
    -O arch/arm64/configs/bcm2711_defconfig
    
    make \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION=-`git -C $workdir/rpi-linux rev-parse --short HEAD` \
    O=$workdir/kernel-build \
    bcm2711_defconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    
    cd $workdir/kernel-build
    # Use kernel config modification script from sakaki- found at 
    # https://github.com/sakaki-/bcm2711-kernel-bis
    # This is needed to enable squashfs - which snapd requires, since otherwise
    # login at boot fails on the ubuntu server image.
    # This also enables the BPF syscall for systemd-journald firewalling
    /source-ro/conform_config.sh
    yes "" | make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION=-`git -C $workdir/rpi-linux rev-parse --short HEAD` \
    O=.$workdir/kernel-build/ \
    olddefconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    
    cd ..

    cd $workdir/rpi-linux
    make \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION=-`git -C $workdir/rpi-linux rev-parse --short HEAD` \
    -j $(($(nproc) + 1)) O=$workdir/kernel-build &>> /tmp/${FUNCNAME[0]}.compile.log
    
    # Not sure why setting this isn't working globally. :/
    export KERNEL_VERSION=`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`
    ###
    echo "* Kernel version is ${KERNEL_VERSION} *"
    echo "* Regenerating broken cross-compile module installation infrastructure."
    # Cross-compilation of kernel wreaks havoc with building out of kernel modules
    # later, due to module install files being installed into the target system in
    # the cross-compile build host architecture, so let's fix this with natively 
    # compiled module tools which have been installed into the image.
    files=("scripts/recordmcount" "scripts/mod/modpost" \
        "scripts/basic/fixdep")
        
    for i in "${files[@]}"
    do
     rm $workdir/kernel-build/$i || true
    done
    
    # This is all we can do before the image is mounted.
    waitfor "extract_and_mount_image"   
    waitfor "setup_arm64_chroot"
    
    chroot /mnt /bin/bash -c "cd $workdir/rpi-linux ; make \
    CCACHE_DIR=/ccache PATH=/usr/lib/ccache:$PATH \
    LOCALVERSION=-${kernelrev} \
    -j $(($(nproc) + 1)) O=$workdir/kernel-build \
    modules_prepare" &>> /tmp/${FUNCNAME[0]}.compile.log

    mkdir -p $workdir/kernel-build/tmp/scripts/mod
    mkdir -p $workdir/kernel-build/tmp/scripts/basic
    for i in "${files[@]}"
    do
     cp $workdir/kernel-build/$i $workdir/kernel-build/tmp/$i
     rm $workdir/kernel-build/$i
     sed -i "/.tmp_quiet_recordmcount$/i TABTMP\$(Q)cp $workdir/kernel-build/tmp/${i} ${i}" \
     $workdir/rpi-linux/Makefile
    done
    TAB=$'\t'
    sed -i "s/TABTMP/${TAB}/g" $workdir/rpi-linux/Makefile
    
    # Now we have qemu-static & arm64 binaries installed, so we copy libraries over
    # from image to build container in case they are needed during this install.
    cp /mnt/usr/lib/aarch64-linux-gnu/libc.so.6 /lib64/
    cp /mnt/lib/ld-linux-aarch64.so.1 /lib/
    
    # Maybe this can all be worked around by statically compiling these files
    # so that qemu-static can just deal with them without library issues during the 
    # packaging process. This two lines may not be needed.
    aarch64-linux-gnu-gcc -static $workdir/rpi-linux/scripts/basic/fixdep.c -o \
    $workdir/kernel-build/tmp/scripts/basic/fixdep &>> /tmp/${FUNCNAME[0]}.compile.log
    
    aarch64-linux-gnu-gcc -static $workdir/rpi-linux/scripts/recordmcount.c -o \
    $workdir/kernel-build/tmp/scripts/recordmount &>> /tmp/${FUNCNAME[0]}.compile.log

    
    debcmd="make \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION=-`git -C $workdir/rpi-linux rev-parse --short HEAD` \
    -j $(($(nproc) + 1)) O=$workdir/kernel-build \
    bindeb-pkg"
    
    echo $debcmd
    $debcmd &>> /tmp/${FUNCNAME[0]}.compile.log
    echo "* Copying out $KERNEL_VERSION kernel debs."
    rm $workdir/linux-libc-dev*.deb
    cp $workdir/*.deb /output/ 
    chown $USER:$GROUP /output/*.deb


    # Now that we have the kernel packages, let us go ahead and make a local 
    # install anyways so that we can manually copy the required files over for
    # first boot.
    mkdir $workdir/kernel-install
    sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    LOCALVERSION=-`git -C $workdir/rpi-linux rev-parse --short HEAD` \
    DEPMOD=echo INSTALL_MOD_PATH=$workdir/kernel-install \
    -j $(($(nproc) + 1))  O=$workdir/kernel-build \
    modules_install &>> /tmp/${FUNCNAME[0]}.compile.log
    depmod --basedir $workdir/kernel-install `cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`
    
endfunc
}

install_kernel () {
    waitfor "build_kernel"
    waitfor "extract_and_mount_image"
startfunc    
    echo "* Copying compiled `cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'` kernel to image."
    df -h
    cd $workdir
    #
    # Try installing the generated debs in chroot before we do anything else.
    cp $workdir/*.deb /mnt/tmp/
    chroot /mnt /bin/bash -c "dpkg -i /tmp/*.deb" &>> /tmp/${FUNCNAME[0]}.install.log
    #chroot /mnt /bin/bash -c "depmod -a `cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`" &>> /tmp/${FUNCNAME[0]}.install.log
    
    
    
    # Ubuntu defaults to using uBoot, which now works for RPI4, as of
    # July 31, 2019, so we copy that into /boot/firmware/kernel8.img later.
    # 
    # We replacee uboot with kernel, but we're installing the kernel here as
    # well. If a working uboot is not available copy this over to kernel8.img
    cp $workdir/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img.nouboot
    #
    # uboot uses uboot & the standard raspberry pi boot script to boot a compressed 
    # kernel on arm64, since linux on arm64 does not support self-decompression of 
    # the kernel, so we copy this for use with uboot.
    cp $workdir/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/vmlinuz-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`
    
    cp $workdir/kernel-build/arch/arm64/boot/Image.gz \
    /mnt/boot/firmware/vmlinuz
    
    cp $workdir/kernel-build/.config /mnt/boot/config-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`
endfunc
}

install_kernel_modules () {
    waitfor "install_kernel"
startfunc    
    echo "* Copying compiled `cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'` modules to image."
    # Ubuntu has /lib as a symlink to /usr/lib so we don't want to overwrite that!
    cp -avr $workdir/kernel-install/lib/* \
    /mnt/usr/lib/ &>> /tmp/${FUNCNAME[0]}.install.log
    
    rm  -rf /mnt/usr/lib/modules/`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`/build 
endfunc
}

install_kernel_dtbs () {
    waitfor "install_kernel"
startfunc    
    echo "* Copying compiled `cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'` dtbs & dtbos to image."
    cp $workdir/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware/ 
    cp $workdir/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo \
    /mnt/boot/firmware/overlays/
    cp $workdir/kernel-build/arch/arm64/boot/dts/overlays/*.dtbo \
    
    #Fix DTB install which for some reason doesn't happen properly in 
    # the generated deb.
    mkdir -p /mnt/lib/firmware/`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`/device-tree/
    rsync -arm --include="*/" --include="*.dtbo" --include="*.dtb" --exclude="*" \
    $workdir/kernel-build/arch/arm64/boot/dts/ \
    /mnt/lib/firmware/`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`/device-tree/
    
    cp $workdir/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb \
    /mnt/etc/flash-kernel/dtbs/    
endfunc
}

armstub8-gic () {
    git_get "https://github.com/raspberrypi/tools.git" "rpi-tools"
startfunc    
    cd $workdir/rpi-tools/armstubs
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make armstub8-gic.bin &>> /tmp/${FUNCNAME[0]}.compile.log
    waitfor "extract_and_mount_image"
    cp $workdir/rpi-tools/armstubs/armstub8-gic.bin /mnt/boot/firmware/armstub8-gic.bin
endfunc
}

non-free_firmware () {
    git_get "https://github.com/RPi-Distro/firmware-nonfree" "firmware-nonfree"
    waitfor "extract_and_mount_image"
startfunc    
    cp -af $workdir/firmware-nonfree/* /mnt/usr/lib/firmware
endfunc
}


configure_rpi_config_txt () {
    waitfor "extract_and_mount_image"
startfunc    
    echo "* Making /boot/firmware/config.txt modifications."
    tee -a /mnt/boot/firmware/config.txt <<EOF
#
# This image was built on $now using software at
# https://github.com/satmandu/docker-rpi4-imagebuilder/
# 
EOF
    if ! grep -qs 'armstub=armstub8-gic.bin' /mnt/boot/firmware/config.txt
        then echo "armstub=armstub8-gic.bin" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'enable_gic=1' /mnt/boot/firmware/config.txt
        then echo "enable_gic=1" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'arm_64bit=1' /mnt/boot/firmware/config.txt
        then echo "arm_64bit=1" >> /mnt/boot/firmware/config.txt
    fi
    #if ! grep -qs 'kernel8.bin' /mnt/boot/firmware/config.txt
    #    then sed -i -r 's/kernel8.bin/kernel8.img/' /mnt/boot/firmware/config.txt
    #fi
    
    if ! grep -qs 'initramfs' /mnt/boot/firmware/config.txt
        then echo "initramfs initrd.img followkernel" >> /mnt/boot/firmware/config.txt
    fi
    
    if ! grep -qs 'enable_uart=1' /mnt/boot/firmware/config.txt
        then echo "enable_uart=1" >> /mnt/boot/firmware/config.txt
    fi
    
    # 3Gb limitation because USB & devices do not work currently without this.
     [ `grep -cs "total_mem=" /mnt/boot/firmware/config.txt` -gt 0 ] && \
     sudo sed 's/total_mem=*$/total_mem=3072/' /mnt/boot/firmware/config.txt || \
     echo "total_mem=3072" | sudo tee -a /mnt/boot/firmware/config.txt
     
endfunc
}

rpi_userland () {
    git_get "https://github.com/raspberrypi/userland" "rpi-userland"
    waitfor "extract_and_mount_image"
startfunc
    echo "* Installing Raspberry Pi userland source."
    cd $workdir
    mkdir -p /mnt/opt/vc
    cd $workdir/rpi-userland/
    CROSS_COMPILE=aarch64-linux-gnu- ./buildme --aarch64 /mnt &>> /tmp/${FUNCNAME[0]}.compile.log
    echo '/opt/vc/lib' > /mnt/etc/ld.so.conf.d/vc.conf 
    mkdir -p /mnt/etc/environment.d
    tee /mnt/etc/environment.d/10-vcgencmd.conf <<EOF
# /etc/environment.d/10-vcgencmd.conf
# Do not edit this file
    
PATH="/opt/vc/bin:/opt/vc/sbin"
ROOTPATH="/opt/vc/bin:/opt/vc/sbin"
LDPATH="/opt/vc/lib"
EOF
    chmod +x /mnt/etc/environment.d/10-vcgencmd.conf
    tee /mnt/etc/profile.d/98-rpi.sh <<EOF
# /etc/profile.d/98-rpi.sh
# Adds Raspberry Pi Foundation userland binaries to path
export PATH="\$PATH:/opt/vc/bin:/opt/vc/sbin"
EOF
       chmod +x /mnt/etc/profile.d/98-rpi.sh
       
    tee /mnt/etc/ld.so.conf.d/00-vmcs.conf <<EOF
/opt/vc/lib
EOF


endfunc
}

modify_wifi_firmware () {
    waitfor "extract_and_mount_image"
    waitfor "install_non-free_firmware"
startfunc    
    echo "* Modifying wireless firmware."
    # as per https://andrei.gherzan.ro/linux/raspbian-rpi4-64/
    if ! grep -qs 'boardflags3=0x44200100' \
    /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
        then sed -i -r 's/0x48200100/0x44200100/' \
        /mnt/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt
    fi
endfunc
}

andrei_gherzan_uboot_fork () {
startfunc
    git_get "https://github.com/agherzan/u-boot.git" "u-boot" "ag/rpi4"   
    cd $workdir/u-boot
    echo "CONFIG_GZIP=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_BZIP2=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_SYS_LONGHELP=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    echo "CONFIG_REGEX=y" >> $workdir/u-boot/configs/rpi_4_defconfig
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make rpi_4_defconfig &>> /tmp/${FUNCNAME[0]}.compile.log
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j $(($(nproc) + 1)) &>> /tmp/${FUNCNAME[0]}.compile.log
    waitfor "extract_and_mount_image"
    echo "* Installing Andrei Gherzan's RPI uboot fork to image."
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/uboot.bin
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/kernel8.bin
    cp $workdir/u-boot/u-boot.bin /mnt/boot/firmware/kernel8.img
    mkdir -p /mnt/usr/lib/u-boot/rpi_4/
    cp $workdir/u-boot/u-boot.bin /mnt/usr/lib/u-boot/rpi_4/
    chroot /mnt /bin/bash -c "mkimage -A arm64 -O linux -T script \
    -d /etc/flash-kernel/bootscript/bootscr.rpi \
    /boot/firmware/boot.scr" &>> /tmp/${FUNCNAME[0]}.compile.log

endfunc
}




install_first_start_cleanup_script () {
    waitfor "extract_and_mount_image"
    waitfor "build_kernel"
startfunc    
    echo "* Creating first start cleanup script."
    tee /mnt/etc/rc.local <<EOF
#!/bin/sh -e
# 1st Boot Cleanup Script
#
# Print the IP address
_IP=\$(hostname -I) || true
if [ "\$_IP" ]; then
 printf "My IP address is %s\n" "\$_IP"
fi
#
mkdir -p /lib/firmware/`uname -r`/device-tree/
/usr/bin/dpkg -i /var/cache/apt/archives/*.deb
/usr/bin/apt remove linux-image-raspi2 linux-image*-raspi2 -y --purge
/usr/bin/apt update && /usr/bin/apt upgrade -y
/usr/sbin/update-initramfs -c -k all
rm /etc/rc.local
exit 0
EOF
    chmod +x /mnt/etc/rc.local
endfunc
} 

make_kernel_install_scripts () {
    waitfor "extract_and_mount_image"
startfunc    
## This script allows flash-kernel to create the uncompressed kernel file
#    # on the boot partition.
#    echo "* Making kernel install scripts. &"
#    mkdir -p /mnt/etc/kernel/postinst.d
#    echo "* Creating /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel ."
#    tee /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel <<EOF
##!/bin/sh -eu
## Note that this conflicts with using uboot in /boot/firmware/kernel8.img
##
## If uboot is working for your hardware, and you have a functional 
## flash-kernel uboot boot script, you can delete this, and also likely 
## uncomment out the lines in the Raspberry Pi 4B entry of 
## /etc/flash-kernel/db to use u-boot.
##
#COMMAND="\$1"
#KERNEL_VERSION="\$2"
##BOOT_DIR_ABS="\$3"
#
#gunzip -c -f \$KERNEL_VERSION > /boot/firmware/kernel8.img
#exit 0
#EOF
#    
#    chmod +x /mnt/etc/kernel/postinst.d/zzzz_rpi4_kernel
    
    # Updated entry for the RPI 4B
    # be copied to the boot partition.
    mkdir -p /mnt/etc/flash-kernel/
    echo "* Creating /mnt/etc/flash-kernel/db ."
    tee -a /mnt/etc/flash-kernel/db <<EOF
#
# Raspberry Pi 4 Model B Rev 1.1
Machine: Raspberry Pi 4 Model B
Machine: Raspberry Pi 4 Model B Rev 1.1
DTB-Id: /etc/flash-kernel/dtbs/bcm2711-rpi-4-b.dtb
Boot-DTB-Path: /boot/firmware/bcm2711-rpi-4-b.dtb
Boot-Kernel-Path: /boot/firmware/vmlinuz
Boot-Initrd-Path: /boot/firmware/initrd.img
Boot-Script-Path: /boot/firmware/boot.scr
U-Boot-Script-Name: bootscr.rpi
Required-Packages: u-boot-tools
# XXX we should copy the entire overlay dtbs dir too
# Note as of July 31, 2019 the Ubuntu u-boot-rpi does 
# not have the required u-boot for the RPI4 yet.


EOF
endfunc
}

cleanup_image_remove_chroot () {
    waitfor "build_kernel"
    waitfor "install_kernel"
    waitfor "install_kernel_modules"
    waitfor "install_kernel_dtbs"
startfunc    
    echo "* Finishing image setup."
    
    echo "* Cleaning up ARM64 chroot"
    chroot /mnt /bin/bash -c "/usr/bin/apt-get \
    autoclean -y $silence_apt_flags"
    
    # binfmt-support wreaks havoc with container, so let it get 
    # installed at first boot.
    umount /mnt/var/cache/apt
    echo "Installing binfmt-support files for install at first boot."
    apt-get -o Dir=/mnt -o APT::Architecture=arm64 \
    -o dir::cache::archives=/mnt/var/cache/apt/archives/ \
    -d install binfmt-support -qq 2>/dev/null


    # I'm not sure where this is needed, but kernel install
    # craps out without this: /lib/firmware/`uname -r`/device-tree/
    # So we create it:
    mkdir -p /mnt/lib/firmware/`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`/device-tree/
    
    # Copy in kernel debs generated earlier to be installed at
    # first boot.
    echo "* Copying compiled kernel debs to image for proper install"
    echo "* at first boot and also so we have a copy locally."
    cp $workdir/*.deb /mnt/var/cache/apt/archives/
    sync
    if [ ! -f /tmp/ok_to_unmount_image_after_build.done ]; then
        echo "** Container paused before image unmount. **"
        echo 'Type in "touch /tmp/ok_to_unmount_image_after_build.done"'
        echo "in a shell into this container to continue."
    fi 
     
    waitfor "ok_to_unmount_image_after_build"
    umount /mnt/build
    umount /mnt/run
    umount /mnt/ccache
    rmdir /mnt/ccache
    umount /mnt/proc
    umount /mnt/dev/pts
    #umount /mnt/sys
    # This is no longer needed.
    rm /mnt/usr/bin/qemu-aarch64-static
endfunc
}

unmount_image () {
startfunc
    echo "* Unmounting modified ${new_image}.img"
    sync
    umount /mnt/boot/firmware || (sleep 60 ; umount /mnt/boot/firmware)
    #umount /mnt || (mount | grep /mnt)
    umount /mnt || (lsof +f -- /mnt ; sleep 60 ; umount /mnt)
    #guestunmount /mnt

    
    kpartx -dv $workdir/${new_image}.img
    #losetup -d /dev/loop0
    dmsetup remove_all
    
    if [ ! -f /tmp/ok_to_exit_container_after_build.done ]; then
        echo "** Image unmounted & container paused. **"
        echo 'Type in "touch /tmp/ok_to_exit_container_after_build.done"'
        echo "in a shell into this container to continue."
    fi 
    waitfor "ok_to_exit_container_after_build"
endfunc
}

export_compressed_image () {
startfunc

    
    # Note that lz4 is much much faster than using xz.
    chown -R $USER:$GROUP /build
    cd $workdir
    for i in "${image_compressors[@]}"
    do
     echo "* Compressing ${new_image} with $i and exporting"
     echo "  out of container to:"
     echo "${new_image}-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.img.$i"
     compress_flags=""
     [ "$i" == "lz4" ] && compress_flags="-m"
     compresscmd="$i -v -k $compress_flags ${new_image}.img"
     cpcmd="cp $workdir/${new_image}.img.$i \
     /output/${new_image}-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.img.$i"
     echo $compresscmd
     $compresscmd
     echo $cpcmd
     $cpcmd
     chown $USER:$GROUP /output/${new_image}-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.img.$i
     echo "/output/${new_image}-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.img.$i created." 
    done
endfunc
}    

export_xdelta_image () {
startfunc
        echo "* Making xdelta binary diffs between today's eoan base image"
        echo "* and the new images."
        xdelta delta -p -V $workdir/old_image.img $workdir/${new_image}.img \
        $workdir/patchout.xdelta
        for i in "${image_compressors[@]}"
        do
            compress_flags=""
            [ "$i" == "lz4" ] && compress_flags="-m"
            xdelta_patchout_compresscmd="$i -v -k $compress_flags $workdir/patchout.xdelta"
            $xdelta_patchout_compresscmd
            xdelta_patchout_cpcmd="cp $workdir/patchout.xdelta.$i \
     /output/eoan-daily-preinstalled-server_`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`${now}_xdelta.$i"
            $xdelta_patchout_cpcmd
            chown $USER:$GROUP /output/eoan-daily-preinstalled-server_`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`${now}_xdelta.$i
        done
endfunc
}

export_log () {
    waitfor "export_compressed_image"
startfunc
    echo "* Build log at: build-log-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.log"
    cat $TMPLOG > /output/build-log-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.log
    chown $USER:$GROUP /output/build-log-`cat $workdir/kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`_${now}.log
endfunc
}

# Delete this by connecting to the container using a shell if you want to 
# debug the container before the image is unmounted.
# The shell command would be something like this:
# docker exec -it `cat ~/docker-rpi4-imagebuilder/build.cid` /bin/bash
# Note that this flag is looked for in the cleanup_image_remove_chroot function
touch /tmp/ok_to_unmount_image_after_build.done


# Delete this by connecting to the container using a shell if you want to 
# debug the container before the container is exited.
# The shell command would be something like this:
# docker exec -it `cat ~/docker-rpi4-imagebuilder/build.cid` /bin/bash
# Note that this flag is looked for in the cleanup_image_remove_chroot function
touch /tmp/ok_to_exit_container_after_build.done

# inotify in docker seems to not recognize that files are being 
# created unless they are touched. Not sure where this bug is.
# So we will work around it.
inotify_touch_events &

checkfor_base_image
rpi_firmware &
armstub8-gic &
non-free_firmware & 
rpi_userland &
andrei_gherzan_uboot_fork &
# KERNEL_VERSION is set here:
build_kernel &
extract_and_mount_image
setup_arm64_chroot
configure_rpi_config_txt &
modify_wifi_firmware &
install_first_start_cleanup_script &
make_kernel_install_scripts &
install_kernel
install_kernel_modules &
install_kernel_dtbs &
cleanup_image_remove_chroot
unmount_image
export_compressed_image &
[[ $XDELTA ]] && export_xdelta_image
[[ $XDELTA ]] && waitfor "export_xdelta_image"
export_log
# This stops the tail process.
rm $TMPLOG
echo "**** Done."
