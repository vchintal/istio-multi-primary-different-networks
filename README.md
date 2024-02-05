# Istio multi-primary on different networks on EKS

## Prerequisites

Ensure that you have installed the following tools locally:

1. [awscli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
2. [kubectl](https://kubernetes.io/docs/tasks/tools/)
3. [terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli)
4. [istioctl](https://istio.io/latest/docs/ops/diagnostic-tools/istioctl/)

## Deploy 

### Generate Certs
Before you could deploy the Terraform, run the following command to generate 
certs for `cluster1` and `cluster2`:

```sh
sh generate_certs.sh
```

### Terraform
To deploy the terraform repo, run the commands shown below:
```sh 
terraform init

terraform apply --auto-approve \
    -target=module.vpc_1 \
    -target=module.vpc_2 \
    -target=module.eks_1 \
    -target=module.eks_2 \
    -target=module.eks_1_addons \
    -target=module.eks_2_addons \
    -target=kubernetes_secret.cacerts_cluster1 \
    -target=kubernetes_secret.cacerts_cluster2

terraform apply --auto-approve \
    -target=helm_release.istio_cluster_1 \
    -target=helm_release.istio_cluster_2
```

After running the command successfully, set the kubeconfig for both EKS clusters:
```sh 
aws eks update-kubeconfig --region us-west-2 --name eks-1
aws eks update-kubeconfig --region us-west-2 --name eks-2
CTX_CLUSTER1=`aws eks describe-cluster --name eks-1 | jq -r '.cluster.arn'`
CTX_CLUSTER2=`aws eks describe-cluster --name eks-2 | jq -r '.cluster.arn'`
```

Check on either clusters if the deployed `IstioOperator`s are healthy:

```sh
k get istiooperator.install.istio.io  -n istio-system --context $CTX_CLUSTER1
k get istiooperator.install.istio.io  -n istio-system --context $CTX_CLUSTER2
```

The output should be similar to: 

```
NAME       REVISION   STATUS    AGE
cluster               HEALTHY   24s
```

After ensuring that the `IstioOperator`s are healthy, deploy rest of the 
terraform repo:

```sh 
terraform apply --auto-approve
```

## Testing

### Readiness of the Istio Gateway loadbalancers

Before you could do any testing, you need to ensure that:
* The loadbalancer for `istio-eastwestgateway` service is ready for the traffic 
* The loadblanncer target groups have their targets ready. 

Use the following scripts to test the readiness of the LBs.
> Note: Change the k8s context to run it against the other cluster
```sh 
EW_LB_NAME=$(k get svc istio-eastwestgateway -n istio-system --context $CTX_CLUSTER1 -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')

EW_LB_ARN=$(aws elbv2 describe-load-balancers | \
jq -r --arg EW_LB_NAME "$EW_LB_NAME" \
'.LoadBalancers[] | select(.DNSName == $EW_LB_NAME) | .LoadBalancerArn')

TG_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $EW_LB_ARN | jq -r '.Listeners[] | select(.Port == 15443) | .DefaultActions[0].TargetGroupArn')

aws elbv2 describe-target-health --target-group-arn $TG_ARN | jq -r '.TargetHealthDescriptions[0]'
```

You should see an output similar to below before proceeding any further:
```
{
  "Target": {
    "Id": "10.1.0.227",
    "Port": 15443,
    "AvailabilityZone": "us-west-2a"
  },
  "HealthCheckPort": "15443",
  "TargetHealth": {
    "State": "healthy"
  }
}
```

### Cross-Cluster Sync

Run the following commands to ensure that the public Load Balancer IP addresses 
are displayed in the output as shown. 

> Note: Change the k8s context to run it against the other cluster

```sh 
POD_NAME=$(kubectl get pod --context="${CTX_CLUSTER1}" -l app=sleep -o jsonpath='{.items[0].metadata.name}' -n sample)

istioctl --context $CTX_CLUSTER1 proxy-config endpoint $POD_NAME -n sample | grep helloworld
```

The output should be similar to:
```
10.1.8.162:5000                                         HEALTHY     OK                outbound|5000||helloworld.sample.svc.cluster.local
100.21.48.49:15443                                      HEALTHY     OK                outbound|5000||helloworld.sample.svc.cluster.local
34.209.120.99:15443                                     HEALTHY     OK                outbound|5000||helloworld.sample.svc.cluster.local
52.36.169.59:15443                                      HEALTHY     OK                outbound|5000||helloworld.sample.svc.cluster.local
```

If you do public IP addresses in the output proceed further to test multi-cluster 
communication.

### Cross-cluster Load-Balancing 

Run the following command to check cross-cluster loadbalancing from the first cluster.

```
for i in {1..10}
do 
kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep \
    "$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello
done
```
Also test similar command to check cross-cluster loadbalancing from the second cluster.

```
for i in {1..10}
do 
kubectl exec --context="${CTX_CLUSTER2}" -n sample -c sleep \
    "$(kubectl get pod --context="${CTX_CLUSTER2}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello
done
```

In either case the output should be similar to:

```
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v2, instance: helloworld-v2-7f46498c69-5g9rk
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v2, instance: helloworld-v2-7f46498c69-5g9rk
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v2, instance: helloworld-v2-7f46498c69-5g9rk
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v1, instance: helloworld-v1-867747c89-7vzwl
Hello version: v2, instance: helloworld-v2-7f46498c69-5g9rk
```

## Destroy 
```sh 
# Remove all helm repositories first. This ensures that all the loadbalancer are
# terminated first  
TARGETS=""
terraform state list | egrep '^helm*' | while read HELM_INSTALL
do
    TARGETS+="--target=$HELM_INSTALL "
done
sh -c "terraform destroy --auto-approve $TARGETS"

# Remove all the rest 
terraform destroy --auto-approve
```

## Troubleshooting

There are many things that can go wrong when deploying a complex solutions such 
as this, Istio multi-primary on different networks.

### Ordering in Terraform deployment

The ordering is important when deploying the resources with Terraform and here 
it is:
1. Deploy VPCs, EKS clusters and EKS AddOns (this deploys the IstioOperator 
Controller)
2. Create the `istio-system` namespace 
3. Deploy the `cacerts` secret in the `istio-system` namespace
4. Deploy the `IstioOperator` that creates the Istio service mesh in `istio-system`
   * This step after step #3 would cause the `cacerts` to picked up and processed 
   by Istio control plane
5. Deploy the `IstioOperator` that creates the `eastwest` Ingress Gateway 
deployment and service. With this step, you can also bundle the Istio `Gateway`
definition.
6. Lastly, deploy the cross-cluster secrets for `istiod` to other


## Documentation Links 

1. [Install Multi-Primary on different networks](https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/)
2. [Verifying cross-cluster traffic](https://istio.io/latest/docs/setup/install/multicluster/verify/#verifying-cross-cluster-traffic)
3. [Multicluster Troubleshooting](https://istio.io/latest/docs/ops/diagnostic-tools/multicluster/)
