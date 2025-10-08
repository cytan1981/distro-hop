#!/usr/bin/env -S bash

if [ $# -lt 1 ];then
    echo "Usage: `basename $0` { upgrade_version } { --use-distro-repos } { --use-local-repo }"
    echo "Description:"
    echo -ne "\t--use-distro-repos : install {DISTO}-repos package from DVD before upgarading\n"
    echo -ne "\t--use-local-repo : requires a prepared /etc/yum.repos.d/local.repo\n"
    echo -ne "\t--use-local-repo : will invalid --use-distro-repos\n"
    exit 1
fi

# https://github.com/cytan1981/distro-hop
# Distro-hop is a script that upgrade AlmaLinux/RockyLinux from 8.4 to 9.x/10.x by dnf distro-sync, third-party packages will remain, e.g docker-ce.
# Only ISO file as upgrade media is supported currently.
# Please put ISO file under /mnt/iso in the format ${ISO_NAME}-${DST_OS_VERSION}-${ARCH}-dvd.iso
# For example: AlmaLinux-10.0-x86_64-dvd.iso

DST_OS_VERSION=$1
USE_LOCAL_REPO=0
USE_DISTRO_REPOS=0
shift

while [ $# -gt 0 ];do
    case $1 in
        --use-local-repo)
            USE_LOCAL_REPO=1
            shift
            continue
            ;;
        --use-distro-repos)
            USE_DISTRO_REPOS=1
            shift
            continue
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# USE_DISTRO_REPO conflicts with USE_LOCAL_REPO
[ $USE_LOCAL_REPO -eq 1 ] && USE_DISTRO_REPOS=0

# Prevent local.repo being saved to backup directory
[ $USE_LOCAL_REPO -eq 1 ] && OTHER_REPO_FILE="|local.repo" || OTHER_REPO_FILE=""

MIN_OS_VERSION=8.4
ARCH=$(uname -m)
ISO_DIR=/mnt/iso
EGREP="/usr/bin/grep -E"
OS_NAME=$(awk -F '"' '/^ID=/{ print $2 }' /etc/os-release)
OS_VERSION=$($EGREP -o '[0-9.]+' /etc/${OS_NAME}-release)
SRC_OS=${OS_NAME}-${OS_VERSION}
OS_VENDOR=$(rpm -q --qf '%{vendor}' $(rpm -qf /etc/os-release))
EXCLUDE_VENDORS=$OS_VENDOR
[ "$OS_NAME" = "almalinux" ] && EXCLUDE_VENDORS="$OS_VENDOR|CloudLinux"
ISO_NAME=$OS_NAME
[ "${OS_NAME}" != "rhel" ] && ISO_NAME=$(grep '^NAME=' /etc/os-release | awk -F '[" ]' '{ print $2 }')

DST_OS=${OS_NAME}-$DST_OS_VERSION
DST_OS_REPO_FILE=${DST_OS}.repo
DST_OS_ISO=$ISO_DIR/${ISO_NAME}-${DST_OS_VERSION}-${ARCH}-dvd.iso
DST_OS_ISO_MP=/mnt/${DST_OS}

SRC_OS_CLASS=$(rpm -qf /etc/profile | awk -F '.' '{ print $(NF-1) }' | sed -e 's/_.*//g')
DST_OS_CLASS=el$(echo $DST_OS_VERSION | awk '{ print int($1) }')

LOG_DIR=/root/distro-hop_${DST_OS_CLASS}
LOG_FILE=$LOG_DIR/upgrade.log
mkdir -p $LOG_DIR
touch $LOG_FILE

function sigint_func()
{
    echo -ne "\nCaught SIGINT, exit\n"
    exit 99
}

check_os_version()
{  
    local os=$OS_NAME
    local os_ver=$OS_VERSION
    echo "Check OS: Found ${os}-${os_ver}" 

    local os_major_ver=$(echo $os_ver | cut -d '.' -f 1)
    local os_minor_ver=$(echo $os_ver | cut -d '.' -f 2)

    local minimal_major_ver=$(echo $MIN_OS_VERSION | cut -d '.' -f 1)
    local minimal_minor_ver=$(echo $MIN_OS_VERSION | cut -d '.' -f 2)

    local dst_major_ver=$(echo $DST_OS_VERSION | cut -d '.' -f 1)
    local dst_minor_ver=$(echo $DST_OS_VERSION | cut -d '.' -f 2)

    if [ $os_major_ver -eq $dst_major_ver -a $os_minor_ver -ge $dst_minor_ver ];then
        echo "Error: $os_ver >= $DST_OS_VERSION , no need to upgrade"
        return 1
    elif [ $os_major_ver -eq $dst_major_ver -a $os_minor_ver -lt $dst_minor_ver ];then
        echo "Error: System minor version is older than expected, update needed"
        return 1
    fi

    if [ $os_major_ver -eq $minimal_major_ver -a $os_minor_ver -lt $minimal_minor_ver ];then
        echo "Error: Minimal version $MIN_OS_VERSION, found $OS_VERSION"
        return 1    
    fi

    if [ $os_major_ver -eq $minimal_major_ver \
            -a $os_minor_ver -ge $minimal_minor_ver \
            -o $os_major_ver -lt $dst_major_ver ];then
        echo "Check OS result: OK"
        return 0
    fi
}

