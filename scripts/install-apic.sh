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
   if [ $APIC_CRD_CREATED -eq 0 ]; then
       oc get APIConnectCluster apicmin -n apic >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "APIC_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get APIConnectCluster apicmin -n apic --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
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
  echo "install-apic.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
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

# APIC CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
APIC_CRD_CREATED=0

echo "Installing API Connect ..."
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
status=$(oc get cm apic-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "apic already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm apic-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create apic-install-progress config map"
     exit 1
  fi
fi

echo "Creating subscription to APIC operator ..."
echo "Check if APIC subscription exists ..."
oc get Subscription ibm-apiconnect -n openshift-operators  >/dev/null 2>&1

if [ $? -ne 0 ]; then

   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-apiconnect
  namespace: openshift-operators
spec:
  channel: v2.1-eus
  installPlanApproval: Automatic
  name: ibm-apiconnect
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to APIC operator"
        exit 1
    fi

    # Give CSVs a chance to appear
    echo "Wait 10 seconds to give CSVs a chance to appear"
    sleep 10

else
   echo "Subscription to  ibm-apiconnect already exists, skipping create ..."
   sleep 2
fi

echo "Check for Operators to successfully deploy - give up after 10 minutes"
printf "Querying CSVs ..."
retry 60 checkCSVComplete $APIC_CSV apic
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

sleep 2

retry 60 checkCSVComplete $APIC_DP_CSV apic
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

sleep 2

echo "Deploying IBM API Connect ..."
echo "Check if API Connect exists ..."
oc get APIConnectCluster apicmin -n apic  >/dev/null 2>&1
if [ $? -ne 0 ]; then
   retries=0
   while [ $retries -le 2 ]
   do
     nap=$(((retries+1)*10))
     sleep $nap
     cat <<EOF | oc create -f -
apiVersion: apiconnect.ibm.com/v1beta1
kind: APIConnectCluster
metadata:
 namespace: apic
 name: apicmin

spec:
 license:
   accept: true
   use: nonproduction
 storageClassName: ibmc-block-gold
 profile: n3xc4.m16
 version: 10.0.1.2-ifix2-eus

EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying API Connect - retrying"
        ((++retries))
        continue
    else
      break
    fi
  done
  if [ $retries -gt 2 ]; then
      echo "Error deploying API Connect"
      exit 1
  fi
else
    echo "API Connect deployment already exists, skipping  ..."
fi

sleep 5

# Check for the resulting operator to be ready - give up after 60 minutes
echo "Check for the resulting CRD to be ready - give up after 60 minutes"
printf "Querying CRD ..."
retry 720 checkCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
fi

# Update install progress
oc create cm apic-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create apic-install-progress config map in project default"
   exit 1
else
   echo "API Connect install completed successfully"
   exit 0
fi
