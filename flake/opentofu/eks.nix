{
  inputs,
  lib,
  config,
  ...
}:
with builtins;
with lib; let
  inherit (config.flake.cardano-parts.cluster) infra;

  system = "x86_64-linux";
  cluster = infra.aws;

  eksConfig = {
    clusterName = "playground-1";
    version = "1.34";
    # IMPORTANT: When upgrading the Kubernetes version, also update the kubectl version in:
    #   perSystem/overlays/kubectl.nix
    region = "eu-central-1";

    useDefaultVpc = true;
  };

  clusterResourceId = replaceStrings ["-"] ["_"] eksConfig.clusterName;

  awsProviderFor = region: "aws.${replaceStrings ["-"] ["_"] region}";

  sensitiveString = {
    type = "string";
    sensitive = true;
    nullable = false;
  };

  # Tags for all EKS resources
  defaultTags = {
    inherit (infra.generic) organization owner project repo;

    costCenter = "\${var.${infra.generic.costCenter}}";
    environment = "playground";
    function = "kubernetes";
    tribe = "sre";
    EKSCluster = eksConfig.clusterName;
  };

  # Helper to create IRSA (AWS IAM Roles for Kubernetes ServiceAccounts)
  # IAM Roles for ServiceAccounts allows Kubernetes pods to assume IAM roles via OIDC
  mkIRSARole = {
    name,
    serviceAccount,
    namespace,
  }: {
    "irsa_${replaceStrings ["-"] ["_"] name}" = {
      name = "${eksConfig.clusterName}-${name}";
      assume_role_policy = "\${jsonencode({
        Version = \"2012-10-17\"
        Statement = [{
          Effect = \"Allow\"
          Principal = {
            Federated = aws_iam_openid_connect_provider.eks.arn
          }
          Action = \"sts:AssumeRoleWithWebIdentity\"
          Condition = {
            StringEquals = {
              \"\${replace(aws_iam_openid_connect_provider.eks.url, \"https://\", \"\")}:sub\" = \"system:serviceaccount:${namespace}:${serviceAccount}\"
              \"\${replace(aws_iam_openid_connect_provider.eks.url, \"https://\", \"\")}:aud\" = \"sts.amazonaws.com\"
            }
          }
        }]
      })}";
      tags = defaultTags;
    };
  };

  mkIRSAPolicy = {
    name,
    policyStatements,
  }: {
    "irsa_${replaceStrings ["-"] ["_"] name}" = {
      name = "${eksConfig.clusterName}-${name}";
      policy = toJSON {
        Version = "2012-10-17";
        Statement = policyStatements;
      };
      tags = defaultTags;
    };
  };
