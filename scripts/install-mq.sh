#!/bin/sh
# Copyright [2018] IBM Corp. All Rights Reserved.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# This function issues the CRD status command and looks for output with 5 separate lines each ending with "=True"
# It returns 0 if it finds these 5 lines or 1 otherwise (output doesn't match or status command fails)
checkCRDComplete() {
   local -i numcomplete=0
   if [ $MQ_CRD_CREATED -eq 0 ]; then
       oc get QueueManager quickstart-cp4i -n mq >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "MQ_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get QueueManager quickstart-cp4i -n mq --template='{{ .status.phase}}')

   if [ "$status" = "Running" ]; then
      let "numcomplete+=1"
   fi

   if [ $numcomplete -eq $1 ]; then
     printf "\nCRD is ready\n"
     return 0
   else
     printf "\rStatus: CRD is not ready - $2 attempts remaining"
     return 1
   fi


}

usage () {
  echo "Usage:"
  echo "install-mq.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi


# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh
source "$SCRIPT_PATH"/vars.sh

# MQ CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
MQ_CRD_CREATED=0

echo "Installing MQ ..."
echo ""
oc project >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Need to authenticate again:"
  echo "Authenticating with the cluster"
  ibmcloud login --apikey $2 -r us-south
  if [[ $? -ne 0 ]]; then
     echo "Fatal error: login via ibmcloud cli"
     exit 1
  fi

  sleep 2

  ibmcloud oc cluster config  --cluster $1 --admin
  if [[ $? -ne 0 ]]; then
     echo "Fatal error: cannot setup cluster access via ibmcloud cli config command"
     exit 1
  fi
else
  echo "Still authenticated. Skipping authentication ..."
fi

# Check if successfully run already and exit w/success if it has
status=$(oc get cm mq-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "mq already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm mq-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create mq-install-progress config map"
     exit 1
  fi
fi


echo "Creating subscription to MQ operator ..."
echo "Check if MQ subscription exists ..."
oc get Subscription ibm-mq -n openshift-operators  >/dev/null 2>&1

if [ $? -ne 0 ]; then

   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mq
  namespace: openshift-operators
spec:
  channel: v1.4
  installPlanApproval: Automatic
  name: ibm-mq
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to MQ operator"
        exit 1
    fi

    # Give CSVs a chance to appear
    echo "Wait 10 seconds to give CSVs a chance to appear"
    sleep 10

else
   echo "Subscription to  ibm-mq already exists, skipping create create ..."
   sleep 2
fi

# Check for the 2 resulting operators to be ready - give up after 5 minutes
echo "Check for Operators to successfully deploy - give up after 5 minutes"
printf "Querying CSVs ..."
retry 60 checkCSVComplete $MQ_CSV mq
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

sleep 2

echo "Deploying MQ Qmgr ConfigMap ..."
echo "Check if ConfigMap exists ..."
oc get cm qmtrader-mqsc -n mq  >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
 apiVersion: v1
 kind: ConfigMap
 metadata:
   name: qmtrader-mqsc
   namespace: mq
 data:
     mqsc: |-
      DEFINE QLOCAL(TRADER.QUEUE) REPLACE
      DEFINE CHANNEL(TRADER.TO.MQ) CHLTYPE(SVRCONN) TRPTYPE(TCP)
      ALTER QMGR CHLAUTH (DISABLED)
      ALTER AUTHINFO(SYSTEM.DEFAULT.AUTHINFO.IDPWOS) AUTHTYPE(IDPWOS) CHCKCLNT(NONE)
      REFRESH SECURITY TYPE(CONNAUTH)
EOF
else
  echo "MQ Qmgr ConfigMap already exists, skipping create  ..."
fi

sleep 2

echo "Deploying IBM MQ..."
echo "Check if IBM MQ exists ..."
oc get QueueManager quickstart-cp4i -n mq  >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: mq.ibm.com/v1beta1
kind: QueueManager
metadata:
  name: quickstart-cp4i
  namespace: mq
spec:
  license:
    accept: true
    license: L-RJON-BUVMQX
    use: NonProduction
  web:
    enabled: true
  version: 9.2.1.0-r1
  template:
    pod:
      containers:
        - env:
            - name: MQSNOAUT
              value: 'yes'
          name: qmgr
  queueManager:
    name: QMTRADER
    resources:
      limits:
        cpu: "1"
        memory: 1Gi
      requests:
        cpu: 300m
        memory: 500Mi

    storage:
      queueManager:
        type: ephemeral

    mqsc:
      - configMap:
          name: qmtrader-mqsc
          items:
            - mqsc
EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying MQ"
        exit 1
    fi
else
    echo "MQ deployment already exists, skipping create  ..."
fi

sleep 2

# Check for the resulting operator to be ready - give up after 30 minutes
echo "Check for the resulting CRD to be ready - give up after 5 minutes"
printf "Querying CRD ..."
retry 60 checkCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
fi

# Update install progress
oc create cm mq-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create mq-install-progress config map in project default"
   exit 1
else
   echo "MQ install ran successfully"
   exit 0
fi
