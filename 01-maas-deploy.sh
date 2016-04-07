#!/usr/bin/sh
# Check a bunch of common openstack stuff in one place, post-install and tell
# the installer how it all looks.

# Pull in admin credentials
# source juju.rc
source /root/keystonerc_admin

VM='maas-vm'
key='/root/.ssh/juju_id_rsa'

# NOTES: apt-get install juju-quickstart juju-core
# juju quickstart

function verify_creds() {

   # Test to check for admin creds.
   echo -n "Verifying admin credentials: "
   env | grep -q OS_AUTH_URL
   check_exit_code
}

function create_sec_group() {

   echo -n "Creating a security group: "
   neutron security-group-create smssh &> /dev/null

   # Wide open for now..
   nova secgroup-add-rule smssh tcp 1 65535 0.0.0.0/0

   #for port in 22 80 443; do
      #neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol \
           #tcp --port-range-min $port --port-range-max $port smssh 
   #done

   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
      --protocol icmp smssh 

   neutron security-group-list | grep -q smssh
   check_exit_code
}

function create_provider_network() {

   echo -n "Checking for provider network: "
   neutron net-list | grep -q floating

   if [ $? != '0' ]; then

      # This is our 'public' network used for either floating IP's and a virtual router
      # or just create VM's with a nic here for direct access (easier).
      net=$(ifconfig br1 | perl -lane 'print $1 if /inet (.*?)\s/' | cut -d'.' -f1-3);
      start="$net.100"
      end="$net.120"
      gateway=$(route -n |grep '^0.0.0.0' |awk '{print $2}')
      mask=$(ifconfig br1|perl -lane 'print $1 if /netmask (.*?)\s/')
      prefix=$(/bin/ipcalc -p $start $mask | awk -F\= '{print $2}')

      echo "Installing ($net.0/$prefix)"

      neutron net-create floating --provider:network_type flat \
          --provider:physical_network RegionOne --router:external=True 

      neutron subnet-create --name floating-subnet --allocation-pool \
          start=$start,end=$end --gateway $gateway floating $net.0/24 \
          --dns_nameservers list=true 8.8.8.8 

   else
      echo "Ok"
   fi
}

function create_virtual_router() {

   echo -n "Checking for a virtual router: "

   neutron router-list | grep -q router1
   if [ $? != '0' ]; then
      echo "Installing"

      neutron router-create router1 
      neutron router-gateway-set router1 floating 
      neutron router-interface-add router1 subnet1 
   else
      echo "Ok"
   fi
}

function create_tenant_networks() {

   echo -n "Checking for guest networks: "
   neutron net-list | grep -q smnet1

   if [ $? != '0' ]; then

      echo "Installing"
      neutron net-create --provider:physical_network RegionOne --provider:network_type vlan --provider:segmentation_id 48 smnet1 
      neutron subnet-create smnet1 10.10.10.0/24 --name subnet1 --enable-dhcp False

   else
      echo "Ok"
   fi
}

function boot_vm() {

   echo -n "Checking for management VM: "

   nova list --all-tenants | grep -q $VM

   if [ $? != '0' ]; then
      echo "Booting Up"
      # Management VM
      nova boot --image $(nova image-list | grep ubuntu1404 | awk '{print $2}') --flavor m1.large \
          --nic net-id=$(neutron net-list | grep floating | awk '{print $2}')  \
          --nic net-id=$(neutron net-list | grep smnet1 | awk '{print $2}')  \
          --key_name juju-key --security_groups smssh $VM 

   else
      echo "Ok" 
   fi
}

function create_flavors() {

   echo -n "Checking for m1.medium flavor: "
   nova flavor-list|grep -q m1.medium
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.medium auto 4096 40 2 
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.large flavor: "
   nova flavor-list|grep -q m1.large
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.large auto 8192 80 4 
   else
      echo "Ok"
   fi

   echo -n "Checking for m1.xlarge flavor: "
   nova flavor-list|grep -q m1.xlarge
   if [ $? != '0' ]; then
      echo "Installing"
      nova flavor-create m1.xlarge auto 16384 160 8 
   else
      echo "Ok"
   fi
}

function create_ssh_key() {

   echo -n "Checking for crypto keys: "
   if [ ! -f $key.pub ]; then
      echo "Installing"
      nova keypair-add juju-key > $key
      chmod 400 $key
   else
      echo "Ok"
   fi
}


function wait_for_running() {

   echo -n "Waiting for (${num_of_vms}) VM 'Running' status: "
   sleep 5

   # If we don't get this far, boot failure occured.
   nova list | grep -q juju
   if [ $? -ne 0 ]; then
      echo "Failed to boot VM."
      clean_up
      exit 255
   fi
}

