#!/usr/bin/env bash
# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


## Shell Opts ----------------------------------------------------------------
set -e -u -v +x

## Vars
export DEPLOY_SWIFT=${DEPLOY_SWIFT:-"yes"}
export FLUSH_IPTABLES=${FLUSH_IPTABLES:-"yes"}
export SYMLINK_DIR=${SYMLINK_DIR:-"$(pwd)/logs"}

# Ubuntu repos
UBUNTU_RELEASE=$(lsb_release -sc)
UBUNTU_REPO=${UBUNTU_REPO:-"http://mirror.rackspace.com/ubuntu"}


## Functions -----------------------------------------------------------------

info_block "Checking for required libraries." || source $(dirname ${0})/scripts-library.sh

## Main ----------------------------------------------------------------------

# Make the /openstack/log directory for openstack-infra gate check log publishing
mkdir -p /openstack/log

# Implement the log directory link for openstack-infra log publishing
ln -sf /openstack/log $SYMLINK_DIR

# Create ansible logging directory and add in a log file entry into ansible.cfg
if [ -f "rpc_deployment/ansible.cfg" ];then
  mkdir -p /openstack/log/ansible-logging
  if [ ! "$(grep -e '^log_path\ =\ /openstack/log/ansible-logging/ansible.log' rpc_deployment/ansible.cfg)" ];then
    sed -i '/\[defaults\]/a log_path = /openstack/log/ansible-logging/ansible.log' rpc_deployment/ansible.cfg
  fi
fi

# Check that the link creation was successful
[[ -d $SYMLINK_DIR ]] || exit_fail
if ! [ -d $SYMLINK_DIR ] ; then
    echo "Could not create a link from /openstack/log to ${SYMLINK_DIR}"
    exit_fail
fi

# Enable logging of all commands executed
set -x

# Update the package cache
apt-get update

# Remove known conflicting packages in the base image
apt-get purge -y libmysqlclient18 mysql-common

# Install required packages
apt-get install -y python-dev \
                   python2.7 \
                   build-essential \
                   curl \
                   git-core \
                   ipython \
                   tmux \
                   vim \
                   vlan \
                   bridge-utils \
                   lvm2 \
                   xfsprogs \
                   linux-image-extra-$(uname -r)

# output diagnostic information
log_instance_info && set -x

if [ "${FLUSH_IPTABLES}" == "yes" ]; then
  # Flush all the iptables rules set by openstack-infra
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
fi

# Ensure newline at end of file (missing on Rackspace public cloud Trusty image)
if ! cat -E /etc/ssh/sshd_config | tail -1 | grep -q "\$$"; then
  echo >> /etc/ssh/sshd_config
fi

# Ensure that sshd permits root login, or ansible won't be able to connect
if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi

# create /opt if it doesn't already exist
if [ ! -d "/opt" ];then
  mkdir /opt
fi

# create /etc/rc.local if it doesn't already exist
if [ ! -f "/etc/rc.local" ];then
  touch /etc/rc.local
  chmod +x /etc/rc.local
fi

# ensure that the ssh key exists and is an authorized_key
ssh_key_create

# prepare the storage appropriately
configure_diskspace

# build the loopback drive for swap to use
loopback_create /opt/swap.img 1024M thick swap

# Ensure swap will be used on the host
sysctl -w vm.swappiness=10 | tee -a /etc/sysctl.conf

# build the loopback drive for cinder to use
# but only if the cinder-volumes vg doesn't already exist
if ! vgs cinder-volumes > /dev/null 2>&1; then
  CINDER="cinder.img"
  loopback_create /opt/${CINDER} 10G thin rc
  CINDER_DEVICE=$(losetup -a | awk -F: "/${CINDER}/ {print \$1}")
  pvcreate ${CINDER_DEVICE}
  pvscan
  vgcreate cinder-volumes ${CINDER_DEVICE}
fi

# build the loopback drives for swift to use
if [ "${DEPLOY_SWIFT}" == "yes" ]; then
  for SWIFT in swift1.img swift2.img swift3.img; do
    loopback_create /opt/${SWIFT} 10G thin none
    if ! grep -q "^/opt/${SWIFT}" /etc/fstab; then
      echo "/opt/${SWIFT} /srv/${SWIFT} xfs loop,noatime,nodiratime,nobarrier,logbufs=8 0 0" >> /etc/fstab
    fi
    if ! mount | grep -q "^/opt/${SWIFT}"; then
      mkfs.xfs -f /opt/${SWIFT}
      mkdir -p /srv/${SWIFT}
      mount /srv/${SWIFT}
    fi
  done
fi

# copy the required interfaces configuration file into place
IFACE_CFG_SOURCE="etc/network/interfaces.d/aio_interfaces.cfg"
IFACE_CFG_TARGET="/${IFACE_CFG_SOURCE}"
cp ${IFACE_CFG_SOURCE} ${IFACE_CFG_TARGET}

# Ensure the network source is in place
if ! grep -q "^source /etc/network/interfaces.d/\*.cfg$" /etc/network/interfaces; then
  echo -e "\nsource /etc/network/interfaces.d/*.cfg" | tee -a /etc/network/interfaces
fi

# Set base DNS to google, ensuring consistent DNS in different environments
if [ ! "$(grep -e '^nameserver 8.8.8.8' -e '^nameserver 8.8.4.4' /etc/resolv.conf)" ];then
  echo -e '\n# Adding google name servers\nnameserver 8.8.8.8\nnameserver 8.8.4.4' | tee -a /etc/resolv.conf
fi

# Set the host repositories to only use the same ones, always, for the sake of consistency.
cat > /etc/apt/sources.list <<EOF
# Normal repositories
deb ${UBUNTU_REPO} ${UBUNTU_RELEASE} main universe
EOF

# Bring up the new interfaces
for iface in $(awk '/^iface/ {print $2}' ${IFACE_CFG_TARGET}); do
  /sbin/ifup $iface || true
done

# Pre-fetch the old container image so that we can adjust it
# before deployment
mkdir -p /var/cache/lxc
pushd /var/cache/lxc
wget http://rpc-repo.rackspace.com/container_images/rpc-trusty-container.old.tgz
mv rpc-trusty-container.old.tgz rpc-trusty-container.tgz
tar -zxf rpc-trusty-container.tgz

# Adjust the container sources so that it doesn't get updated packages
echo "deb http://mirror.rackspace.com/ubuntu trusty main universe" > /var/cache/lxc/trusty/rootfs-amd64/etc/apt/sources.list

# Downgrade the tzdata package to the latest available in the release of Trusty
# to prevent the JDK installation from failing
chroot /var/cache/lxc/trusty/rootfs-amd64/ apt-get update
chroot /var/cache/lxc/trusty/rootfs-amd64/ apt-get install -y --force-yes tzdata=2014b-1

popd

# RAX Public Cloud's hypervisor does not detect properly
# so we need to setup libvirt-bin and modify the cpu map
apt-get install -y libvirt-bin
cp etc/cpu_map.xml /usr/share/libvirt/cpu_map.xml
service libvirt-bin stop && service libvirt-bin start

# output an updated set of diagnostic information
log_instance_info

# Final message
info_block "The system has been prepared for an all-in-one build."
