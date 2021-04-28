#!/bin/sh
#
# Umbrella script for installing CP4I 2020.4 for a CDA Workshop

usage () {
  echo "Usage:"
  echo "run.sh CLUSTER_NAME API_KEY ENTITLEMENT_REGISTRY_KEY FRODO_LOCAL_IMAGE"
}

if [ "$#" -ne 4 ]
then
    usage
    exit 1
fi


# Path where script lives
SCRIPT_PATH=$(dirname `realpath  $0`)
APIC_CLOUD_ADMIN_PWD=bhytY78gb
TRADER_NAMESPACE=student001

echo ""
echo "****Running Step 1: Pre install****"
echo ""
${SCRIPT_PATH}/pre-install.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "Pre install failed. Terminating"
  exit 1
fi

echo ""
echo "****Running Step 2: Install Common Services****"
echo ""
${SCRIPT_PATH}/install-cs.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "Common Services install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 3: Install Platform Navigator****"
echo ""
${SCRIPT_PATH}/install-pn.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "Platform Navigator install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 4: Install API Connect****"
echo ""
${SCRIPT_PATH}/install-apic.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "API Connect install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 5: Install App Connect****"
echo ""
${SCRIPT_PATH}/install-ace.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "App Connect install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 6: Install MQ****"
echo ""
${SCRIPT_PATH}/install-mq.sh $1 $2 $3
if [ $? -ne 0 ]; then
  echo "MQ install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 7: Install Strimzi****"
echo ""
${SCRIPT_PATH}/install-kafka.sh $1 $2
if [ $? -ne 0 ]; then
  echo "Kafka install failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 8: Set APIC Cloud Admin password****"
echo ""
${SCRIPT_PATH}/setup-apic-cloud-admin.sh $1 $2 $APIC_CLOUD_ADMIN_PWD
if [ $? -ne 0 ]; then
  echo "Set APIC Cloud Admin password failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 9: Setup APIC Org****"
echo ""
${SCRIPT_PATH}/setup-apic-orgs.sh $1 $2 $APIC_CLOUD_ADMIN_PWD
if [ $? -ne 0 ]; then
  echo "Setup APIC Org failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 10: Setup Kafka****"
echo ""
${SCRIPT_PATH}/setup-kafka.sh $1 $2 $TRADER_NAMESPACE
if [ $? -ne 0 ]; then
  echo "Setup Kafka failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 11: Install TraderLite Operator****"
echo ""
${SCRIPT_PATH}/install-trader-operator.sh $1 $2 $TRADER_NAMESPACE
if [ $? -ne 0 ]; then
  echo "Install TraderLite Operator failed. Terminating"
  exit 1
fi

sleep 3

echo ""
echo "****Running Step 12: Install Frodo Local****"
echo ""
${SCRIPT_PATH}/install-frodo-local.sh $1 $2 $4 $TRADER_NAMESPACE
if [ $? -ne 0 ]; then
  echo "Install Frodo Local  failed. Terminating"
  exit 1
else
  echo "****CP4I setup completed successfully****"
fi
