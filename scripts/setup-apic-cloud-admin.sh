
usage () {
  echo "Usage:"
  echo "setup-apic-cloud-admin.sh CLUSTER_NAME API_KEY CLOUD_ADMIN_PWD"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi

# Path where script lives
SCRIPT_PATH=$(dirname `realpath  $0`)


echo "Set APIC Cloud Admin pwd..."
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
status=$(oc get cm cloudadmin-setup-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "setup_apic_cloudadmin already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm cloudadmin-setup-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create cloudadmin-setup-progress config map"
     exit 1
  fi
fi

oc project apic

KUBECONFIG="$HOME/.kube/config"
#export APICOPS_K8SCLIENT=oc

#apicops organisations:list -n apic

echo "Setting Cloud Admin password ..."
"$SCRIPT_PATH"/apic.exp "$KUBECONFIG" $3
if [ $? -ne 0 ]; then
    echo "Error: setting Cloud Admin password"
    exit 1
fi

# Update install progress
oc create cm cloudadmin-setup-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create cloudadmin-setup-progress config map in project default"
   exit 1
else
   echo "Cloud Admin password set"
   exit 0
fi
