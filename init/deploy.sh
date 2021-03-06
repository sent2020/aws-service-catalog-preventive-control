#!/bin/bash

# /*
# * Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# *
# * Permission is hereby granted, free of charge, to any person obtaining a copy of this
# * software and associated documentation files (the "Software"), to deal in the Software
# * without restriction, including without limitation the rights to use, copy, modify,
# * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# * permit persons to whom the Software is furnished to do so.
# *
# * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# */

#Initial Deployment Configuration Section
resources_cfn_stack_name="sc-product-resources"
lambda_functions_cfn_stack_name="sc-lambda-functions"
deployment_lambda_function_name="sc-product-deployment"
deployment_lambda_role_name="sc-product-deployment-lambda-role"
# Enter the name you want to use for Amazon S3 deployment bucket
deployment_s3_bucket_name=""

product_selector_lambda_role_name="sc-product-selector-lambda-role"
resource_selector_lambda_role_name="sc-resource-selector-lambda-role"
resource_compliance_lambda_role_name="sc-resource-compliance-lambda-role"
pipeline_role_name="sc-product-update-codepipeline-role"
sc_product_policy_name="service-catalog-product-policy"
sc_portfolio_description="Security Product Allow Deploy by Developers"
sc_portfolio_name="security-products"
account_access_role_name=""
account_access_user_name=""
deployer_config_file_suffix="deployer"
aws_cli_profile="default"
# To add bucket policy allows all accounts in organization get object from deployment bucket
# update below line with correct aws organization id
# alternatively uncomment line 64 to get organization id using CLI command
aws_organization_id=""


# check if the name of deployment S3 bucket provided in script argument
if [[ $1 != '' ]]
then
  deployment_s3_bucket_name=$1
fi

if [[ $2 != '' ]]
then
  aws_cli_profile=$2
fi

if [[ $deployment_s3_bucket_name = '' ]]
then
  echo "Usage: deploy.sh <S3 Deployment Bucket Name"
  exit 1
fi

printf "\nDeploying using CLI profile: $aws_cli_profile\n\n"

# Get organization id
aws_organization_id=$(aws organizations describe-organization --query 'Organization.[Id]' --profile $aws_cli_profile --output text)

#List of products to deploy
products_to_deploy=(sqs kinesis sns elasticsearch elasticache ebs efs dmsinstance dmsendpoint autoscaling alb albtarget alblistener fsx dynamodb sagemaker s3 kms mq governance-lambdas governance-lambda-roles)

