# Introduction

distro-hop is a script that upgrade AlmaLinux/RockyLinux from 8.4 to 9.x/10.x by dnf distro-sync, third-party packages will remain, e.g docker-ce. 

Currently only ISO file as upgrade media is supported.

Note: When upgrade to el10, the option "--use-distro-repos" enable CRB repo to upgrade packages like libvirt-daemon-driver-* and virt-manager.

# How to use

Please put ISO file under /mnt/iso in the format '${ISO_NAME}-${DST_OS_VERSION}-${ARCH}-dvd.iso'
For example: *AlmaLinux-10.0-x86_64-dvd.iso*

The work directory is /root/distro-hop_${DST_OS_CLASS)
For example: */root/distro-hop_el10*

./distro-hop.sh 10.0

# Upgrade 8.x to 10.0 using offline packages

If you have more than one 8.x host, then you can upgrade the first host and save offline packages for another 8.x host.

## Upgrade 8.x to 10.x using --enable-distro-repos

`# ./distro-hop.sh 10.0 --use-distro-repos`

## Download packages after reboot

` dnf reinstall -y --downloadonly --setopt=keepcache-1 $(rpm -qa|sort)` 

## Create repos of downloaded packages

`dnf install -y createrepo`
`cd /var/cache/dnf`
`find . -name '*.rpm' > /root/cached_rpms.lst`
`mkdir -p /mnt/repo`
`rsync --files-from=/root/cached_rpms.lst . /mnt/repo/`

## Create repo file of offline repos

`cd /mnt/repo`

<pre>
for dir in \*;
    new_dir=$(echo $dir|cut -d '-' -f 1)-10.0-local
    /bin/mv -f $dir $new_dir
    cd $new_dir
    mv packages/* ./
    rmdir packages
    cd ..
    createrepo $new_dir
done
</pre>

`cd /mnt/repo`<br/>

`for dir in *;do`<br/>
    `echo "[$dir]"`<br/>
    `echo "name=$dir"`<br/>
    `echo "baseurl=file:///mnt/repo/$dir"`<br/>
    `echo "gpgcheck=0"`<br/>
    `echo "enable=1"`<br/>
    `echo`<br/>
`done > /root/create_repo_file.sh`<br/>

`chmod 755 /root/create_repo_file.sh`<br/>
`/root/create_repo_file.sh > /etc/yum.repos.d/local.repo`<br/>

## Copy /mnt/repo and local.repo to another host(s)

`scp -rp /etc/yum.repos.d/local.repo otheHost:/etc/yum.repos.d/`<br/>
`scp -rp /mnt/repo otheHost:/mnt`

## Upgrade another host using --use-local-repo option

`./distro-hop 10.0 --use-local-repo`
