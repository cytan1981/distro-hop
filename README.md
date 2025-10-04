Distro-hop is a script that upgrade AlmaLinux/RockyLinux from 8.4 to 9.x/10.x by dnf distro-sync, third-party packages will remain, e.g docker-ce. 

Only ISO file as upgrade media is supported currently.

Please put ISO file under /mnt/iso in the format '${ISO_NAME}-${DST_OS_VERSION}-${ARCH}-dvd.iso'
For example:
AlmaLinux-10.0-x86_64-dvd.iso
