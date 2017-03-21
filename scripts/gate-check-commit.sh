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

## Variables -----------------------------------------------------------------

export ADMIN_PASSWORD=${ADMIN_PASSWORD:-"secrete"}
export BOOTSTRAP_ANSIBLE=${BOOTSTRAP_ANSIBLE:-"yes"}
export BOOTSTRAP_AIO=${BOOTSTRAP_AIO:-"yes"}
export DEPLOY_SWIFT=${DEPLOY_SWIFT:-"yes"}
export DEPLOY_TEMPEST=${DEPLOY_TEMPEST:-"yes"}
export RUN_PLAYBOOKS=${RUN_PLAYBOOKS:-"yes"}
export RUN_TEMPEST=${RUN_TEMPEST:-"yes"}
# Ansible options
export ANSIBLE_PARAMETERS=${ANSIBLE_PARAMETERS:-"-vvvvv"}
# limit Ansible forks for gate check
export FORKS=${FORKS:-10}
# tempest and testr options, default is to run tempest in serial
export RUN_TEMPEST_OPTS=${RUN_TEMPEST_OPTS:-'--serial'}
export TESTR_OPTS=${TESTR_OPTS:-''}
export TEMPEST_FLAT_CIDR=${TEMPEST_FLAT_CIDR:-"172.29.248.0/22"}
export TEMPEST_FLAT_GATEWAY=${TEMPEST_FLAT_GATEWAY:-"172.29.248.100"}
# Limit the gate check to only performing one attempt, unless already set
export MAX_RETRIES=${MAX_RETRIES:-"2"}

## Functions -----------------------------------------------------------------

info_block "Checking for required libraries." || source $(dirname ${0})/scripts-library.sh

## Main ----------------------------------------------------------------------

# ensure that the current kernel can support vxlan
if ! modprobe vxlan; then
  MINIMUM_KERNEL_VERSION=$(awk '/required_kernel/ {print $2}' rpc_deployment/inventory/group_vars/all.yml)
  info_block "A minimum kernel version of ${MINIMUM_KERNEL_VERSION} is required for vxlan support."
  exit 1
fi

# Get initial host information and reset verbosity
set +x && log_instance_info && set -x

# Bootstrap ansible if required
if [ "${BOOTSTRAP_ANSIBLE}" == "yes" ]; then
  bash $(dirname ${0})/bootstrap-ansible.sh
fi

# Bootstrap an AIO setup if required
if [ "${BOOTSTRAP_AIO}" == "yes" ]; then
  bash $(dirname ${0})/bootstrap-aio.sh
fi

# Get initial host information and reset verbosity
set +x && log_instance_info && set -x

# Install requirements
pip2 install -r requirements.txt || pip install -r requirements.txt

