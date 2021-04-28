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

usage () {
  echo "Usage:"
  echo "pre-install.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi


# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh

# Platform Navigator CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
PN_CRD_CREATED=0

echo "Authenticate with the cluster"
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

# Check if successfully run already and exit w/success if it has
status=$(oc get cm pre-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "pre-install already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm pre-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create pre-install-progress config map"
     exit 1
  fi
fi

echo "Add the IBM Common Services operators to the list of installable operators ..."
echo "Check if CatalogSource opencloud-operators exists ..."
oc get CatalogSource opencloud-operators -n openshift-marketplace  >/dev/null 2>&1
if [ $? -ne 0 ]; then
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: opencloud-operators
  namespace: openshift-marketplace
spec:
  displayName: IBMCS Operators
  publisher: IBM
  sourceType: grpc
  image: docker.io/ibmcom/ibm-common-service-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
    if [ $? -ne 0 ]; then
      echo "Fatal error: CatalogSource opencloud-operators install failed"
      exit 1
    fi
else
    echo "CatalogSource opencloud-operators already exists, skipping create ..."
fi

echo "Add the IBM operators to the list of installable operators ..."
echo "Check if CatalogSource ibm-operator-catalog exists ..."
oc get CatalogSource ibm-operator-catalog -n openshift-marketplace  >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-operator-catalog
  publisher: IBM Content
  sourceType: grpc
  image: docker.io/ibmcom/ibm-operator-catalog
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
  if [ $? -ne 0 ]; then
    echo "Fatal error: CatalogSource ibm-operator-catalog install failed"
    exit 1
  fi
else
   echo "CatalogSource ibm-operator-catalog already exists, skipping create ..."
fi



echo "Creating required projects ..."
projects="pn mq apic ace kafka student001"
for project in $projects
do
    echo "Check if $project project exists ..."
    oc project $project -q >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Creating $project project for CP4I ..."
        oc new-project $project

        if [ $? -ne 0 ]; then
           echo "Fatal error: Could not create $project project"
           exit 1
        fi
        if [ "$project" != "kafka" ] && [ "$project" != "student001" ]; then
          echo "Creating  IBM entitlement key secret in project $project ..."
          oc create secret docker-registry ibm-entitlement-key \
              --docker-username=cp \
              --docker-password="$3" \
              --docker-server=cp.icr.io \
              --namespace=$project

          if [ $? -ne 0 ]; then
             echo "Fatal error: Could not create IBM entitlement key in  project $project"
             exit 1
          fi
        fi

    else
        echo "$project project already exists, skipping create ..."

        if [ "$project" != "kafka" ] && [ "$project" != "student001" ]; then
          echo "Check if entitlement key exists ..."
          oc get secret ibm-entitlement-key -n $project >/dev/null 2>&1
          if [ $? -ne 0 ]; then
             echo "Entitlement key does not exist in  $project project, creating ..."
             echo "Creating  IBM entitlement key secret in project $project ..."
             oc create secret docker-registry ibm-entitlement-key \
                 --docker-username=cp \
                 --docker-password="$3" \
                 --docker-server=cp.icr.io \
                 --namespace=$project

             if [ $? -ne 0 ]; then
                echo "Fatal error: Could not create IBM entitlement key in  project $project"
                exit 1
             fi
          else
            echo "Entitlement key already exists in $project project, skipping create..."
          fi
        fi
    fi

done

# Update install progress
oc create cm pre-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create pre-install-progress config map in project default"
   exit 1
else
   echo "Pre install script ran successfully"
   exit 0
fi
