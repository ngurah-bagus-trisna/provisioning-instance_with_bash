#!/bin/bash
VOLUME_POOL=/data/vms
IMAGE_POOL=/data/isos

# create network first

PRE_NET_NAME=$(cat ./genvariable | grep NET_NAME | tr -d 'NET_NAME=' | uniq )
NET_SUB=$(echo $PRE_NET_NAME | tr -dc '0-9,.')

printf "\n ====== Create Network ======\n"

cat > ./$PRE_NET_NAME.xml << EOF
<network>
  <name>$PRE_NET_NAME</name>
  <forward mode='route'/>
  <bridge name='$PRE_NET_NAME' stp='on' delay='0'/>
  <ip address='$NET_SUB.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$NET_SUB.5' end='$NET_SUB.254'/>
    </dhcp>
  </ip>
</network>
EOF

printf "\n ======== Start Network ========\n"

virsh net-define --file ./$PRE_NET_NAME.xml
virsh net-start $PRE_NET_NAME
virsh net-autostart $PRE_NET_NAME

rm -rf ./net-$NET_SUB.xml


#parse data from source.txt
while read line; do
  #check if line contains NAME
  if [[ $line == NAME=* ]]; then
    NAME=${line#*=}
    NAME=${NAME//\"}
    MAC=$(date +%s | md5sum | head -c 6 | sed -e 's/\([0-9A-Fa-f]\{2\}\)/\1:/g' -e 's/\(.*\):$/\1/' | sed -e 's/^/52:54:00:/')
  fi

  #check if line contains CPU
  if [[ $line == CPU=* ]]; then
    CPU=${line#*=}
  fi

  #check if line contains RAM
  if [[ $line == RAM=* ]]; then
    RAM=${line#*=}
  fi

  #check if line contains DISK
  if [[ $line == DISK=* ]]; then
    DISK=${line#*=}
  fi

  #check if line contains IP
  if [[ $line == IP=* ]]; then
    IP=${line#*=}
  fi

  #check if line contains NET_NAME
  if [[ $line == NET_NAME=* ]]; then
    NET_NAME=${line#*=}
    NET_INT=$(virsh net-info --network $NET_NAME | awk '{print $2}' | grep vi)
  fi

  #check if line contains NAME_IMAGE
  if [[ $line == NAME_IMAGE=* ]]; then
    NAME_IMAGE=${line#*=}
  fi

  #provisioning instance with parsed data
  if [[ -n $NAME && -n $CPU && -n $RAM && -n $DISK && -n $IP && -n $NET_NAME && -n $NAME_IMAGE ]]; then
    #create instance directory
    printf "\n =========== Provisioning Instance $NAME =============== \n\n"
    mkdir -p $VOLUME_POOL/$NAME

    #convert base image to root disk
    printf "\n =========== Convert Cloud Image ============ \n \n"
    qemu-img create -b $IMAGE_POOL/$NAME_IMAGE -F qcow2 -f qcow2 $VOLUME_POOL/$NAME/vda.qcow2 $DISK"G"
    #qemu-img convert -f raw -O qcow2 $IMAGE_POOL/$NAME_IMAGE $VOLUME_POOL/$NAME/vda.qcow2

    #resize root disk
    # qemu-img resize $VOLUME_POOL/$NAME/vda.qcow2 $DISK"G"

    cat > $VOLUME_POOL/$NAME/user-data << EOF
#cloud-config
timezone: Asia/Jakarta
users:
  - name: ubuntu
    ssh-authorized-keys:
      - <ssh-keys>
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
EOF

    #create meta-data for cloud-init
    echo "instance-id: $NAME" > $VOLUME_POOL/$NAME/meta-data
    echo "local-hostname: $NAME" >> $VOLUME_POOL/$NAME/meta-data
    
    # cloud-localds not supported on rhel, rocky, alma.
    # cloud-localds -v $VOLUME_POOL/$NAME/cloud-init.iso $VOLUME_POOL/$NAME/user-data $VOLUME_POOL/$NAME/meta-data
    
    genisoimage  -output $VOLUME_POOL/$NAME/cloud-init.iso -volid cidata -joliet -rock $VOLUME_POOL/$NAME/user-data $VOLUME_POOL/$NAME/meta-data
    
    printf "\n =========== Configure Network =========== \n\n"
    virsh net-update $NET_NAME add ip-dhcp-host --xml "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config
    # virsh net-update $NET_NAME add dns-host "<host ip='$IP'><hostname>$NAME</hostname></host>" --config --live

    #create instance

    printf "\n =========== Create Instance $NAME ============ \n\n"
    virt-install --name $NAME \
    --ram $RAM \
    --vcpus $CPU \
    --disk $VOLUME_POOL/$NAME/vda.qcow2,bus=virtio,format=qcow2 \
    --disk $VOLUME_POOL/$NAME/cloud-init.iso,device=cdrom \
    --network network=$NET_NAME,mac=$MAC \
    --graphics none \
    --osinfo detect=on,require=off \
    --import \
    --noautoconsole


    #remove cloud-init iso
    #rm $VOLUME_POOL/$NAME/cloud-init.iso

    #unset parsed data
    unset NAME
    unset CPU
    unset RAM
    unset DISK
    unset IP
    unset NET_NAME
    unset NET_INT
    unset NAME_IMAGE
    unset MAC
  fi
done < genvariable
