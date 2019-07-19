#!/bin/bash
# Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file
# except in compliance with the License. A copy of the License is located at
# 
#     http://aws.amazon.com/apache2.0/
# 
# or in the "license" file accompanying this file. This file is distributed on an "AS IS"
# BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under the License.

## Documentation related to this script:
# https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html#UsingWithRDS.IAMDBAuth.Availability

## Functions ##
usage(){
    cat << EOF
Usage: 
./setupIAM-Postgres.sh <AWS CLI Profile [optional]>
EOF
}
securityDisclaimer(){
    # This function just lets the user know what will be done so he can cancel before doing anything if he wants.
    cat << EOF
This script helps setting up the IAM Policy and Role to allow RDS Postgres Authentication using IAM.

Versions supported:
RDS Postgresql 9.5.13 or higher
RDS Postgresql 9.6.9 or higher
RDS Postgresql 10.4 or higher
Aurora Postgresql 9.6.9 or higher
Aurora Postgresql 10.4 or higher

Security Disclaimer - Executing this script will:
    1. Query your account ID from AWS CLI.
    2. Create IAM Policy and attach to the desired IAM User.
    3. Download SSL certificate to this machine.
    4. Create parameter file on ${HOME}

EOF
    read -p "Do you wish to proceed Y/N? [N]: " DECISION; DECISION=${DECISION:-N}; echo $DECISION
    if [[ ${DECISION} == y ]] || [[ ${DECISION} == Y ]]; then echo "Proceeding..."; else exit 1; fi
}
getAccountID(){
    # This requires AWS CLI to be properly configured!
    ACC_ID="$(aws sts get-caller-identity --query "[Account]" --output text --profile ${PROFILE})"
    echo "Account ID: ${ACC_ID}"
    return 0
}
loadVariables() {
    read -p "Policy Name [IAMDBAuthPostgresPolicy]: " POLICY_NAME; POLICY_NAME=${POLICY_NAME:-IAMDBAuthPostgresPolicy}
    read -p "Region [us-east-1]: " REGION; REGION=${REGION:-us-east-1}
    read -p "DB Resource ID [*]: " DB_RES_ID; DB_RES_ID=${DB_RES_ID:-*}
    read -p "IAM User: " IAM_USER
    read -p "DB User: [${IAM_USER}] " DB_USER; if [[ -z $DB_USER ]]; then DB_USER=${IAM_USER}; fi
    return 0
}
createJSONPolicy() {
cat << EOF > rds-iam-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds-db:connect"
            ],
            "Resource": [
                "arn:aws:rds:${REGION}:${ACC_ID}:dbuser:${DB_RES_ID}/${DB_USER}"
            ]
        }
    ]
}
EOF
POLICY_ARN="arn:aws:iam::${ACC_ID}:policy/${POLICY_NAME}"
return 0
}
createIAMPolicy() {
    aws iam create-policy --policy-name ${POLICY_NAME} --policy-document file://rds-iam-policy.json --profile ${PROFILE}
    return 0
}
attachIAMPolicyToUser(){
    aws iam attach-user-policy --policy-arn ${POLICY_ARN} --user-name ${IAM_USER} --profile ${PROFILE}
    return 0
}
getSSLCertificate(){
    if [[ -f rds-combined-ca-bundle.pem ]] 
    then 
        return 0
    else 
        wget https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem -o /tmp/ssl.log
        if [[ $? > 0 ]]; then echo "Failed to download SSL Certificate" && exit 1; else return 0; fi
    fi
}
createParameterFile() {
if [[ -f ~/.pg_${IAM_USER} ]]; 
then 
    echo "Configuration file already exists, run the command below to use IAM authentication: " 
    echo ". ~/.pg_${IAM_USER}" 
    exit 0
else
    echo "Please provide database details to create the parameter file that will be used to generate the authentication token."
    read -p "Database Endpoint: " RDSHOST
    read -p "Database Port: [5432] " RDSPORT; RDSPORT=${RDSPORT:-5432}
    read -p "Database Name: " RDSDB
cat << EOF > ~/.pg_${IAM_USER} 
export RDSHOST="${RDSHOST}"
export RDSPORT="${RDSPORT}"
export RDSDB="${RDSDB}"
export REGION="${REGION}"
export DB_USER="${DB_USER}"
export CONN="psql \"host=$RDSHOST dbname=$RDSDB user=$DB_USER sslrootcert=rds-combined-ca-bundle.pem sslmode=verify-full\""
EOF
echo "export PGPASSWORD=\"\$(aws rds generate-db-auth-token --hostname \$RDSHOST --port \$RDSPORT --region \$REGION --username \$DB_USER)\"" >> ~/.pg_${IAM_USER}
echo "echo \$CONN" >> ~/.pg_${IAM_USER} 
fi
return 0
}
validateSettings(){
    if [[ -z $ACC_ID ]]; then echo "Failed to get Account ID, make sure your AWS CLI is properly configured." && exit 1; fi
    if [[ -z $IAM_USER ]]; then echo "No IAM user was entered. Rerun the script and enter the IAM User." && exit 1; fi
}

## Sets the profile to be used for CLI and displays usage if user types -h or --help
if [[ -z $1 ]]; then PROFILE="default"; else PROFILE=${1}; fi
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then usage && exit 0; fi

## MAIN Workflow ##
securityDisclaimer
getAccountID
loadVariables
createJSONPolicy
validateSettings
createIAMPolicy
attachIAMPolicyToUser
getSSLCertificate
createParameterFile
. ~/.pg_${IAM_USER} > /dev/null
if [[ -z $PGPASSWORD ]] 
then 
    echo "Environment configured, but token creation failed."
    echo "Try again later by running the command below:"
    echo ". ~/.pg_${IAM_USER}"
    exit 1
else
    echo ''
    echo "*** Environment configured successfully ***"
    echo ''
    echo "You may add the policy ${POLICY_NAME} to users and roles that will connect to the database/s."
    echo ''
    echo "Please connect with the master user to your database and execute the following commands: "
    echo "create user ${DB_USER} with login;"
    echo "grant rds_iam to ${DB_USER};"
    echo ''
    echo "You can connect to the database now with the following connection string: "
    echo "${CONN}"
    echo ''
    echo "You can generate tokens and get the connection string at any time by running: "
    echo ". ~/.pg_${IAM_USER}"
    exit 0
fi