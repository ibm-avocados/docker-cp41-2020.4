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
   if [ $PN_CRD_CREATED -eq 0 ]; then
       oc get PlatformNavigator cp4i-navigator -n pn >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "PN_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get PlatformNavigator cp4i-navigator -n pn --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
   while IFS= read -r line
   do
     if [[ "$line" == "Ready=True" ]]; then
        let "numcomplete+=1"
     fi
   done <<< "$status"

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
  echo "install-pn.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
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

# Platform Navigator CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
PN_CRD_CREATED=0

echo "Installing Platform Navigator ..."
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
status=$(oc get cm pn-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "pn already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm pn-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create pn-install-progress config map"
     exit 1
  fi
fi

echo "Creating subscription to PN operator ..."
echo "Check if Platform Navigator subscription exists ..."
oc get Subscription ibm-integration-platform-navigator -n openshift-operators  >/dev/null 2>&1

if [ $? -ne 0 ]; then

   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-integration-platform-navigator
  namespace: openshift-operators
spec:
  channel: v4.1-eus
  installPlanApproval: Automatic
  name: ibm-integration-platform-navigator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to PN operator"
        exit 1
    fi

    # Give CSVs a chance to appear
    echo "Wait 10 sceonds to give CSVs a chance to appear"
    sleep 10
    # Check for the 2 resulting operators to be ready - give up after 5 minutes

else
   echo "Subscription to  ibm-integration-platform-navigator already exists, skipping create ..."
   sleep 2
fi

echo "Check for Operators to successfully deploy - give up after 5 minutes"
printf "Status: Querying CSV ..."
retry 60 checkCSVComplete $PN_CSV pn
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

echo "Deploying Platform Navigator ..."
echo "Check if Platform Navigator exists ..."
oc get PlatformNavigator cp4i-navigator -n pn  >/dev/null 2>&1
#echo "Pls delete this line in script !"
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: integration.ibm.com/v1beta1
kind: PlatformNavigator
metadata:
    name: cp4i-navigator
    namespace: pn
spec:
    license:
        accept: true
        license: L-RJON-BUVMQX
    mqDashboard: true
    replicas: 2
    version: 2020.4.1-eus
EOF


    if [ $? -ne 0 ]; then
        echo "Error deploying Platform Navigator"
        exit 1
    fi
else
    echo "Platform Navigator deployment already exists, skipping  ..."
fi

# Check for the resulting operator to be ready - give up after 40 minutes
echo "Check for the resulting CRD to be ready - give up after 40 minutes"
printf "Status: Querying CRD ..."
retry 480 checkCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
fi

# Update install progress
oc create cm pn-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create pn-install-progress config map in project default"
   exit 1
else
   echo "CP4I Platform Navigator completed successfully"
   exit 0
fi
