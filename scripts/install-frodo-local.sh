# This function issues the CRD status command and looks for output with separate lines equal to "Avaliable=True"
# It returns 0 if it finds this line or 1 otherwise (output doesn't match or status command fails)
checkDeploymentComplete() {
   local -i numcomplete=0

   if [ $WORKSHOP_INFO_DEPLOYMENT_CREATED -eq 0 ]; then
       oc get deployment workshop-info  -n $NAMESPACE >/dev/null 2>&1
       if [[ $? -eq 0 ]]; then
           let "WORKSHOP_INFO_DEPLOYMENT_CREATED +=1"
       else
           printf "\rStatus: DC is not ready - $2 attempts remaining"
           return 1
       fi
   fi

   local -r status=$( oc get deployment workshop-info  -n $NAMESPACE  --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
   while IFS= read -r line
   do
     if [[ "$line" == "Available=True" ]]; then
        let "numcomplete+=1"
     fi
   done <<< "$status"

   if [ $numcomplete -eq $1 ]; then
     printf "\nDC is ready\n"
     return 0
   else
     printf "\rStatus: DC is not ready - $2 attempts remaining"
     return 1
   fi
}



usage () {
  echo "Usage:"
  echo "install-frodo-local.sh CLUSTER_NAME API_KEY FRODO_LOCAL_IMAGE NAMESPACE"
}

if [ "$#" -ne 4 ]
then
    usage
    exit 1
fi

# Include utility functions
SCRIPT_PATH=$(dirname `realpath  $0`)
source "$SCRIPT_PATH"/utils.sh


WORKSHOP_INFO_DEPLOYMENT_CREATED=0
NAMESPACE=$4

echo "Setup Workshop Info app .."
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
status=$(oc get cm frodo-local-install-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "frodo-local-install already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm frodo-local-install-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create frodo-local-install-progress config map"
     exit 1
  fi
fi

echo "Deploying Frodo Local app ..."
echo "Check if Frodo Local Deployment  exists ..."
oc get deployment workshop-info -n student001 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    oc new-app $3 --name=workshop-info  -e "APP_CLUSTER_NAME=$1" -e "API_KEY=$2"  -n $NAMESPACE >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Error deploying Frodo Local"
        exit 1
    fi
else
    echo "Frodo Local deployment already exists, skipping  ..."
fi

# Check for the resulting deployment to be ready - give up after 5 minutes
echo "Check for the resulting Deployment to be ready - give up after 5 minutes"
printf "Status: Querying DC ..."
retry 60 checkDeploymentComplete 1
if [ $? -ne 0 ]; then
    echo "Error: timed out waiting for deployment"
    exit 1
else
    echo "Workshop Info all install completed successfully"
fi

echo "Creating route for workshop-info service ..."
oc expose service workshop-info -l app=workshop-info -n $NAMESPACE
if [ $? -ne 0 ]; then
    echo "Error: creating route for workshop-info service"
    exit 1
fi

# Update install progress
oc create cm frodo-local-install-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create frodo-local-install-progress config map in project default"
   exit 1
else
   echo "Workshop Info app successfully installed"
   exit 0
fi
