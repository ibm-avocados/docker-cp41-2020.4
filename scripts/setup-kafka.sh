# This function issues the CRD status command and looks for output with 5 separate lines each ending with "=True"
# It returns 0 if it finds these 5 lines or 1 otherwise (output doesn't match or status command fails)
checkTopicCRDComplete() {
   local -i numcomplete=0
   if [ $TOPIC_CRD_CREATED -eq 0 ]; then
       oc get  KafkaTopic trader001  -n kafka >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "TOPIC_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get  KafkaTopic trader001  -n kafka --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
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

checkBuild() {
   local -i numcomplete=0
   status=$(oc get  Build  my-connect-cluster-connect-$2  -n $TRADER_NAMESPACE --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
   while IFS= read -r line
   do
     if [ "$line" = "Complete=True" ]; then
        let "numcomplete+=1"
     fi
   done <<< "$status"
   if [ $numcomplete -eq $1 ]; then
     printf "\n Build successful \n"
     return 0
   else
     printf "\rStatus: $numcomplete of $1 Builds done - $3 attempts remaining"
     return 1
   fi

}

checkConnectS2ICRDComplete() {
   local -i numcomplete=0
   if [ $S2I_CRD_CREATED -eq 0 ]; then
       oc get KafkaConnectS2I my-connect-cluster  -n $TRADER_NAMESPACE >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "S2I_CRD_CREATED+=1"
       else
           printf "\rStatus: CRD is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$(oc get KafkaConnectS2I my-connect-cluster  -n $TRADER_NAMESPACE --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
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

checkConnectorBuilt() {
  local -i numcomplete=0
  oc describe kafkaconnects2i my-connect-cluster -n $TRADER_NAMESPACE | grep $2 > /dev/null 2>&1
  if [[ $? -eq 0 ]]; then
     let "numcomplete+=1"
  fi


  if [ $numcomplete -eq $1 ]; then
    printf "\nConnector $2 is ready\n"
    return 0
  else
    printf "\rStatus: Connector $2 is not ready - $3 attempts remaining"
    return 1
  fi
}



usage () {
  echo "Usage:"
  echo "setup-kafka.sh CLUSTER_NAME API_KEY TRADER_NAMESPACE"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi

# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh
TRADER_NAMESPACE=$3

# kafka CRD created flag. This CRD needs common services to install first
# So querying for it while CS is still being installed will return an error
TOPIC_CRD_CREATED=0
S2I_CRD_CREATED=0

echo "Setup Kafka..."
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
status=$(oc get cm kafka-setup-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "kafka already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm kafka-setup-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create kafka-setup-progress config map"
     exit 1
  fi
fi

echo "Deploying KafkaTopic ..."
echo "Check if KafkaTopic exists ..."
oc get KafkaTopic trader001 -n kafka >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: trader001
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka-cluster
  namespace: kafka
spec:
  partitions: 1
  replicas: 1
EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying KafkaTopic"
        exit 1
    fi
else
    echo "KafkaTopic deployment already exists, skipping  ..."
fi

# Check for the resulting operator to be ready - give up after 10 minutes
echo "Check for the resulting CRD to be ready - give up after 10 minutes"
printf "Status: Querying CRD ..."
retry 120 checkTopicCRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
else
    echo "KafkaTopic install completed successfully"
fi

echo "Deploying KafkaConnectS2I ..."
echo "Check if KafkaConnectS2I exists ..."
oc get KafkaConnectS2I my-connect-cluster -n $TRADER_NAMESPACE >/dev/null 2>&1
if [ $? -ne 0 ]; then
   cat <<EOF | oc create -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnectS2I
metadata:
  name: my-connect-cluster
  namespace: $TRADER_NAMESPACE

 #  # use-connector-resources configures this KafkaConnect
 #  # to use KafkaConnector resources to avoid
 #  # needing to call the Connect REST API directly
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 2.7.0
  replicas: 1
  bootstrapServers: my-kafka-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092

  config:
    group.id: connect-cluster
    offset.storage.topic: connect-cluster-offsets
    config.storage.topic: connect-cluster-configs
    status.storage.topic: connect-cluster-status
    config.storage.replication.factor: 1
    offset.storage.replication.factor: 1
    status.storage.replication.factor: 1

EOF

    if [ $? -ne 0 ]; then
        echo "Error deploying KafkaConnectS2I"
        exit 1
    fi
    sleep 5
else
    echo "KafkaConnectS2I deployment already exists, skipping  ..."
fi


# Check for the resulting operator to be ready - give up after 10 minutes
echo "Check for the resulting CRD to be ready - give up after 10 minutes"
printf "Status: Querying CRD ..."
retry 120 checkConnectS2ICRDComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for operators"
    exit 1
else
    echo "KafkaConnectS2I install completed successfully"
fi

echo "Building and Deploying KafkaConnect image ..."
#oc start-build my-connect-cluster-connect --from-dir ./my-plugins
echo "Wait 10 seconds before kicking off build"
sleep 10

oc start-build my-connect-cluster-connect --from-dir ./kafka-connect-plugins -n $TRADER_NAMESPACE
if [ $? -ne 0 ]; then
    echo "Error: starting build of Kafka Connector"
    exit 1
fi
echo "Check for Build to be complete - give up after 10 minutes"
printf "Status: Querying Build ..."
retry 120 checkBuild 1 2
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for Kafka Connect Build"
    exit 1
else
    echo "Kafka Connect Build completed successfully"
fi

echo "Check for MQ connector to be ready - give up after 10 minutes"
printf "Status: Querying KafkaConnect ..."
retry 120 checkConnectorBuilt 1 MQSourceConnector
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for MQSourceConnector"
    exit 1
else
    echo "MQSourceConnector install completed successfully"
fi

echo "Check for Mongo connector to be ready - give up after 10 minutes"
printf "Status: Querying KafkaConnect ..."
retry 120 checkConnectorBuilt 1 MongoSinkConnector
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for MongoSinkConnector"
    exit 1
else
    echo "MongoSinkConnector install completed successfully"
fi

# Update install progress
oc create cm kafka-setup-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create kafka-install-progress config map in project default"
   exit 1
else
   echo "Kafka setup ran successfully"
   exit 0
fi
