
usage () {
  echo "Usage:"
  echo "setup-apic-orgs.sh CLUSTER_NAME API_KEY CLOUD_ADMIN_PWD"
}

if [ "$#" -ne 3 ]
then
    usage
    exit 1
fi

# Path where script lives
SCRIPT_PATH=$(dirname `realpath  $0`)


echo "Setup APIC orgs..."
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
status=$(oc get cm org-setup-progress -n default -o "jsonpath={ .data['state']}" 2>/dev/null)

if [ "$status" = "complete" ]; then
  echo "setup_apic_org already completed successfully, skipping ..."
  exit 0
elif [ "$status" != "started" ]; then
  oc create cm org-setup-progress --from-literal=state=started -n default
  if [ $? -ne 0 ]; then
     echo "Fatal error: Could not create org-setup-progress config map"
     exit 1
  fi
fi

APIC_ADMIN_SERVER=$(oc get route apicmin-mgmt-admin --template '{{ .spec.host }}'  -n apic)

echo "Logging in to the Cloud Admin realm ..."
yes | apic-slim login --server ${APIC_ADMIN_SERVER} --username admin --password $3 --realm admin/default-idp-1 --accept-license
if [ $? -ne 0 ]; then
    echo "Error: Logging in to the Cloud Admin realm"
    exit 1
else
   echo "Successfully logged in to the Cloud Admin realm"
fi

sleep 2

#echo "Creating user in APIC Local User Registry ..."
# user_file="$SCRIPT_PATH"/apic/student-user.txt
# org_file="$SCRIPT_PATH"/apic/student-org.txt
org_file="$SCRIPT_PATH"/apic/admin-org.txt
#cmd_output=$(apic-slim users:create --server ${APIC_ADMIN_SERVER} --org admin --user-registry api-manager-lur ${user_file})
#URL=$(echo ${cmd_output} | tr -s ' ' | cut -d ' ' -f 4)
URL=$(apic-slim users:get --server ${APIC_ADMIN_SERVER} --org admin --user-registry common-services --fields url --output - admin | grep -v 'url:')
echo "Owner URL: ${URL}"
cat ${org_file} > "$SCRIPT_PATH"/apic/temp-org.txt
echo "owner_url: ${URL}" >> "$SCRIPT_PATH"/apic/temp-org.txt

echo "Creating new provider org ..."
apic-slim orgs:create --server ${APIC_ADMIN_SERVER} "$SCRIPT_PATH"/apic/temp-org.txt
if [ $? -ne 0 ]; then
    echo "Error: Creating new provider org"
    exit 1
else
   echo "Successfully created new provider org"
fi

sleep 2

# Cleanup
rm "$SCRIPT_PATH"/apic/temp-org.txt >/dev/null 2>&1
apic logout --server ${APIC_ADMIN_SERVER} >/dev/null 2>&1

# Update install progress
oc create cm org-setup-progress --from-literal=state=complete -n default --dry-run=client -o yaml | oc apply -f -
if [ $? -ne 0 ]; then
   echo "Fatal error: Could not create org-setup-progress config map in project default"
   exit 1
else
   echo "APIC Org setup ran successfully"
   exit 0
fi