printf "Copy Deployment Files\n"
mkdir ../products-config
cp -f ../templates/deployment/*.deployer ../products-config/

printf "Creating Deployment S3 Bucket\n"
aws cloudformation create-stack --stack-name $resources_cfn_stack_name-s3-bucket \
--profile $aws_cli_profile \
--template-body file://service-catalog-s3-deployment-bucket-cfn.yml  \
--tags Key=SC:Automation,Value=sc-deployment-bucket \
--parameters ParameterKey=BucketName,ParameterValue=$deployment_s3_bucket_name \
ParameterKey=OrganizationId,ParameterValue=$aws_organization_id 

#Check if CloudFormation launch success
if [ $? -ne 0 ]
then
  printf "CFN S3 Bucket Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF S3 Bucket Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name-s3-bucket --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name-s3-bucket --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
  if [ $cfStat = "CREATE_FAILED" ]
  then
    printf "\nCFN S3 Bucket Stack Failed to Create\n"
    exit 1
  fi
done

printf "Create Role, Policy and SC Portfolio\n"
aws cloudformation create-stack --stack-name $resources_cfn_stack_name \
--profile $aws_cli_profile \
--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
--template-body file://service-catalog-product-resources-cfn.yml \
--parameters ParameterKey=PolicyName,ParameterValue=$sc_product_policy_name \
ParameterKey=DeploymentBucketName,ParameterValue=$deployment_s3_bucket_name \
ParameterKey=PortfolioDescription,ParameterValue="$sc_portfolio_description" \
ParameterKey=PortfolioName,ParameterValue=$sc_portfolio_name \
ParameterKey=AccessRoleName,ParameterValue="$account_access_role_name" \
ParameterKey=AccessUserName,ParameterValue="$account_access_user_name"

#Check if CloudFormation launch success
if [ $? -ne 0 ]
then
  printf "CFN Resources Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF Resources Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name $resources_cfn_stack_name --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
  if [ $cfStat = "CREATE_FAILED" ]
  then
    printf "\nCFN Resources Stack Failed to Create\n"
    exit 1
  fi
done

printf "\n\nCopy lambda code to deployment S3 Bucket\n"
aws s3 cp ../deployment-lambda/deployment-lambda.zip s3://$deployment_s3_bucket_name/share-code/deployment-lambda.zip --profile $aws_cli_profile
aws s3 cp ../product-selector-lambda/product-selector-lambda.zip s3://$deployment_s3_bucket_name/share-code/product-selector-lambda.zip --profile $aws_cli_profile
aws s3 cp ../resource-selector-lambda/resource-selector-lambda.zip s3://$deployment_s3_bucket_name/share-code/resource-selector-lambda.zip --profile $aws_cli_profile
aws s3 cp ../resource-compliance-lambda/resource-compliance-lambda.zip s3://$deployment_s3_bucket_name/share-code/resource-compliance-lambda.zip --profile $aws_cli_profile
aws s3 cp ../control-tower-account-baseline/control-tower-baseline-solution.zip s3://$deployment_s3_bucket_name/share-code/control-tower-baseline-solution.zip --profile $aws_cli_profile

printf "Creating Lambda Functions\n"
aws cloudformation create-stack --stack-name $lambda_functions_cfn_stack_name \
--profile $aws_cli_profile \
--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
--template-body file://service-catalog-lambda-functions-cfn.yml  \
--parameters ParameterKey=DeploymentBucketName,ParameterValue=$deployment_s3_bucket_name \
ParameterKey=DeploymentFunctionName,ParameterValue="$deployment_lambda_function_name" \
ParameterKey=DeploymentLambdaRoleName,ParameterValue=$deployment_lambda_role_name \
ParameterKey=ProductSelectorLambdaRoleName,ParameterValue=$product_selector_lambda_role_name \
ParameterKey=ResourceComplianceLambdaRoleName,ParameterValue=$resource_compliance_lambda_role_name \
ParameterKey=ResourceSelectorLambdaRoleName,ParameterValue=$resource_selector_lambda_role_name \
ParameterKey=PipelineRoleName,ParameterValue=$pipeline_role_name \
ParameterKey=CreateDeploymentFunction,ParameterValue=true

#Check if CloudFormation launch success
if [ $? -ne 0 ]
then
  printf "CFN Lambdas Stack Failed to Create\n"
  exit 1
fi

printf "Waiting for CF Lambdas Stack to Finish ..."
cfStat=$(aws cloudformation describe-stacks --stack-name $lambda_functions_cfn_stack_name --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
while [ $cfStat != "CREATE_COMPLETE" ]
do
  sleep 5
  printf "."
  cfStat=$(aws cloudformation describe-stacks --stack-name $lambda_functions_cfn_stack_name --query 'Stacks[0].[StackStatus]' --profile $aws_cli_profile --output text)
  if [ $cfStat = "CREATE_FAILED" ]
  then
    printf "\nCFN Lambdas Stack Failed to Create\n"
    exit 1
  fi
done

lambda_function_arn=$(aws cloudformation describe-stacks --stack-name $lambda_functions_cfn_stack_name \
--profile $aws_cli_profile \
--query 'Stacks[0].Outputs[?OutputKey==`DeploymentFunctionArn`].OutputValue' \
--output text)

printf "\n\nCopy Files to S3 Bucket\n"
aws s3 cp ../s3-upload-files s3://$deployment_s3_bucket_name/ --recursive --profile $aws_cli_profile
aws s3 cp ../control-tower-account-baseline/control-tower-baseline-solution.zip s3://$deployment_s3_bucket_name/share-code/control-tower-baseline-solution.zip --profile $aws_cli_profile

printf "Adding Trigger to S3 Bucket\n"
aws s3api put-bucket-notification-configuration --bucket $deployment_s3_bucket_name --profile $aws_cli_profile \
--notification-configuration 'LambdaFunctionConfigurations={Id="sc-deployment-lambda",LambdaFunctionArn="'$lambda_function_arn'",Events=["s3:ObjectCreated:*"],Filter={Key={FilterRules=[{Name=suffix,Value='$deployer_config_file_suffix'}]}}}'

# Wait to let deployment settle down, before deploying products to AWS Service Catalog
# slepp 150
counter=0
while [ $counter != 30 ]
do
  sleep 5
  printf "."
  counter=$((counter+1))
done

#Deploy products

#Get OS Name
getOS=$(uname -s)

# Upload Products to Service Catalog
for i in ${products_to_deploy[*]}
do
  printf "\nDeploying Configuration for Product: $i\n"

  if [ $getOS = "Darwin" ]
  then
    sed -i '' 's/var.deploymentBucket/'$deployment_s3_bucket_name'/g' ../products-config/sc-product-$i.deployer
    sed -i '' 's/var.portfolioCfn/'$resources_cfn_stack_name'/g' ../products-config/sc-product-$i.deployer
    sed -i '' 's/var.policy/'$sc_product_policy_name'/g' ../products-config/sc-product-$i.deployer
  else
    sed -i 's/var.deploymentBucket/'$deployment_s3_bucket_name'/g' ../products-config/sc-product-$i.deployer
    sed -i 's/var.portfolioCfn/'$resources_cfn_stack_name'/g' ../products-config/sc-product-$i.deployer
    sed -i 's/var.policy/'$sc_product_policy_name'/g' ../products-config/sc-product-$i.deployer
  fi
  aws s3 cp ../products-config/sc-product-$i.deployer s3://$deployment_s3_bucket_name/deployment-cfg/sc-product-$i.deployer --profile $aws_cli_profile
done

printf "\nSolution Deployed\n"
printf "You might check the status of each CFN directly under AWS Management Console\n"
