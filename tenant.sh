#!/usr/bin/bash
# Create a keystone tenant and matching swift user in radosgw
#
# Joey <joey.mcdonald@nokia.com>


RADOS_PORT=$(hiera radosgw::public_port 2>/dev/null)
EXT_ADDR=$(hiera VIP_RADOSGW 2>/dev/null)
EXTERNAL_URL="http://${EXT_ADDR}:${RADOS_PORT}/auth/v1.0"

function keystone_create_user() {

   keystone tenant-list 2> /dev/null | grep -q juju

   if [ $? != '0' ]; then
      echo -n "Creating keystone tenant juju-admin: "
      keystone tenant-create --name juju &> /dev/null
      keystone user-create --name juju-admin --tenant juju --pass nimda-ujuj --email nobody@cloud-band.com &> /dev/null

cat << EOF > ./juju.rc
export OS_USERNAME=juju-admin
export OS_TENANT_NAME=juju
export OS_PASSWORD=nimda-ujuj
export PS1='[\u@\h \W(keystone_admin)]\$ '
export OS_AUTH_URL=http://10.1.20.5:35357/v2.0
EOF

      echo "Ok"
   else
      echo "User juju-admin already exists."
   fi
}

function keystone_delete_user() {

      keystone tenant-list 2>/dev/null | grep -q juju
      if [ $? == 0 ]; then
         echo -n "Deleting keystone tenant juju-admin: "
         keystone user-delete juju-admin 2>/dev/null
         keystone tenant-delete juju  2>/dev/null
         echo "Ok"
      else
         echo "User juju-admin does not exist."
      fi
}

function swift_create_user() {

   echo -n "Creating swift juju-admin user: "
   radosgw-admin user create --uid=juju-admin --display-name="Juju Admin"  &> /dev/null
   radosgw-admin subuser create --uid=juju-admin --subuser=juju-admin:swift --access=full  &> /dev/null
   radosgw-admin key create --uid=juju-admin --subuser=juju-admin:swift --key-type=swift --gen-secret  &> /dev/null
   radosgw-admin subuser modify --uid=juju-admin --subuser=juju-admin:swift --access=full  &> /dev/null
   radosgw-admin subuser create --uid=juju-admin --subuser=juju-admin:s3 --access=full  &> /dev/null
   radosgw-admin key create --uid=juju-admin --subuser=juju-admin:s3 --key-type=s3 --gen-secret  &> /dev/null
   sleep 2
   echo "Ok"
}

function upload_to_bucket() {

   bucket=$1
   SWIFT_KEY=$(get_swift_key)
   echo -n "Creating bucket $bucket: "
   swift -A ${EXTERNAL_URL} -U juju-admin:swift -K "${SWIFT_KEY}" --verbose upload ${bucket} /root/anaconda-ks.cfg  &> /dev/null
   if [ $? != '0' ]; then
      echo "Failed"
   else
      echo "Ok"
   fi
   sleep 2
}

function check_bucket() {

   bucket=$1
   SWIFT_KEY=$(get_swift_key)
   echo -n "Checking bucket $bucket: "
   swift -A ${EXTERNAL_URL} -U juju-admin:swift -K "${SWIFT_KEY}" list ${bucket} |grep -q anaconda 
   if [ $? != '0' ]; then
      echo "Failed"
   else
      echo "Ok"
   fi
   sleep 2
}


function get_swift_key() {
   # extract swift user key
   echo $(radosgw-admin user info --uid=juju-admin --subuser=juju-admin:swift |\
     python -c \
     'import sys, json; print json.load(sys.stdin)["swift_keys"][0]["secret_key"]')
}   

function swift_delete_user() {

   echo -n "Deleting swift juju-admin user: "
   radosgw-admin user rm --uid=juju-admin --purge-data
   if [ $? != '0' ]; then
      echo "Failed"
   else
      echo "Ok"
   fi
   sleep 2
}



keystone_delete_user
keystone_create_user
swift_delete_user
swift_create_user
upload_to_bucket juju-bucket
check_bucket juju-bucket
echo "Swift Key:" $(get_swift_key)