function prtlog()
{
    local logfile=$LOG_FILE

    if [ "$1" = "-f" ];then
        logfile=$2
        shift 2
    fi

    echo "[`date +'%Y-%m-%d %H:%M:%S'`] $@" | tee -a $logfile
}

function make_repo_files()
{
    local logfile=$LOG_DIR/pre_upgrade.log
    local repo_suffix="-${DST_OS_VERSION}-DVD"

    prtlog -f $logfile "Generate $DST_OS_REPO_FILE"
    cd /etc/yum.repos.d
    cat > $DST_OS_REPO_FILE <<-EOF
[BaseOS$repo_suffix]
name=BaseOS$repo_suffix
baseurl=file:///mnt/${DST_OS}/BaseOS
gpgcheck=0
enable=1

[AppStream$repo_suffix]
name=AppStream$repo_suffix
baseurl=file:///mnt/${DST_OS}/AppStream
gpgcheck=0
enable=1
EOF
}

function mount_repos()
{
    local retval=0
    local logfile=$LOG_DIR/pre_upgrade.log
    > $logfile

    [ -e $DST_OS_ISO ] || {
        prtlog -f $logfile "Error: $DST_OS_ISO not found!"
        ((retval++))
    }
   
    if [ $retval -gt 0 ];then
        prtlog -f $logfile "Please prepare needed ISO file(s) under $ISO_DIR"
        exit 1
    fi
  
    mkdir -p $DST_OS_ISO_MP
    prtlog -f $logfile "Mounting ISOs"
    [ -d $DST_OS_ISO_MP/BaseOS ] || mount -o loop,ro $DST_OS_ISO $DST_OS_ISO_MP
}

function reset_dnf_modules()
{
    modules=$(dnf module remove @modulefailsafe 2>&1 \
    | grep nothing \
    | perl -npe 's/.* by module ([^:]+):.*/\1/') 
    
    [ -n "$modules" ] && {
        echo "Reset dnf modules"
        echo $modules | xargs yum -y module reset 2>&1 > /dev/null
    }
}

function disable_old_repos()
{
    local logfile=$LOG_DIR/pre_upgrade.log 

    prtlog -f $logfile "Disable old repos"
    local saved_dir=saved_repos
    cd /etc/yum.repos.d
    mkdir -p $saved_dir

    if [ $USE_DISTRO_REPOS -eq 1 ];then
        repos_pkg=${OS_NAME}-repos
        rpm -q $repos_pkg 2>&1>/dev/null && rpm -e --nodeps  2>&1 >> $logfile
        saved_list=$(/bin/ls -A *.repo 2>/dev/null)
    else
        saved_list=$(/bin/ls -A *.repo 2>/dev/null | $EGREP -v "$DST_OS_REPO_FILE${OTHER_REPO_FILE}")
    fi

    [ -n "$saved_list" ] && /bin/mv -f $saved_list $saved_dir
    (yum clean all; yum makecache) 2>&1 > /dev/null

    prtlog -f $logfile "Reset dnf modules"
    reset_dnf_modules 2>&1 >> $logfile
}

function upgrade()
{
    logfile=$LOG_FILE
    > $logfile

    if [ -e $LOG_DIR/upgrade.done ];then
        echo "Skipped for uprade.done found"
        return 0
    fi

    prtlog "Remove conflict packages"
    dnf --allowerasing -y --setopt=tsflags=test distro-sync 2>&1 \
    | egrep 'from package' \
    | awk '{ print $NF }' | sort | uniq \
    | while read pkg;do rpm -e --nodeps $pkg;done

    if [ $USE_DISTRO_REPOS -eq 1 ];then
        cd /etc/yum.repos.d
        local saved_dir=saved_${DST_OS_CLASS}
        mkdir -p $saved_dir
        local saved_list=$(/bin/ls -A *.repo 2>/dev/null)
        [ -n "${saved_list}" ] && /bin/mv -f $saved_list $saved_dir

        find $DST_OS_ISO_MP \
            -regextype egrep -regex ".*-(release|gpg-keys|repos)-.*" \
        | while read pkg;do 
            rpm -ivh --nodeps --force $pkg 2>&1 >> $logfile
        done

        cd /etc/yum.repos.d
        for repo_file in *.repo;do             
            [ -e ${repo_file}.orig ] || sed -i.orig -e "s/\$releasever/${DST_OS_VERSION}/g" $repo_file
        done

        # Some packages like virt-manager are moved CRB repo on el10
        if [ "${DST_OS_CLASS}" = "el10" ];then
            prtlog "Enable CRB repo for ${DST_OS_CLASS}"
            yum config-manager --enable crb 2>&1 >> $logfile
        fi

        (yum clean all; yum makecache) >> $logfile
    fi

    prtlog ">>> Upgrade ${OS_NAME}-${OS_VERSION} to ${OS_NAME}-${DST_OS_VERSION} by dnf distro-sync"
    (dnf -y --releasever=$DST_OS_VERSION \
        --allowerasing \
        --setopt=deltarpm=false \
        --nobest distro-sync \
        && update-crypto-policies --set LEGACY \
        && rpm --rebuilddb
    ) 2>&1 >> $LOG_FILE \
    && touch $LOG_DIR/upgrade.done
}

