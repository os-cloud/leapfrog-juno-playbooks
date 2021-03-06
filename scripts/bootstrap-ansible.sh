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
#
# (c) 2014, Kevin Carter <kevin.carter@rackspace.com>

## Shell Opts ----------------------------------------------------------------
set -e -u -x


## Vars ----------------------------------------------------------------------
export ANSIBLE_GIT_RELEASE=${ANSIBLE_GIT_RELEASE:-"v1.6.10"}
export ANSIBLE_GIT_REPO=${ANSIBLE_GIT_REPO:-"https://github.com/ansible/ansible"}
export ANSIBLE_ROLE_FILE=${ANSIBLE_ROLE_FILE:-"ansible-role-requirements.yml"}
export ANSIBLE_WORKING_DIR=${ANSIBLE_WORKING_DIR:-/opt/ansible_${ANSIBLE_GIT_RELEASE}}
export GET_PIP_URL=${GET_PIP_URL:-"https://bootstrap.pypa.io/get-pip.py"}
export SSH_DIR=${SSH_DIR:-"/root/.ssh"}
export UPDATE_ANSIBLE_REQUIREMENTS=${UPDATE_ANSIBLE_REQUIREMENTS:-"yes"}
export PIP2_INSTALL=" pip2 install --ignore-installed"
export PIP_INSTALL=" pip install --ignore-installed"

## Functions -----------------------------------------------------------------
info_block "Checking for required libraries." 2> /dev/null || source $(dirname ${0})/scripts-library.sh


## Main ----------------------------------------------------------------------
info_block "Bootstrapping System with Ansible"

# Create the ssh dir if needed
ssh_key_create

# Install the base packages
apt-get update
apt-get -y install git python-all python-dev curl autoconf g++ python2.7-dev libssl-dev libffi-dev

# If the working directory exists remove it
if [ -d "${ANSIBLE_WORKING_DIR}" ];then
    rm -rf "${ANSIBLE_WORKING_DIR}"
fi

#make a directory if the directory doesn't exist
[ -d /openstack/log/ansible-logging ] || mkdir -p /openstack/log/ansible-logging
#create the file for deploying juno
touch /openstack/log/ansible-logging/ansible.log

# Clone down the base ansible source
git clone "${ANSIBLE_GIT_REPO}" "${ANSIBLE_WORKING_DIR}"
pushd "${ANSIBLE_WORKING_DIR}"
    git checkout "${ANSIBLE_GIT_RELEASE}"
    git submodule update --init --recursive
popd

# Install pip
if [ ! "$(which pip)" ];then
    curl ${GET_PIP_URL} > /opt/get-pip.py
    python /opt/get-pip.py pip==6.1.1 setuptools==7.0 wheel==0.24.0 --trusted-host rpc-repo.rackspace.com
fi

# Install requirements if there are any
if [ -f "requirements.txt" ];then
    ${PIP2_INSTALL} -r requirements.txt || ${PIP_INSTALL} -r requirements.txt
fi

# Install ansible
${PIP2_INSTALL} "${ANSIBLE_WORKING_DIR}" || ${PIP_INSTALL} "${ANSIBLE_WORKING_DIR}"

# Update dependent roles
if [ -f "${ANSIBLE_ROLE_FILE}" ];then
    # Pull all required roles.
    ansible-galaxy install --role-file=${ANSIBLE_ROLE_FILE} \
                           --ignore-errors \
                           --force
fi

# Create openstack ansible wrapper tool
cat > /usr/local/bin/openstack-ansible <<EOF
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
#
# (c) 2014, Kevin Carter <kevin.carter@rackspace.com>

# OpenStack wrapper tool to ease the use of ansible with multiple variable files.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

function info() {
    echo -e "\e[0;35m\${@}\e[0m"
}

# Discover the variable files.
VAR1="\$(for i in \$(ls /etc/rpc_deploy/user_*.yml); do echo -ne "-e @\$i "; done)"

# Provide information on the discovered variables.
info "Variable files: \"\${VAR1}\""

# Run the ansible playbook command.
\$(which ansible-playbook) \${VAR1} \$@
EOF

# Ensure wrapper tool is executable
chmod +x /usr/local/bin/openstack-ansible

echo "openstack-ansible script created."
echo "System is bootstrapped and ready for use."
