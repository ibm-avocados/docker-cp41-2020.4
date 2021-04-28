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
   if [ $KAFKA_CRD_CREATED -eq 0 ]; then
       oc get  Kafka my-kafka-cluster  -n kafka >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "APIC_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get Kafka my-kafka-cluster -n kafka --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
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
  echo "install-kafka.sh CLUSTER_NAME API_KEY"
}

if [ "$#" -ne 2 ]
then
    usage
    exit 1
fi


# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh
source "$SCRIPT_PATH"/vars.sh

# kafka CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
KAFKA_CRD_CREATED=0

echo "Installing Strimzi ..."
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
status=$(oc get cm kafka-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "kafka already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm kafka-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create kafka-install-progress config map"
     exit 1
  fi
fi

echo "Creating subscription to Kafka operator ..."
echo "Check if Kafka subscription exists ..."
oc get Subscription strimzi-kafka-operator -n openshift-operators  >/dev/null 2>&1

if [ $? -ne 0 ]; then

   cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: strimzi-kafka-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: strimzi-kafka-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
    if [ $? -ne 0 ]; then
        echo "Error creating subscription to Kafka operator"
        exit 1
    fi

    # Give CSVs a chance to appear
    echo "Wait 10 seconds to give CSVs a chance to appear"
    sleep 10

else
   echo "Subscription to strimzi-kafka-operator already exists, skipping create ..."
   sleep 2
fi

# Check for the 2 resulting operators to be ready - give up after 5 minutes
echo "Check for Operators to successfully deploy - give up after 5 minutes"
printf "Status: Querying CSV ..."
retry 60 checkCSVComplete $KAFKA_CSV kafka
if [ $? -ne 0 ]; then
   echo "Error: timed out waiting for operators"
   exit 1
fi

echo "Deploying Kafka ..."
echo "Check if Kafka exists ..."
oc get Kafka my-kafka-cluster -n kafka >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
 apiVersion: kafka.strimzi.io/v1beta1
 kind: Kafka
 metadata:
   name: my-kafka-cluster
   namespace: kafka
 spec:
   kafka:
     config:
       offsets.topic.replication.factor: 3
       transaction.state.log.replication.factor: 3
       transaction.state.log.min.isr: 2
       log.message.format.version: '2.7'
       inter.broker.protocol.version: '2.7'
     version: 2.7.0
     storage:
       type: ephemeral
     replicas: 3
     listeners:
       - name: plain
         port: 9092
         type: internal
         tls: false
       - name: tls
         port: 9093
         type: internal
         tls: true
   entityOperator:
     topicOperator: {}
     userOperator: {}
   zookeeper:
     storage:
       type: ephemeral
     replicas: 3

EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying Kafka"
        exit 1
    fi
else
    echo "Kafka deployment already exists, skipping  ..."
fi

# Check for the resulting operator to be ready - give up after 10 minutes
echo "Check for the resulting CRD to be ready - give up after 10 minutes"
printf "Status: Querying CRD ..."
retry 120 checkCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
fi

# Update install progress
oc create cm kafka-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create kafka-install-progress config map in project default"
   exit 1
else
   echo "Kafka install completed successfully"
   exit 0
fi
