provider "kubernetes" {
  host                   = module.eks_1.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_1.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_1.cluster_name]
  }
  alias = "kubernetes_1"
}

provider "helm" {
  kubernetes {
    host                   = module.eks_1.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_1.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks_1.cluster_name]
    }
  }
  alias = "helm_1"
}

################################################################################
# VPC
################################################################################

module "vpc_1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.eks_1_name}-vpc"
  cidr = local.vpc_1_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_1_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_1_cidr, 8, k + 48)]

  enable_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = merge({
    Name = "${local.eks_1_name}-vpc"
  }, local.tags)
}

################################################################################
# Cluster
################################################################################

module "eks_1" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16"

  cluster_name                   = local.eks_1_name
  cluster_version                = local.eks_cluster_version
  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      preserve = true
    }
  }

  vpc_id     = module.vpc_1.vpc_id
  subnet_ids = module.vpc_1.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["t3.medium"]

      min_size     = 1
      max_size     = 5
      desired_size = 2
    }
  }

  #  EKS K8s API cluster needs to be able to talk with the EKS worker nodes with port 15017/TCP and 15012/TCP which is used by Istio
  #  Istio in order to create sidecar needs to be able to communicate with webhook and for that network passage to EKS is needed.
  node_security_group_additional_rules = {
    ingress_15017 = {
      description                   = "Cluster API - Istio Webhook namespace.sidecar-injector.istio.io"
      protocol                      = "TCP"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15012 = {
      description                   = "Cluster API to nodes ports/protocols"
      protocol                      = "TCP"
      from_port                     = 15012
      to_port                       = 15012
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = local.tags
}

resource "kubernetes_namespace_v1" "istio_system_1" {
  metadata {
    name = "istio-system"
    labels = {
      "topology.istio.io/network" = local.networkName1
    }
  }
  provider = kubernetes.kubernetes_1
}

# Create secret for custom certificates in Cluster 1
resource "kubernetes_secret" "cacerts_cluster1" {
  metadata {
    name      = "cacerts"
    namespace = kubernetes_namespace_v1.istio_system_1.metadata[0].name
  }

  data = {
    "ca-cert.pem"    = file("certs/cluster1/ca-cert.pem")
    "ca-key.pem"     = file("certs/cluster1/ca-key.pem")
    "root-cert.pem"  = file("certs/cluster1/root-cert.pem")
    "cert-chain.pem" = file("certs/cluster1/cert-chain.pem")
  }
  provider = kubernetes.kubernetes_1
}

module "eks_1_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks_1.cluster_name
  cluster_endpoint  = module.eks_1.cluster_endpoint
  cluster_version   = module.eks_1.cluster_version
  oidc_provider_arn = module.eks_1.oidc_provider_arn

  # This is required to expose Istio Ingress Gateway
  enable_aws_load_balancer_controller = true

  helm_releases = {
    istio-operator = {
      chart            = "istio-operator"
      chart_version    = "2.13.2"
      repository       = "https://stevehipwell.github.io/helm-charts/"
      name             = "istio-operator"
      namespace        = "istio-operator"
      create_namespace = true

      set = [{
        name  = "watchedNamespaces"
        value = "${kubernetes_namespace_v1.istio_system_1.metadata[0].name}"
      }]
    }
  }

  tags = local.tags

  providers = {
    kubernetes = kubernetes.kubernetes_1
    helm       = helm.helm_1
  }
}

resource "helm_release" "istio_cluster_1" {
  name       = "istio-cluster"
  repository = "./"
  namespace  = kubernetes_namespace_v1.istio_system_1.metadata[0].name
  chart      = "istio-cluster"

  set {
    name  = "clusterName"
    value = local.clusterName1
  }

  set {
    name  = "networkName"
    value = local.networkName1
  }

  set {
    name  = "meshID"
    value = "mesh1"
  }  

  provider = helm.helm_1
}

resource "helm_release" "istio_eastwest_1" {
  name       = "istio-eastwest"
  repository = "./"
  namespace  = kubernetes_namespace_v1.istio_system_1.metadata[0].name
  chart      = "istio-eastwest"

  set {
    name  = "clusterName"
    value = local.clusterName1
  }

  set {
    name  = "networkName"
    value = local.networkName1
  }

  provider = helm.helm_1
}

resource "kubernetes_secret" "istio_reader_token_1" {
  metadata {
    annotations = {
      "kubernetes.io/service-account.name" = "istio-reader-service-account"
    }
    name      = "istio-reader-service-account-istio-remote-secret-token"
    namespace = kubernetes_namespace_v1.istio_system_1.metadata[0].name
  }
  type = "kubernetes.io/service-account-token"

  provider = kubernetes.kubernetes_1
}

data "kubernetes_secret" "istio_reader_token_1" {
  metadata {
    name      = kubernetes_secret.istio_reader_token_1.metadata[0].name
    namespace = kubernetes_namespace_v1.istio_system_1.metadata[0].name
  }
  provider = kubernetes.kubernetes_1
}

resource "kubernetes_namespace_v1" "sample_namespace_1" {
  metadata {
    name = "sample"
    labels = {
      "istio-injection" = "enabled"
    }
  }
  provider = kubernetes.kubernetes_1
}

resource "helm_release" "multicluster_verification_1" {
  name       = "multicluster-verification"
  repository = "./"
  namespace  = kubernetes_namespace_v1.sample_namespace_1.metadata[0].name
  chart      = "multicluster-verification"

  set {
    name  = "version"
    value = "v1"
  }

  set {
    name  = "clusterName"
    value = local.clusterName2
  }

  set {
    name  = "certificateAuthorityData"
    value = module.eks_2.cluster_certificate_authority_data
  }

  set {
    name  = "server"
    value = module.eks_2.cluster_endpoint
  }

  set {
    name  = "token"
    value = kubernetes_secret.istio_reader_token_2.data["token"]
  }

  provider = helm.helm_1
}