function clean_up() {

   ip=$(get_vm_ip)
   cat ~/.ssh/known_hosts | grep -v $ip > /tmp/known_hosts
   mv /tmp/known_hosts /root/.ssh/

   for uuid in `nova list |grep $VM |awk '{print $2}'`
   do
      nova delete $uuid
   done

   sleep 5

   for router in `neutron router-list|grep router1|awk '{print $2}'`
      do
         for subnet in `neutron router-port-list ${router} -c fixed_ips -f csv | egrep -o '[0-9a-z\-]{36}'`
            do
               neutron router-interface-delete ${router} ${subnet}
            done
         neutron router-gateway-clear ${router}
         neutron router-delete ${router}
      done


   for net in `neutron net-list|egrep 'smnet|floating'|awk '{print $2}'`
   do
      neutron net-delete $net
   done

   for uuid in `nova secgroup-list | grep smssh|awk '{print $2}'`
   do
      nova secgroup-delete $uuid &> /dev/null
   done

   for uuid in `nova flavor-list | egrep 'm1.small|m1.medium|m1.large|m1.xlarge' |awk '{print $2}'`
   do 
      nova flavor-delete $uuid &> /dev/null
   done

   rm -rf $key
   nova keypair-delete juju-key &> /dev/null
}

function check_exit_code() {

   if [ $? -ne 0 ]; then
      $SMOKE_RES = false
      echo "Failed"
      echo "Running clean up"
      clean_up
      exit 255
   fi
   echo "Success"
}

function get_vm_ip() {

   ip=$(nova list|grep $VM|perl -lane 'print $1 if (/floating=(.*?)[;|\s]/)')
   echo $ip
}

function init_vm() {

   ip=$(get_vm_ip)

   run_cmd_jr="ssh -q -l ubuntu $ip -i $key"
   run_cmd_rt="ssh -q -l root $ip -i $key"

   $run_cmd_jr "sudo sed -n 's/^.*ssh-rsa/ssh-rsa/p' /root/.ssh/authorized_keys > /tmp/authorized_keys"  &> /dev/null
   $run_cmd_jr "sudo mv /tmp/authorized_keys /root/.ssh/"  &> /dev/null
   $run_cmd_jr "sudo chmod 600 /root/.ssh/authorized_keys"  &> /dev/null
   $run_cmd_jr "sudo chown root:root /root/.ssh/authorized_keys"  &> /dev/null

   # sudo isn't happy with out this.
   $run_cmd_rt "echo '127.0.0.1 $VM' >> /etc/hosts"

   maas_private_ip=$(nova list|egrep $VM |perl -lane 'print $1 if (/smnet1=(.*?)[\s|\;]/)')
   cat << EOF > /tmp/eth1

auto eth1
iface eth1 inet static
    address $maas_private_ip
    netmask 255.255.255.0
EOF

   # Ubuntu LTS 14.04 doesn't automatically start a second interface. 
   # We want it to be static, so we can run a dhcp server on eth1 for 
   # all our computes.
   scp -q -i $key /tmp/eth3 root@$ip:/root/
   $run_cmd_rt "cat /root/eth1 >> /etc/network/interfaces" &> /dev/null
   $run_cmd_rt 'ifup eth1'  &> /dev/null
   echo "Ok"

   echo -n "Installing MAAS Controller: "
   $run_cmd_rt 'apt-get install python-software-properties' &> /dev/null
   $run_cmd_rt 'add-apt-repository ppa:juju/stable' &> /dev/null
   $run_cmd_rt 'add-apt-repository ppa:maas/stable' &> /dev/null
   $run_cmd_rt 'add-apt-repository ppa:cloud-installer/stable' &> /dev/null
   $run_cmd_rt 'apt-get update' &> /dev/null
   $run_cmd_rt 'apt-get -y install maas' &> /dev/null
   echo "Ok"
}

function wait_for_running() {

   sleep 15
   ip=$(get_vm_ip)
   echo -n "Waiting for $VM ($ip): "

   ssh -q -l ubuntu -i $key $ip 'date &> /dev/null'
   while test $? -gt 0; do
      sleep 5
      ssh -q -l ubuntu -i $key $ip 'date &> /dev/null'
   done
   echo "Ok"
}


# clean_up

function start_up() {

   #verify_creds
   #create_sec_group
   #create_ssh_key
   #create_provider_network
   #create_tenant_networks
   #create_flavors
   #create_virtual_router
   boot_vm
   wait_for_running
   init_vm

   ip=$(get_vm_ip)
   echo "Configure MAAS here: http://$ip/MAAS/

}

function shutdown() {

   clean_up
}

# clean_up
start_up

