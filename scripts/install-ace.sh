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
checkDesignerAuthoringCRDComplete() {
   local -i numcomplete=0
   if [ $ACE_DESIGN_CRD_CREATED -eq 0 ]; then
       oc get DesignerAuthoring des-01-quickstart -n ace >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "ACE_DESIGN_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get DesignerAuthoring des-01-quickstart -n ace --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
   while IFS= read -r line
   do
     if [[ "$line" == "Ready=True" ]]; then
        let "numcomplete+=1"
     fi
   done <<< "$status"

   if [ $numcomplete -eq $1 ]; then
     printf "\nStatus: CRD is ready\n"
     return 0
   else
     printf "\rStatus: CRD is not ready - $2 attempts remaining"
     return 1
   fi
}

# This function issues the CRD status command and looks for output with 5 separate lines each ending with "=True"
# It returns 0 if it finds these 5 lines or 1 otherwise (output doesn't match or status command fails)
checkDashboardCRDComplete() {
   local -i numcomplete=0
   if [ $ACE_DASHBOARD_CRD_CREATED -eq 0 ]; then
       oc get Dashboard db-01-quickstart -n ace >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "ACE_DASHBOARD_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD object initializing ..."
           return 1
       fi
   fi

   local -r status=$(oc get Dashboard db-01-quickstart -n ace --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
   while IFS= read -r line
   do
     if [[ "$line" == "Ready=True" ]]; then
        let "numcomplete+=1"
     fi
   done <<< "$status"

   if [ $numcomplete -eq $1 ]; then
     printf "\nStatus: CRD is ready\n"
     return 0
   else
     printf "\rStatus: CRD is not ready"
     return 1
   fi
}


usage () {
  echo "Usage:"
  echo "install-ace.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY"
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
ACE_DESIGN_CRD_CREATED=0

# ACE DASHBOARD CRD created flag.
ACE_DASHBOARD_CRD_CREATED=0


echo "Installing App Connect ..."
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
status1=$(oc get cm ace-des-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)
status2=$(oc get cm ace-db-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status1" = "complete" ] && [ "$status2" = "complete" ]; then
  echo "ACE install already completed successfully, skipping ..."
  exit 0
elif [ "$status1" != "complete" ] && [ "$status1" != "started" ]; then
  oc create cm ace-des-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create ace-des-install-progress config map"
     exit 1
  fi
fi

if [ "$status1" != "complete" ]; then
    echo "Creating subscription to ACE operator ..."
    echo "Check if ACE subscription exists ..."
    oc get Subscription ibm-appconnect -n openshift-operators  >/dev/null 2>&1

    if [ $? -ne 0 ]; then

       cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-appconnect
  namespace: openshift-operators
spec:
  channel: v1.2
  installPlanApproval: Automatic
  name: ibm-appconnect
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF
        if [ $? -ne 0 ]; then
            echo "Error creating subscription to ACE operator"
            exit 1
        fi

        # Give CSVs a chance to appear
        echo "Wait 10 seconds to give CSVs a chance to appear"
        sleep 10

    else
       echo "Subscription to  ibm-appconnect already exists, skipping create ..."
       sleep 2
    fi
fi

sleep 2

# Check for the 2 resulting operators to be ready - give up after 10 minutes
echo "Check for Operators to successfully deploy - give up after 10 minutes"
echo "Status: Query Operators ..."
retry 60 checkCSVComplete $APPCONN_CSV openshift-operators
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi
retry 60 checkCSVComplete $APPCONN_COUCH_CSV openshift-operators

if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

sleep 2

if [ "$status1" != "complete" ]; then
    echo "Deploying App Connect DesignerAuthoring..."
    echo "Check if App Connect DesignerAuthoring exists  ..."
    oc get DesignerAuthoring des-01-quickstart -n ace  >/dev/null 2>&1
    if [ $? -ne 0 ]; then
       cat <<EOF | oc create -f -
apiVersion: appconnect.ibm.com/v1beta1
kind: DesignerAuthoring
metadata:
  name: des-01-quickstart
  namespace: ace
spec:
  license:
    accept: true
    license: L-APEH-BSVCHU
    use: CloudPakForIntegrationNonProduction
  couchdb:
    replicas: 1
    storage:
      class: 'ibmc-block-gold'
      size: 10Gi
      type: persistent-claim
  useCommonServices: true
  designerFlowsOperationMode: local
  version: 11.0.0
  replicas: 1
EOF

        if [ $? -ne 0 ]; then
            echo "Error deploying DesignerAuthoring"
            exit 1
        fi
    else
        echo "DesignerAuthoring deployment already exists, skipping  ..."
    fi

    sleep 2

    # Check for the resulting operator to be ready - give up after 15 minutes
    echo "Check for the resulting CRD to be ready - give up after 20 minutes"
    echo "Status: Query CRD ..."
    retry 240 checkDesignerAuthoringCRDComplete 1
    if [ $? -ne 0 ]; then
        echo "Error: timed out waiting for operators"
        exit 1
    else
        # Update install progress
        oc create cm ace-des-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
        if [ $? -ne 0 ]; then
           echo "Fatal error: Could not create ace-des-install-progress config map in project student001"
           exit 1
        else
           echo "DesignerAuthoring install completed successfully"
           sleep 2
        fi
    fi

fi


echo "Deploying App Connect Dashboard ..."
if [ "$status2" != "started" ]; then
  oc create cm ace-db-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create ace-db-install-progress config map"
     exit 1
  fi
fi
echo "Check if App Connect Dashboard exists ..."
oc get Dashboard db-01-quickstart -n ace  >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: appconnect.ibm.com/v1beta1
kind: Dashboard
metadata:
 name: db-01-quickstart
 namespace: ace
spec:
 license:
   accept: true
   license: L-APEH-BSVCHU
   use: CloudPakForIntegrationNonProduction
 pod:
   containers:
     content-server:
       resources:
         limits:
           cpu: 250m
     control-ui:
       resources:
         limits:
           cpu: 250m
           memory: 250Mi
 useCommonServices: true
 version: 11.0.0
 storage:
   class: 'ibmc-file-gold-gid'
   size: 5Gi
   type: persistent-claim
 replicas: 1

EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying Dashboard"
        exit 1
    fi
else
    echo "Dashboard deployment already exists, skipping  ..."
fi

sleep 2

# Check for the resulting operator to be ready - give up after 15 minutes
echo "Check for the resulting CRD to be ready - give up after 15 minutes"
printf "Status: Querying CRD ..."
retry 180 checkDashboardCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
fi

# Update install progress
oc create cm ace-db-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create ace-db-install-progress config map in project default"
   exit 1
else
   echo "Dashboard install completed successfully"
   exit 0
fi