in {
  flake.opentofu.k8s = inputs.cardano-parts.inputs.terranix.lib.terranixConfiguration {
    inherit system;
    modules = [
      {
        terraform = {
          required_providers = {
            aws.source = "opentofu/aws";
          };

          # This bucket is created by CloudFormation
          backend = {
            s3 = {
              inherit (cluster) region;
              bucket = cluster.bucketName;
              key = "terraform-k8s";
              dynamodb_table = "terraform";
            };
          };
        };

        variable = {
          "${infra.generic.costCenter}" = sensitiveString;
        };

        provider.aws = {
          inherit (eksConfig) region;
          alias = replaceStrings ["-"] ["_"] eksConfig.region;
          default_tags.tags = defaultTags;
        };

        # Data sources for existing infrastructure
        data = {
          aws_caller_identity.current = {};
          aws_region.current = {};

          # Get default VPC
          aws_vpc.default = {
            provider = awsProviderFor eksConfig.region;
            default = true;
          };

          # Get all subnets in default VPC for multi-AZ HA
          aws_subnets.default = {
            provider = awsProviderFor eksConfig.region;
            filter = {
              name = "vpc-id";
              values = ["\${data.aws_vpc.default.id}"];
            };
          };

          # Reference to EKS cluster for add-ons
          aws_eks_cluster."${clusterResourceId}_data" = {
            name = eksConfig.clusterName;
            depends_on = ["aws_eks_cluster.${clusterResourceId}"];
          };
        };

        resource = {
          # ===========================================
          # IAM ROLES
          # ===========================================

          aws_iam_role =
            {
              # EKS Cluster IAM Role
              eks_cluster = {
                name = "${eksConfig.clusterName}-cluster-role";
                assume_role_policy = toJSON {
                  Version = "2012-10-17";
                  Statement = [
                    {
                      Action = "sts:AssumeRole";
                      Effect = "Allow";
                      Principal.Service = "eks.amazonaws.com";
                    }
                  ];
                };
                tags = defaultTags;
              };

              # Node Group IAM Role
              eks_node_group = {
                name = "${eksConfig.clusterName}-node-group-role";
                assume_role_policy = toJSON {
                  Version = "2012-10-17";
                  Statement = [
                    {
                      Action = "sts:AssumeRole";
                      Effect = "Allow";
                      Principal.Service = "ec2.amazonaws.com";
                    }
                  ];
                };
                tags = defaultTags;
              };
            }
            # IRSA roles for Kubernetes ServiceAccounts
            // mkIRSARole {
              name = "ebs-csi-driver";
              serviceAccount = "ebs-csi-controller-sa";
              namespace = "kube-system";
            }
            // mkIRSARole {
              name = "aws-load-balancer-controller";
              serviceAccount = "aws-load-balancer-controller";
              namespace = "aws-load-balancer-controller";
            }
            // mkIRSARole {
              name = "external-dns";
              serviceAccount = "external-dns";
              namespace = "external-dns";
            }
            // mkIRSARole {
              name = "cert-manager";
              serviceAccount = "cert-manager";
              namespace = "cert-manager";
            };

          # ===========================================
          # IAM POLICIES
          # ===========================================

          aws_iam_policy =
            mkIRSAPolicy {
              name = "ebs-csi-driver";
              policyStatements = [
                {
                  Effect = "Allow";
                  Action = [
                    "ec2:CreateSnapshot"
                    "ec2:AttachVolume"
                    "ec2:DetachVolume"
                    "ec2:ModifyVolume"
                    "ec2:DescribeAvailabilityZones"
                    "ec2:DescribeInstances"
                    "ec2:DescribeSnapshots"
                    "ec2:DescribeTags"
                    "ec2:DescribeVolumes"
                    "ec2:DescribeVolumesModifications"
                  ];
                  Resource = "*";
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:CreateTags"];
                  Resource = [
                    "arn:aws:ec2:*:*:volume/*"
                    "arn:aws:ec2:*:*:snapshot/*"
                  ];
                  Condition = {
                    StringEquals = {
                      "ec2:CreateAction" = [
                        "CreateVolume"
                        "CreateSnapshot"
                      ];
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteTags"];
                  Resource = [
                    "arn:aws:ec2:*:*:volume/*"
                    "arn:aws:ec2:*:*:snapshot/*"
                  ];
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:CreateVolume"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "aws:RequestTag/ebs.csi.aws.com/cluster" = "true";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:CreateVolume"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "aws:RequestTag/CSIVolumeName" = "*";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteVolume"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteVolume"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "ec2:ResourceTag/CSIVolumeName" = "*";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteVolume"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "ec2:ResourceTag/kubernetes.io/created-for/pvc/name" = "*";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteSnapshot"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "ec2:ResourceTag/CSIVolumeSnapshotName" = "*";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:DeleteSnapshot"];
                  Resource = "*";
                  Condition = {
                    StringLike = {
                      "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true";
                    };
                  };
                }
              ];
            }
            // mkIRSAPolicy {
              name = "aws-load-balancer-controller";
              policyStatements = [
                {
                  Effect = "Allow";
                  Action = ["iam:CreateServiceLinkedRole"];
                  Resource = "*";
                  Condition = {
                    StringEquals = {
                      "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "ec2:DescribeAccountAttributes"
                    "ec2:DescribeAddresses"
                    "ec2:DescribeAvailabilityZones"
                    "ec2:DescribeInternetGateways"
                    "ec2:DescribeVpcs"
                    "ec2:DescribeVpcPeeringConnections"
                    "ec2:DescribeSubnets"
                    "ec2:DescribeSecurityGroups"
                    "ec2:DescribeInstances"
                    "ec2:DescribeNetworkInterfaces"
                    "ec2:DescribeTags"
                    "ec2:GetCoipPoolUsage"
                    "ec2:DescribeCoipPools"
                    "elasticloadbalancing:DescribeLoadBalancers"
                    "elasticloadbalancing:DescribeLoadBalancerAttributes"
                    "elasticloadbalancing:DescribeListeners"
                    "elasticloadbalancing:DescribeListenerCertificates"
                    "elasticloadbalancing:DescribeSSLPolicies"
                    "elasticloadbalancing:DescribeRules"
                    "elasticloadbalancing:DescribeTargetGroups"
                    "elasticloadbalancing:DescribeTargetGroupAttributes"
                    "elasticloadbalancing:DescribeTargetHealth"
                    "elasticloadbalancing:DescribeTags"
                  ];
                  Resource = "*";
                }
                {
                  Effect = "Allow";
                  Action = [
                    "cognito-idp:DescribeUserPoolClient"
                    "acm:ListCertificates"
                    "acm:DescribeCertificate"
                    "iam:ListServerCertificates"
                    "iam:GetServerCertificate"
                    "waf-regional:GetWebACL"
                    "waf-regional:GetWebACLForResource"
                    "waf-regional:AssociateWebACL"
                    "waf-regional:DisassociateWebACL"
                    "wafv2:GetWebACL"
                    "wafv2:GetWebACLForResource"
                    "wafv2:AssociateWebACL"
                    "wafv2:DisassociateWebACL"
                    "shield:GetSubscriptionState"
                    "shield:DescribeProtection"
                    "shield:CreateProtection"
                    "shield:DeleteProtection"
                  ];
                  Resource = "*";
                }
                {
                  Effect = "Allow";
                  Action = [
                    "ec2:AuthorizeSecurityGroupIngress"
                    "ec2:RevokeSecurityGroupIngress"
                    "ec2:CreateSecurityGroup"
                  ];
                  Resource = "*";
                }
                {
                  Effect = "Allow";
                  Action = ["ec2:CreateTags"];
                  Resource = "arn:aws:ec2:*:*:security-group/*";
                  Condition = {
                    StringEquals = {
                      "ec2:CreateAction" = "CreateSecurityGroup";
                    };
                    "Null" = {
                      "aws:RequestTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "ec2:CreateTags"
                    "ec2:DeleteTags"
                  ];
                  Resource = "arn:aws:ec2:*:*:security-group/*";
                  Condition = {
                    "Null" = {
                      "aws:RequestTag/elbv2.k8s.aws/cluster" = "true";
                      "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "ec2:AuthorizeSecurityGroupIngress"
                    "ec2:RevokeSecurityGroupIngress"
                    "ec2:DeleteSecurityGroup"
                  ];
                  Resource = "*";
                  Condition = {
                    "Null" = {
                      "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:CreateLoadBalancer"
                    "elasticloadbalancing:CreateTargetGroup"
                  ];
                  Resource = "*";
                  Condition = {
                    "Null" = {
                      "aws:RequestTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:CreateListener"
                    "elasticloadbalancing:DeleteListener"
                    "elasticloadbalancing:CreateRule"
                    "elasticloadbalancing:DeleteRule"
                    "elasticloadbalancing:AddListenerCertificates"
                    "elasticloadbalancing:RemoveListenerCertificates"
                    "elasticloadbalancing:ModifyListener"
                  ];
                  Resource = "*";
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:AddTags"
                    "elasticloadbalancing:RemoveTags"
                  ];
                  Resource = [
                    "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
                    "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*"
                    "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
                  ];
                  Condition = {
                    "Null" = {
                      "aws:RequestTag/elbv2.k8s.aws/cluster" = "true";
                      "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:AddTags"
                    "elasticloadbalancing:RemoveTags"
                  ];
                  Resource = [
                    "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*"
                    "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*"
                    "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*"
                    "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
                  ];
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:ModifyLoadBalancerAttributes"
                    "elasticloadbalancing:SetIpAddressType"
                    "elasticloadbalancing:SetSecurityGroups"
                    "elasticloadbalancing:SetSubnets"
                    "elasticloadbalancing:DeleteLoadBalancer"
                    "elasticloadbalancing:ModifyTargetGroup"
                    "elasticloadbalancing:ModifyTargetGroupAttributes"
                    "elasticloadbalancing:DeleteTargetGroup"
                  ];
                  Resource = "*";
                  Condition = {
                    "Null" = {
                      "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false";
                    };
                  };
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:RegisterTargets"
                    "elasticloadbalancing:DeregisterTargets"
                  ];
                  Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*";
                }
                {
                  Effect = "Allow";
                  Action = [
                    "elasticloadbalancing:SetWebAcl"
                    "elasticloadbalancing:ModifyListener"
                    "elasticloadbalancing:AddListenerCertificates"
                    "elasticloadbalancing:RemoveListenerCertificates"
                    "elasticloadbalancing:ModifyRule"
                  ];
                  Resource = "*";
                }
              ];
            }
            // mkIRSAPolicy {
              name = "external-dns";
              policyStatements = [
                {
                  Effect = "Allow";
                  Action = ["route53:ChangeResourceRecordSets"];
                  Resource = ["arn:aws:route53:::hostedzone/*"];
                }
                {
                  Effect = "Allow";
                  Action = [
                    "route53:ListHostedZones"
                    "route53:ListResourceRecordSets"
                    "route53:ListTagsForResource"
                  ];
                  Resource = ["*"];
                }
              ];
            }
            // mkIRSAPolicy {
              name = "cert-manager";
              policyStatements = [
                {
                  Effect = "Allow";
                  Action = ["route53:GetChange"];
                  Resource = ["arn:aws:route53:::change/*"];
                }
                {
                  Effect = "Allow";
                  Action = [
                    "route53:ChangeResourceRecordSets"
                    "route53:ListResourceRecordSets"
                  ];
                  Resource = ["arn:aws:route53:::hostedzone/*"];
                }
                {
                  Effect = "Allow";
                  Action = ["route53:ListHostedZonesByName"];
                  Resource = ["*"];
                }
              ];
            };

          # ===========================================
          # IAM POLICY ATTACHMENTS
          # ===========================================

          aws_iam_role_policy_attachment = {
            # EKS Cluster policies
            eks_cluster_policy = {
              role = "\${aws_iam_role.eks_cluster.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy";
            };

            eks_vpc_resource_controller = {
              role = "\${aws_iam_role.eks_cluster.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController";
            };

            # Node Group policies
            eks_worker_node_policy = {
              role = "\${aws_iam_role.eks_node_group.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy";
            };

            eks_cni_policy = {
              role = "\${aws_iam_role.eks_node_group.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy";
            };

            ec2_container_registry_read_only = {
              role = "\${aws_iam_role.eks_node_group.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly";
            };

            ssm_managed_instance_core = {
              role = "\${aws_iam_role.eks_node_group.name}";
              policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore";
            };

            # IRSA policy attachments
            ebs_csi_driver = {
              role = "\${aws_iam_role.irsa_ebs_csi_driver.name}";
              policy_arn = "\${aws_iam_policy.irsa_ebs_csi_driver.arn}";
            };

            aws_load_balancer_controller = {
              role = "\${aws_iam_role.irsa_aws_load_balancer_controller.name}";
              policy_arn = "\${aws_iam_policy.irsa_aws_load_balancer_controller.arn}";
            };

            external_dns = {
              role = "\${aws_iam_role.irsa_external_dns.name}";
              policy_arn = "\${aws_iam_policy.irsa_external_dns.arn}";
            };

            cert_manager = {
              role = "\${aws_iam_role.irsa_cert_manager.name}";
              policy_arn = "\${aws_iam_policy.irsa_cert_manager.arn}";
            };
          };

          # ===========================================
          # EKS CLUSTER
          # ===========================================

          aws_eks_cluster."${clusterResourceId}" = {
            name = eksConfig.clusterName;
            role_arn = "\${aws_iam_role.eks_cluster.arn}";
            inherit (eksConfig) version;

            vpc_config = {
              subnet_ids = "\${data.aws_subnets.default.ids}";
              endpoint_private_access = true;
              endpoint_public_access = true;
              public_access_cidrs = ["0.0.0.0/0"];
            };

            # Enable control plane logging to CloudWatch Logs
            enabled_cluster_log_types = [
              "api"
              "audit"
              "authenticator"
              "controllerManager"
              "scheduler"
            ];

            # Encryption at rest using KMS
            encryption_config = {
              provider.key_arn = "\${aws_kms_key.eks.arn}";
              resources = ["secrets"];
            };

            depends_on = [
              "aws_iam_role_policy_attachment.eks_cluster_policy"
              "aws_iam_role_policy_attachment.eks_vpc_resource_controller"
            ];

            tags = defaultTags;
          };

          # KMS key for EKS secrets encryption
          aws_kms_key.eks = {
            description = "EKS cluster ${eksConfig.clusterName} encryption key";
            enable_key_rotation = true;
            tags = defaultTags;
          };

          aws_kms_alias.eks = {
            name = "alias/eks-${eksConfig.clusterName}";
            target_key_id = "\${aws_kms_key.eks.id}";
          };

          # OpenID Connect provider for IRSA (AWS IAM Roles for Kubernetes ServiceAccounts)
          aws_iam_openid_connect_provider.eks = {
            url = "\${aws_eks_cluster.${clusterResourceId}.identity[0].oidc[0].issuer}";
            client_id_list = ["sts.amazonaws.com"];
            thumbprint_list = [
              # AWS EKS OIDC thumbprint (verified 2026-03-22)
              # To update, run: openssl s_client -servername oidc.eks.eu-central-1.amazonaws.com -connect oidc.eks.eu-central-1.amazonaws.com:443 2>&1 < /dev/null | openssl x509 -fingerprint -sha1 -noout -in /dev/stdin | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
              "19ad2e462c50e774b5c5703380bef4eb49c62767"
            ];
            tags = defaultTags;
          };

          # ===========================================
          # MANAGED NODE GROUPS
          # ===========================================

          # Security group for nodes
          aws_security_group.eks_nodes = {
            name = "${eksConfig.clusterName}-nodes";
            description = "Security group for EKS worker nodes";
            vpc_id = "\${data.aws_vpc.default.id}";

            egress = [
              {
                description = "Allow all outbound";
                from_port = 0;
                to_port = 0;
                protocol = "-1";
                cidr_blocks = ["0.0.0.0/0"];
                ipv6_cidr_blocks = ["::/0"];
                prefix_list_ids = [];
                security_groups = [];
                self = false;
              }
            ];

            tags = defaultTags // {Name = "${eksConfig.clusterName}-nodes";};
          };

          # Allow nodes to communicate with each other
          aws_security_group_rule.nodes_internal = {
            type = "ingress";
            from_port = 0;
            to_port = 65535;
            protocol = "-1";
            security_group_id = "\${aws_security_group.eks_nodes.id}";
            source_security_group_id = "\${aws_security_group.eks_nodes.id}";
            description = "Allow nodes to communicate with each other";
          };

          # Allow nodes to receive communication from cluster control plane
          aws_security_group_rule.nodes_cluster_inbound = {
            type = "ingress";
            from_port = 1025;
            to_port = 65535;
            protocol = "tcp";
            security_group_id = "\${aws_security_group.eks_nodes.id}";
            source_security_group_id = "\${aws_eks_cluster.${clusterResourceId}.vpc_config[0].cluster_security_group_id}";
            description = "Allow worker Kubelets and pods to receive communication from the cluster control plane";
          };

          # Managed Node Group - General purpose (Amazon Linux 2023)
          aws_eks_node_group.general = {
            cluster_name = "\${aws_eks_cluster.${clusterResourceId}.name}";
            node_group_name = "general-al2023";
            node_role_arn = "\${aws_iam_role.eks_node_group.arn}";
            subnet_ids = "\${data.aws_subnets.default.ids}";
            inherit (eksConfig) version;

            ami_type = "AL2023_x86_64_STANDARD";
            capacity_type = "ON_DEMAND";
            disk_size = 100;

            scaling_config = {
              desired_size = 2;
              min_size = 2;
              max_size = 10;
            };

            instance_types = [
              "t3.medium"
              "t3a.medium"
              "t3.large"
              "t3a.large"
            ];

            update_config = {
              max_unavailable_percentage = 33;
            };

            labels = {
              workload = "general";
              inherit (infra.generic) environment;
            };

            tags = defaultTags // {Name = "general-node";};

            depends_on = [
              "aws_iam_role_policy_attachment.eks_worker_node_policy"
              "aws_iam_role_policy_attachment.eks_cni_policy"
              "aws_iam_role_policy_attachment.ec2_container_registry_read_only"
            ];

            lifecycle = [
              {
                ignore_changes = ["scaling_config[0].desired_size"];
              }
            ];
          };

          # Spot Node Group - For infrastructure workloads
          aws_eks_node_group.spot = {
            cluster_name = "\${aws_eks_cluster.${clusterResourceId}.name}";
            node_group_name = "spot-infra";
            node_role_arn = "\${aws_iam_role.eks_node_group.arn}";
            subnet_ids = "\${data.aws_subnets.default.ids}";
            inherit (eksConfig) version;

            ami_type = "AL2023_x86_64_STANDARD";
            capacity_type = "SPOT";
            disk_size = 100;

            scaling_config = {
              desired_size = 1;
              max_size = 10;
              min_size = 0;
            };

            instance_types = [
              "t3.medium"
              "t3a.medium"
              "t3.large"
              "t3a.large"
              "t2.medium"
              "t2.large"
            ];

            update_config = {
              max_unavailable_percentage = 50;
            };

            labels = {
              workload = "infrastructure";
              capacity-type = "spot";
            };

            taint = [
              {
                key = "spot";
                value = "true";
                effect = "NO_SCHEDULE";
              }
            ];

            tags =
              defaultTags
              // {
                Name = "spot-infra-node";
                SpotInstance = "true";
              };

            depends_on = [
              "aws_iam_role_policy_attachment.eks_worker_node_policy"
              "aws_iam_role_policy_attachment.eks_cni_policy"
              "aws_iam_role_policy_attachment.ec2_container_registry_read_only"
            ];

            lifecycle = [
              {
                ignore_changes = ["scaling_config[0].desired_size"];
              }
            ];
          };

          # ===========================================
          # AWS-MANAGED EKS ADD-ONS
          # ===========================================

          aws_eks_addon = {
            vpc_cni = {
              cluster_name = eksConfig.clusterName;
              addon_name = "vpc-cni";
              resolve_conflicts_on_create = "OVERWRITE";
              resolve_conflicts_on_update = "PRESERVE";
              preserve = true;
              tags = defaultTags;

              depends_on = ["aws_eks_cluster.${clusterResourceId}"];
            };

            coredns = {
              cluster_name = eksConfig.clusterName;
              addon_name = "coredns";
              resolve_conflicts_on_create = "OVERWRITE";
              resolve_conflicts_on_update = "PRESERVE";
              preserve = true;
              tags = defaultTags;

              depends_on = ["aws_eks_addon.vpc_cni"];
            };

            kube_proxy = {
              cluster_name = eksConfig.clusterName;
              addon_name = "kube-proxy";
              resolve_conflicts_on_create = "OVERWRITE";
              resolve_conflicts_on_update = "PRESERVE";
              preserve = true;
              tags = defaultTags;

              depends_on = ["aws_eks_cluster.${clusterResourceId}"];
            };

            ebs_csi_driver = {
              cluster_name = eksConfig.clusterName;
              addon_name = "aws-ebs-csi-driver";
              resolve_conflicts_on_create = "OVERWRITE";
              resolve_conflicts_on_update = "PRESERVE";
              preserve = true;
              service_account_role_arn = "\${aws_iam_role.irsa_ebs_csi_driver.arn}";
              tags = defaultTags;

              depends_on = ["aws_eks_cluster.${clusterResourceId}"];
            };
          };
        };

        # Outputs for connecting to cluster and using IRSA roles
        output = {
          kubeconfig_command = {
            description = "Command to configure kubectl access to the cluster";
            value = "aws eks update-kubeconfig --region ${eksConfig.region} --name ${eksConfig.clusterName}";
          };

          # IRSA Role ARNs - annotate Kubernetes ServiceAccounts with these ARNs
          # Example: eks.amazonaws.com/role-arn: <arn-from-output>
          ebs_csi_driver_role_arn = {
            description = "IAM role ARN for EBS CSI Driver ServiceAccount (kube-system/ebs-csi-controller-sa)";
            value = "\${aws_iam_role.irsa_ebs_csi_driver.arn}";
          };

          aws_load_balancer_controller_role_arn = {
            description = "IAM role ARN for AWS Load Balancer Controller ServiceAccount (aws-load-balancer-controller/aws-load-balancer-controller)";
            value = "\${aws_iam_role.irsa_aws_load_balancer_controller.arn}";
          };

          external_dns_role_arn = {
            description = "IAM role ARN for External DNS ServiceAccount (external-dns/external-dns)";
            value = "\${aws_iam_role.irsa_external_dns.arn}";
          };

          cert_manager_role_arn = {
            description = "IAM role ARN for cert-manager ServiceAccount (cert-manager/cert-manager)";
            value = "\${aws_iam_role.irsa_cert_manager.arn}";
          };

          z_IMPORTANT_REMINDER_disable_aws_guardduty = {
            description = "AWS auto-installs GuardDuty (paid service). Run this command to disable it";
            value = "aws eks delete-addon --cluster-name ${eksConfig.clusterName} --addon-name aws-guardduty-agent --region ${eksConfig.region}";
          };
        };
      }
    ];
  };
}
