#!/usr/bin/env bash

# Load service variables
source openrc

# Create base flavors for the new deployment
for flavor in micro tiny mini small medium large xlarge heavy; do
  NAME="m1.${flavor}"
  ID="${ID:-0}"
  RAM="${RAM:-256}"
  DISK="${DISK:-1}"
  VCPU="${VCPU:-1}"
  SWAP="${SWAP:-0}"
  EPHEMERAL="${EPHEMERAL:-0}"
  nova flavor-delete $ID > /dev/null || echo "No Flavor with ID: [ $ID ] found to clean up"
  nova flavor-create $NAME $ID $RAM $DISK $VCPU --swap $SWAP --is-public true --ephemeral $EPHEMERAL --rxtx-factor 1
  let ID=ID+1
  let RAM=RAM*2
  if [ "$ID" -gt 5 ];then
    let VCPU=VCPU*2
    let DISK=DISK*2
    let EPHEMERAL=256
    let SWAP=4
  elif [ "$ID" -gt 4 ];then
    let VCPU=VCPU*2
    let DISK=DISK*4+$DISK
    let EPHEMERAL=$DISK/2
    let SWAP=4
  elif [ "$ID" -gt 3 ];then
    let VCPU=VCPU*2
    let DISK=DISK*4+$DISK
    let EPHEMERAL=$DISK/3
    let SWAP=4
  elif [ "$ID" -gt 2 ];then
    let VCPU=VCPU+$VCPU/2
    let DISK=DISK*4
    let EPHEMERAL=$DISK/3
    let SWAP=4
  elif [ "$ID" -gt 1 ];then
    let VCPU=VCPU+1
    let DISK=DISK*2+$DISK
  fi
done

# Neutron provider network setup
neutron net-create GATEWAY_NET \
    --router:external \
    --provider:physical_network=flat \
    --provider:network_type=flat

neutron subnet-create GATEWAY_NET 172.29.248.0/22 \
    --name GATEWAY_NET_SUBNET \
    --gateway 172.29.248.1 \
    --allocation-pool start=172.29.248.201,end=172.29.248.255 \
    --dns-nameservers list=true 8.8.4.4 8.8.8.8

# Neutron private network setup
neutron net-create PRIVATE_NET \
    --shared \
    --router:external \
    --provider:network_type=vxlan \
    --provider:segmentation_id 101

neutron subnet-create PRIVATE_NET 192.168.0.0/24 \
    --enable-dhcp \
    --name PRIVATE_NET_SUBNET

# Neutron router setup
ROUTER_ID=$(neutron router-create GATEWAY_NET_ROUTER | grep -w id | awk '{print $4}')
neutron router-gateway-set \
    ${ROUTER_ID} \
    $(neutron net-list | awk '/GATEWAY_NET/ {print $2}')

neutron router-interface-add \
    ${ROUTER_ID} \
    $(neutron subnet-list | awk '/PRIVATE_NET_SUBNET/ {print $2}')

# Neutron security group setup
SEC_GROUPS=$(python <<EOC
x = $(neutron security-group-list --column id --format json)
for i in x: 
  print(i['id'])
EOC
)

for id in ${SEC_GROUPS}; do
    # Allow ICMP
    neutron security-group-rule-create --protocol icmp \
                                       --direction ingress \
                                       $id || true
    # Allow all TCP
    neutron security-group-rule-create --protocol tcp \
                                       --port-range-min 1 \
                                       --port-range-max 65535 \
                                       --direction ingress \
                                       $id || true
    # Allow all UDP
    neutron security-group-rule-create --protocol udp \
                                       --port-range-min 1 \
                                       --port-range-max 65535 -\
                                       -direction ingress \
                                       $id || true
done

# Create some default images
wget http://uec-images.ubuntu.com/releases/14.04/release/ubuntu-14.04-server-cloudimg-amd64-disk1.img
glance image-create --name 'Ubuntu14.04-Test-LEAP' \
                    --container-format bare \
                    --disk-format qcow2 \
                    --is-public=True \
                    --progress \
                    --file ubuntu-14.04-server-cloudimg-amd64-disk1.img
rm ubuntu-14.04-server-cloudimg-amd64-disk1.img

TEST_IMAGE="$(glance image-list | awk '/Ubuntu14.04-Test-LEAP/ {print $2}')"
L2_NET="$(neutron net-list | awk '/GATEWAY_NET/ {print $2}')"

nova boot --image "${TEST_IMAGE}" \
          --flavor "m1.mini" \
          --nic "net-id=${L2_NET}" \
          --max-count 2 \
          "TEST-L2-Networks"

nova boot --image "${TEST_IMAGE}" \
          --flavor "m1.mini" \
          --nic "net-id=$(neutron net-list | awk '/PRIVATE_NET/ {print $2}')" \
          --max-count 2 \
          "TEST-L3-Networks"

nova boot --image "${TEST_IMAGE}" \
          --flavor "m1.mini" \
          --nic "net-id=${L2_NET}" \
          --max-count 2 \
          "TEST-Cinder-LVM"

for instance in $(nova list | awk '/TEST-L3-Networks/ {print $2}'); do
  FLOATING_IP_ID="$(neutron floatingip-create ${L2_NET} | grep -w "id" | awk '{print $4}')"
  PORT_ID="$(neutron port-list --device_id=${instance} | awk '/ip_address/ {print $2}')"
  neutron floatingip-associate "${FLOATING_IP_ID}" "${PORT_ID}"
done

for instance in $(nova list | awk '/TEST-Cinder-LVM/ {print $2}'); do
  CINDER_ID="$(cinder create --display-name "${instance}" 2 | grep -w id | awk '{print $4}')"
  while [[ $(cinder show ${CINDER_ID} | grep -w "status" | grep -v "os-vol" | awk '{print $4}') != "available" ]]; do
    sleep 4
  done
  while [[ $(nova show ${instance} | grep -w vm_state | awk '{print $4}') != "active" ]]; do
    sleep 4
  done
  nova volume-attach "${instance}" "${CINDER_ID}" /dev/sdb1
done

swift upload Test-Swift "${HOME}"