# Copy the base etc files
if [ ! -d "/etc/rpc_deploy" ];then
  cp -R etc/rpc_deploy /etc/

  USER_VARS_PATH="/etc/rpc_deploy/user_variables.yml"

  # Adjust any defaults to suit the AIO
  # commented lines are removed by pw-token gen, so this substitution must
  # happen prior.
  sed -i "s/# nova_virt_type:.*/nova_virt_type: qemu/" ${USER_VARS_PATH}
  sed -i "s/# logstash_heap_size_mb:/logstash_heap_size_mb:/" ${USER_VARS_PATH}
  sed -i "s/# elasticsearch_heap_size_mb:/elasticsearch_heap_size_mb:/" ${USER_VARS_PATH}

  # Generate random passwords and tokens
  ./scripts/pw-token-gen.py --file ${USER_VARS_PATH}

  # Reduce galera gcache size in an attempt to fit into an 8GB cloudserver
  if grep -q galera_gcache_size ${USER_VARS_PATH}; then
    sed -i 's/galera_gcache_size:.*/galera_gcache_size: 50M/'
  else
    echo 'galera_gcache_size: 50M' >> ${USER_VARS_PATH}
  fi

  # reduce the mysql innodb_buffer_pool_size
  echo 'innodb_buffer_pool_size: 512M' | tee -a ${USER_VARS_PATH}

  if [ "${DEPLOY_TEMPEST}" == "yes" ]; then
    echo "tempest_public_subnet_cidr: ${TEMPEST_FLAT_CIDR}" | tee -a ${USER_VARS_PATH}
    echo "tempest_public_gateway_ip: ${TEMPEST_FLAT_GATEWAY}" | tee -a ${USER_VARS_PATH}
  fi

  # Set the minimum kernel version to our specific kernel release because it passed the vxlan test.
  echo "required_kernel: $(uname --kernel-release)" | tee -a ${USER_VARS_PATH}

  # Set the development repo location
  echo 'rpc_repo_url: "http://rpc-repo.rackspace.com"' | tee -a ${USER_VARS_PATH}

  # change the generated passwords for the OpenStack (admin) and Kibana (kibana) accounts
  sed -i "s/keystone_auth_admin_password:.*/keystone_auth_admin_password: ${ADMIN_PASSWORD}/" ${USER_VARS_PATH}
  sed -i "s/kibana_password:.*/kibana_password: ${ADMIN_PASSWORD}/" ${USER_VARS_PATH}

  if [ "${DEPLOY_SWIFT}" == "yes" ]; then
    # ensure that glance is configured to use swift
    sed -i "s/glance_default_store:.*/glance_default_store: swift/" ${USER_VARS_PATH}
    sed -i "s/glance_swift_store_auth_address:.*/glance_swift_store_auth_address: '{{ auth_identity_uri }}'/" ${USER_VARS_PATH}
    sed -i "s/glance_swift_store_container:.*/glance_swift_store_container: glance_images/" ${USER_VARS_PATH}
    sed -i "s/glance_swift_store_key:.*/glance_swift_store_key: '{{ glance_service_password }}'/" ${USER_VARS_PATH}
    sed -i "s/glance_swift_store_region:.*/glance_swift_store_region: RegionOne/" ${USER_VARS_PATH}
    sed -i "s/glance_swift_store_user:.*/glance_swift_store_user: 'service:glance'/" ${USER_VARS_PATH}
    echo "cinder_service_backup_program_enabled: True" | tee -a ${USER_VARS_PATH}
    echo "tempest_volume_backup_enabled: True" | tee -a ${USER_VARS_PATH}
  fi

  if [ "${BOOTSTRAP_AIO}" == "yes" ]; then
    # adjust the default user configuration for the AIO
    USER_CONFIG_PATH="/etc/rpc_deploy/rpc_user_config.yml"
    ENV_CONFIG_PATH="/etc/rpc_deploy/rpc_environment.yml"
    sed -i "s/environment_version: .*/environment_version: $(md5sum ${ENV_CONFIG_PATH} | awk '{print $1}')/" ${USER_CONFIG_PATH}
    SERVER_IP_ADDRESS="$(ip -o -4 addr show dev eth0 | awk -F '[ /]+' '/global/ {print $4}')"
    sed -i "s/external_lb_vip_address: .*/external_lb_vip_address: ${SERVER_IP_ADDRESS}/" ${USER_CONFIG_PATH}
    if [ "${DEPLOY_SWIFT}" == "yes" ]; then
      # add the swift proxy host network provider map
      sed -i 's/# - swift_proxy/- swift_proxy/' ${USER_CONFIG_PATH}
    fi
  fi
fi

# Run the ansible playbooks if required
if [ "${RUN_PLAYBOOKS}" == "yes" ]; then
  # Set-up our tiny awk script.
  strip_debug="
    !/(^[ 0-9|:.-]+<[0-9.]|localhost+>)|Extracting/ {
      gsub(/{.*/, \"\");
      gsub(/\\n.*/, \"\");
      gsub(/\=\>.*/, \"\");
      print
    }
  "
  set -o pipefail
  bash $(dirname ${0})/run-playbooks.sh | awk "${strip_debug}"
  set +o pipefail
fi

# Run the tempest tests if required
if [ "${RUN_TEMPEST}" == "yes" ]; then
  bash $(dirname ${0})/run-tempest.sh
fi
