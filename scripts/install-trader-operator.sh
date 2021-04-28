#!/bin/bash
# Copyright [2018-2020] IBM Corp. All Rights Reserved.
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

# Install Trader Lite operator in all student namespaces


usage () {
  echo "Usage:"
  echo "install-trader-operator.sh CLUSTER_NAME API_KEY NAMESPACE"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi

#
# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh
source "$SCRIPT_PATH"/vars.sh

PROJECT=$3


echo "Installing TraderLite Operator ..."
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
status=$(oc get cm traderlite-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "setup_traderlite already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm traderlite-install-progress --from-literal=state=started -n default
fi

echo "Installing Trader Lite Operator in namespace $PROJECT ..."
echo ""

echo "Creating subscription to TraderLite operator ..."
echo "Check if TraderLite subscription exists ..."
oc get Subscription traderlite-operator -n $PROJECT  >/dev/null 2>&1

if [ $? -ne 0 ]; then

    operator-sdk run bundle $TRADERLITE_OPERATOR_BUNDLE -n $PROJECT --timeout 5m0s
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to TraderLite operator"
        exit 1
    fi

else
   echo "Subscription to traderlite-operator already exists, skipping create ..."
   echo "Check if  Operator is successfully Deployed - give up after 5 minutes"
   printf "Status: Querying CSV ..."
   retry 60 checkCSVComplete $TRADERLITE_CSV $PROJECT
   if [ $? -ne 0 ]; then
      echo "Error: timed out waiting for operators"
      exit 1
   fi
fi



# Update install progress
oc create cm traderlite-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not update traderlite-install-progress config map in project default"
   exit 1
else
   echo "TraderLite Operator successfully installed"
   exit 0
fi
