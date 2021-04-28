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
checkCommonServiceCRDComplete() {

   oc get CommonService common-service -n ibm-common-services >/dev/null 2>&1
   if [[ $? -ne 0 ]]; then
      echo "CommonService not ready yet"
      return 1
   else
     echo "CommonService ready !"
     return 0
   fi

}

usage () {
  echo "Usage:"
  echo "install-cs.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
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

# ACE DESIGNER CRD created flag.
COMMON_SERVICE_CRD_CREATED=0

echo "Installing Common Services ..."
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
status=$(oc get cm cs-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "cs already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm cs-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create cs-install-progress config map"
     exit 1
  fi
fi

echo "Creating subscription to Common Services operator ..."
echo "Check if Common Services subscription exists ..."
oc get Subscription ibm-common-service-operator -n openshift-operators  >/dev/null 2>&1

if [ $? -ne 0 ]; then

   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
 name: ibm-common-service-operator
 namespace: openshift-operators
spec:
 channel: stable-v1
 installPlanApproval: Automatic
 name: ibm-common-service-operator
 source: opencloud-operators
 sourceNamespace: openshift-marketplace
EOF
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to Common Services operator"
        exit 1
    fi

    # Give CSVs a chance to appear
    echo "Wait 10 seconds to give CSVs a chance to appear"
    sleep 10


else
   echo "Subscription to  ibm-common-service-operator already exists, skipping create ..."
   sleep 2
fi


echo "Check for dependent operators to come up. Wait 15 minutes "
printf "Querying CSVs ..."
retry 60 checkCSVComplete $CS_CSV ibm-common-services
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators in openshift-operators project"
   exit 1
fi
retry 60 checkCSVComplete $CS_ODLM_CSV ibm-common-services
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators in openshift-operators project"
   exit 1
fi
retry 60 checkCSVComplete $CS_NAMESPACE_CSV ibm-common-services
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators in openshift-operators project"
   exit 1
fi


echo "Wait for  CommonService to come up"
retry 60 checkCommonServiceCRDComplete

echo "Patching CommonService ..."
oc patch CommonService common-service --type merge  -p '{"spec":{"size":"small"}}' -n ibm-common-services
if [ $? -ne 0 ]; then
   echo "Error patching CommonService"
   exit 1
fi

# Update install progress
oc create cm cs-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create cs-install-progress config map in project default"
   exit 1
else
   echo "IBM Common Service successfully installed"
   exit 0
fi
