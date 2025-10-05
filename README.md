Distro-hop is a script that upgrade AlmaLinux/RockyLinux from 8.4 to 9.x/10.x by dnf distro-sync, third-party packages will remain, e.g docker-ce. 

Only ISO file as upgrade media is supported currently.

Note: When upgrade to el10, the option "--use-distro-repos" enable CRB repo to upgrade packages like libvirt-daemon-driver-* and virt-manager.

Please put ISO file under /mnt/iso in the format '${ISO_NAME}-${DST_OS_VERSION}-${ARCH}-dvd.iso'
For example:
AlmaLinux-10.0-x86_64-dvd.iso

The work directory is /root/distro-hop_${DST_OS_CLASS), e.g. /root/distro-hop_el10
