function create_pxe_image() {

   echo -n "Checking for ipxe image: "

   nova image-list |grep -q os-pxe
   if [ $? != 0 ]; then 
      echo -n "Installing... "
      dd if=/dev/zero of=pxeboot.img bs=1M count=4 &> /dev/null
      mkdosfs pxeboot.img &> /dev/null

      rm -rf /mnt/ipxe/
      mkdir -p /mnt/ipxe/cdrom/
      mkdir -p /mnt/ipxe/syslinux/

      # This is what we are modifying
      losetup /dev/loop0 pxeboot.img &> /dev/null
      mount /dev/loop0 /mnt/ipxe/cdrom/ &> /dev/null
      syslinux --install /dev/loop0 &> /dev/null

      # This stuff is read-only.
      wget -q http://boot.ipxe.org/ipxe.iso
      mount -o loop ipxe.iso /mnt/ipxe/syslinux/ &> /dev/null
      cp /mnt/ipxe/syslinux/ipxe.krn /mnt/ipxe/cdrom/
      cat > /mnt/ipxe/cdrom/syslinux.cfg <<EOF
DEFAULT ipxe
LABEL ipxe
 KERNEL ipxe.krn
EOF

      umount /mnt/ipxe/cdrom/ &> /dev/null
      umount /mnt/ipxe/syslinux/ &> /dev/null
      glance image-create --name os-pxe --is-public true  --disk-format raw --container-format bare < pxeboot.img &> /dev/null
      if [ $? == 0 ]; then
         rm -f ipxe.iso pxeboot.img
         echo "Ok"
      else
         echo "Failed."
      fi
   else
      echo "Ok"
   fi
}

function boot_computes() {

   echo -n "Checking for compute instances: "

   nova list --all-tenants | grep -q compute

   if [ $? != '0' ]; then
      echo "Booting Computes"

      for i in {1..5}; do
      
         nova boot --image $(nova image-list | grep os-pxe | awk '{print $2}') --flavor m1.large \
          --nic net-id=$(neutron net-list | grep floating | awk '{print $2}')  \
          --nic net-id=$(neutron net-list | grep smnet1 | awk '{print $2}')  \
          --security_groups smssh compute-0-$i

      done

   else
      echo "Ok" 
   fi
}

create_pxe_image
boot_computes
