#!/bin/bash

RADOS_PORT=$(hiera radosgw::public_port 2>/dev/null)
EXT_ADDR=$(hiera VIP_RADOSGW 2>/dev/null)
EXTERNAL_URL="http://${EXT_ADDR}:${RADOS_PORT}/auth/v1.0"

function create_user_sub() {

   echo -n "Creating admin user: "
   radosgw-admin user create --uid=admin --display-name="Juju Admin" &>> /dev/null
   radosgw-admin subuser create --uid=admin --subuser=admin:swift --access=full &>> /dev/null
   radosgw-admin key create --uid=admin --subuser=admin:swift --key-type=swift --gen-secret &>> /dev/null
   radosgw-admin subuser modify  --uid=admin --subuser=admin:swift --access=full &>> /dev/null
   radosgw-admin subuser create --uid=admin --subuser=admin:s3 --access=full &>> /dev/null
   radosgw-admin key create --uid=admin --subuser=admin:s3 --key-type=s3 --gen-secret &>> /dev/null
   sleep 2
   echo "Ok"
}

function upload_to_bucket() {

   bucket=$1
   SWIFT_KEY=$(get_swift_key)

   echo -n "Creating bucket $bucket: "
   swift -A ${EXTERNAL_URL} -U admin:swift -K "${SWIFT_KEY}" --verbose upload ${bucket} /root/anaconda-ks.cfg &> /dev/null
   swift -A ${EXTERNAL_URL} -U admin:swift -K "${SWIFT_KEY}" --verbose post ${bucket} -w '.r:*' &> /dev/null
   echo "Ok"
   sleep 2
}

function check_bucket() {

   bucket=$1
   SWIFT_KEY=$(get_swift_key)
   echo -n "Checking bucket $bucket: "
   echo "swift -A ${EXTERNAL_URL} -U admin:swift -K "${SWIFT_KEY}" list ${bucket} |grep -q anaconda "
   if [ $? != '0' ]; then
      echo "Failed"
   else
      echo "Ok"
   fi
   sleep 2
}


function get_swift_key() {
   # extract swift user key
   echo $(radosgw-admin user info --uid=admin --subuser=admin:swift |\
     python -c \
     'import sys, json; print json.load(sys.stdin)["swift_keys"][0]["secret_key"]')
}   

function del_user() {

   echo -n "Deleting admin user: "
   radosgw-admin user rm --uid=admin --purge-data
   if [ $? != '0' ]; then
      echo "Failed"
   else
      echo "Ok"
   fi
   sleep 2
}

del_user
create_user_sub
echo $(get_swift_key)
upload_to_bucket juju-bucket
check_bucket juju-bucket
