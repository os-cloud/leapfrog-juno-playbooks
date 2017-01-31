#!/usr/bin/env bash

set -e -u -v +x
#install the necessary packages
apt-get install -y libffi-dev\
                   libssl-dev

#install the setuptools
pip install setuptools

#make a directory if the directory doesn't exist
[ -d /openstack/log/ansible-logging ] || mkdir /openstack/log/ansible-logging
#create the file for deploying juno
touch /openstack/log/ansible-logging/ansible.log
