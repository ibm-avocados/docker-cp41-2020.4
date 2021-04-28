# Retries a command on failure.
# $1 - the max number of attempts
# $2... - the command to run
retry() {
    local -r -i max_attempts="$1"; shift
    local -r cmd="$@"
    local -i attempt_num=1
    local -i remaining=$(( max_attempts - 1 ))
    let "remaining=max_attempts-1"

    until $cmd $remaining
    do
        if (( attempt_num == max_attempts ))
        then
            printf "\nAttempt $attempt_num failed and there are no more attempts left!\n"
            return 1
        else
            #echo "Attempt $attempt_num failed! Trying again in 5 seconds..."
            (( attempt_num++ ))
            let "remaining-=1"
            sleep 5
        fi
    done

}

checkCSVComplete() {

   status=$(oc get csv $1 -o=custom-columns=":status.phase" --no-headers -n $2 2>/dev/null)
   if [ "$status" = "Succeeded" ]; then
     printf "\n $1 CSV up\n"
     return 0
   else
    printf "\rStatus: $1 CSV not up - $3 attempts remaining"
    return 1
   fi

}

checkCatalogSourceComplete() {
   status=$(oc get CatalogSource $1 -n openshift-marketplace --template='{{ .status.connectionState.lastObservedState }}')
   if [ "$status" = "READY" ]; then
     printf "\n CatalogSource $1 ready \n"
     return 0
   else
     printf "\rStatus: $1 not up - $2 attempts remaining"
     return 1
   fi

}