function post_upgrade()
{
    local logfile=$LOG_DIR/post_upgrade.log
    local pkgs_list=$LOG_DIR/old_pkgs.lst
    local other_pkgs=$LOG_DIR/other_pkgs.lst
    local post_done=$LOG_DIR/post_upgrade.done
    local install_list=$LOG_DIR/found_in_${DST_OS_CLASS}.lst

    touch $logfile
    
    cd $LOG_DIR
    [ -e $post_done ] && {
        echo "Post upgrade has been done, skipped"
        echo "To do post upgrade again, please run 'export FORCE_POST_UPGRADE=1'"
        return 0
    }

    # Prevent deleting upgraded packages when using 'export FORCE_POST_UPGRADE=1'
    [ -e upgrade.done ] || {
        echo "Error: file upgrade.done not found, please upgrade system first"
        return 1
    }

    local current_os_class=$(rpm -qf /etc/${OS_NAME}-release | awk -F '.' '{ print $(NF-1) }')
    prtlog -f $logfile "Comparing target OS class"
    if [ "${current_os_class}" = "${DST_OS_CLASS}" ];then
        prtlog -f $logfile "Result: OK (specified ${DST_OS_CLASS}, detected ${current_os_class})"
    else
        prtlog -f $logfile "Result: Error (specified ${DST_OS_CLASS}, detected ${current_os_class})"
        exit 1
    fi

    prtlog -f $logfile ">>> Post Upgrade"

    local saved_dir=saved_$DST_OS_CLASS
    cd /etc/yum.repos.d
    mkdir -p $saved_dir
    if [ "${OS_NAME}" != "rhel" ];then
        if [ $USE_DISTRO_REPOS -eq 1 ];then
            prtlog -f $logfile "Using repo files of ${OS_NAME}-repos"
            [ -e $DST_OS_REPO_FILE ] && /bin/mv -f ${DST_OS_REPO_FILE} $saved_dir
            for repo_file in *.repo;do
                rpm -qf $repo_file 2>&1 > /dev/null || /bin/mv -f $repo_file $saved_dir
            done
        else
            prtlog -f $logfile "Saved repo files of ${OS_NAME}-repos to /etc/yum.repos.d/${saved_dir}"
            prtlog -f $logfile "Warning: Some old packages like virt-manager will be removed when using ISO repo only"
            saved_list=$(/bin/ls -A | $EGREP -v "${DST_OS_REPO_FILE}|$saved_dir|saved${OTHER_REPO_FILE}")
            [ -n "$saved_list" ] && /bin/mv -f $saved_list $saved_dir
        fi
    fi

    prtlog -f $logfile "Make yum cache for listing old packages"
    (yum clean all; yum makecache) 2>&1 > /dev/null

    prtlog -f $logfile "Reset DNF modules"
    reset_dnf_modules 2>&1

    # List all remained old packages
    if [ ! -e ${pkgs_list} ];then
        prtlog -f $logfile "List all remained ${SRC_OS} packages to $pkgs_list"
        rpm -qa --qf '%{name}@%{version}@%{release}@%{arch}@%{vendor}\n' \
        | sort \
        | $EGREP -v ".${current_os_class}" > $pkgs_list
        /bin/cp -af $pkgs_list ${pkgs_list}.orig
    fi

    prtlog -f $logfile "Generate thirdparty packages list"
    $EGREP -v "$EXCLUDE_VENDORS" ${pkgs_list}.orig > $other_pkgs

    # Fix the problem that yum/dnf/leapp cannot resolve thirdparty packages and their depends
    if [ -s $other_pkgs ];then
        prtlog -f $logfile "Generte providers list for thirdparty packages"
        providers=$(awk -F '@' '{ print $1 "." $4 }' $other_pkgs \
            | while read pkg;do
                  dep_list=$(rpm -q --requires $pkg | sed -e 's|(.*||g' -e 's|\s*>.*||g' | uniq)
                  dnf provides $dep_list | grep '^Provide' | grep -v ".${DST_OS_CLASS}"  | awk '{ print $3 }'
              done | sort | uniq)
        
        prtlog -f $logfile "Filter out providers for thirdparty"
        dep_providers=$(for item in $providers;do
                provider=$(dnf provides $item | $EGREP ".${DST_OS_CLASS}" | cut -d ' ' -f 1)
                [ -z "$provider" ] && echo $item
            done)

        prtlog -f $logfile "Delete thirdparty packages and its depends from $pkgs_list"
        (cut -d '@' -f 1 < $other_pkgs; echo $dep_providers | tr ' ' '\n') \
        | sort \
        | uniq \
        | while read pkg;do
            [ -n "$pkg" ] && sed -i -e "/${pkg}@/d" $pkgs_list
        done
    fi

    # Remove old packages
    if [ -s $pkgs_list ];then
        prtlog -f $logfile "Remove remained old packages"          
        rpm -e --nodeps $(awk -F '@' '{ printf("%s-%s-%s.%s\n", $1, $2,$3,$4); }' $pkgs_list)
    fi
    systemctl daemon-reload

    prtlog -f $logfile "Create symlink /usr/bin/python3 for yum/dnf"
    cd /usr/bin; /bin/ln -sf $(/bin/ls -A python[0-9].*) python3

    prtlog -f $logfile "Make yum cache after removing old packages"
    (yum clean all
    yum makecache 2>&1
    yum list --available > $LOG_DIR/yum.lst ) >> $logfile

    prtlog -f $logfile "Building install list for old packages found in $DST_OS"
    > $install_list
    while IFS=@ read name version release arch vendor;do
        echo "$name" | grep -q kernel &&  continue
        pkg=""
        pkg=$(dnf provides $name 2>/dev/null | grep ".${arch}" | grep ".${DST_OS_CLASS}" | cut -d ' ' -f 1 | head -n1)
        if [ -n "$pkg" ];then
            echo "$pkg" >> $install_list
            continue
        fi
    done < $pkgs_list
    
    if [ -s $install_list ];then
        prtlog -f $logfile "Install old packages found in ${DST_OS}"
        dnf install --skip-broken -y $(cat $install_list) 2>&1 >> $logfile
    fi

    prtlog -f $logfile "Install back packages after upgraded to ${DST_OS_CLASS}"
    case $DST_OS_CLASS in
        el9)
            yum install -y audit initscripts 2>&1 >> $logfile
            ;;
        el10)
            yum reinstall -y python-unversioned-command python3 2>&1 >> $logfile
            (find $DST_OS_ISO_MP -name 'javapackages-filesystem*' -exec dnf localinstall -y {} \;) 2>&1 >> $logfile
            ;;
    esac
    
    # dbus-daemon is disabled after upgraded to el10
    systemctl is-enabled dbus-daemon 2>&1 > /dev/null || {
        prtlog -f $logfile "Enable dbus-daemon.service"
        systemctl enable -f dbus-daemon 2>&1 >> $logfile
    }

    if [ "${DST_OS_CLASS}" = "el10" ];then
        prtlog -f $logfile "Migrate NetworkManager connections for ${DST_OS_CLASS}"
        (systemctl restart dbus-daemon NetworkManager
        nmcli conn migrate
        cd /etc/NetworkManager/system-connections        
        for netdev in $(nmcli c s | sed -n -e '2,$p' | cut -d ' ' -f 1);do
            nmcli conn modify $netdev connection.autoconnect yes
        done
        ) 2>&1 >> $logfile
    fi

    prtlog -f $logfile "Update grub boot title for $DST_OS"
    os_title=$($EGREP -o '[0-9.]{2,}.*' /etc/${OS_NAME}-release)
    cd /boot/loader/entries
    for file in *.conf;do
        sed -i -r \
        -e "s/[0-9.]{2,} \(.*/${os_title}/g" \
        -e "s/ [0-9]*$/ ${os_title}/" \
        $file
    done
    cd $LOG_DIR

    touch $post_done
}

# ---------------------------- Main --------------------------------------
trap sigint_func SIGINT

[ -d $ISO_DIR ] || {
    echo "Error: $ISO_DIR not found!"
    exit 1
}
    
[ -n "$FORCE_POST_UPGRADE" ] && [ $FORCE_POST_UPGRADE -eq 1 ] && {
    /bin/rm -f $LOG_DIR/post_upgrade.done
    post_upgrade
    exit $?
}

check_os_version || exit 1
mount_repos
make_repo_files
disable_old_repos
upgrade && post_upgrade