{
  inputs,
  lib,
  config,
  ...
}: let
  inherit (config.flake.lib.strings) dashToSnake;

  inherit (config.flake.cardano-parts.cluster) infra;

  system = "x86_64-linux";

  bucketPolicyStatementSecureTransport = bucketArn: {
    sid = "RestrictToTLSRequestsOnly";
    effect = "Deny";
    actions = ["s3:*"];
    resources = [
      bucketArn
      "${bucketArn}/*"
    ];
    condition = {
      test = "Bool";
      variable = "aws:SecureTransport";
      values = ["false"];
    };
    principals = {
      type = "*";
      identifiers = ["*"];
    };
  };

  unmanagedBuckets = ["rain_artifacts"];

  workspace = "bootstrap";

  awsProviderFor = region: "aws.${dashToSnake region}";
  awsccProviderFor = region: "awscc.${dashToSnake region}";

  sensitiveString = {
    type = "string";
    sensitive = true;
    nullable = false;
  };
in {
  flake.opentofu.${workspace} = inputs.cardano-parts.inputs.terranix.lib.terranixConfiguration {
    strip_nulls = false;
    inherit system;
    modules = [
      {
        terraform = {
          required_providers = {
            aws.source = "opentofu/aws";
            awscc.source = "opentofu/awscc";
            external.source = "opentofu/external";
          };

          backend = {
            s3 = {
              inherit (infra.aws) region;
              bucket = infra.aws.bucketName;
              key = "terraform";
              dynamodb_table = "terraform";
            };
          };
        };

        variable = {
          # costCenter tag should remain secret in public repos
          ${infra.generic.costCenter} = sensitiveString;

          # Separate (secret) cost center for leios resources, mirroring the
          # cluster workspace. Applied as a per-resource tag override below.
          tag_costCenterLeios = sensitiveString;
        };

        provider = {
          aws = lib.forEach (lib.attrNames infra.aws.regions) (region: {
            inherit region;
            alias = dashToSnake region;
            default_tags.tags = {
              inherit
                (infra.generic)
                environment
                function
                organization
                owner
                project
                repo
                tribe
                ;

              # costCenter is saved as a secret
              costCenter = "\${var.${infra.generic.costCenter}}";

              TerraformWorkspace = workspace;
              TerraformState = "s3://${infra.aws.bucketName}/env:/${workspace}/terraform";
            };
          });

          awscc = lib.forEach (lib.attrNames infra.aws.regions) (region: {
            inherit region;
            alias = dashToSnake region;
          });
        };
      }

      # Configure rain's and CloudFormation's buckets.
      {
        data = {
          awscc_s3_buckets.this = {
            provider = awsccProviderFor infra.aws.region;
          };

          aws_iam_policy_document = lib.listToAttrs (
            lib.forEach unmanagedBuckets (
              name:
                lib.nameValuePair "s3_bucket_policy-${name}" {
                  statement = bucketPolicyStatementSecureTransport "arn:aws:s3:::\${local.aws_s3_bucket-${name}-id}";
                }
            )
          );
        };

        locals = {
          aws_s3_bucket-rain_artifacts-id = assert lib.elem "rain_artifacts" unmanagedBuckets;
            lib.trim ''
              ''${one([for bucket in data.awscc_s3_buckets.this.ids : bucket if length(regexall("rain-artifacts-\\d{12}-${infra.aws.region}", bucket)) > 0])}
            '';
        };

        resource = {
          aws_s3_bucket_policy = lib.genAttrs unmanagedBuckets (name: {
            bucket = "\${local.aws_s3_bucket-${name}-id}";
            policy = "\${data.aws_iam_policy_document.s3_bucket_policy-${name}.minified_json}";
          });

          aws_s3_bucket_versioning = lib.genAttrs unmanagedBuckets (name: {
            bucket = "\${local.aws_s3_bucket-${name}-id}";
            versioning_configuration.status = "Enabled";
          });
        };
      }

      # This creates the AMI for our EC2 instances.
      # It is done here in the bootstrap workspace
      # to avoid slowing down evaluation of the other workspaces
      # because we change them much more frequently.
      {
        data = {
          external."ami_nixos_${system}".program = [
            "nu"
            "--commands"
            ''
              $'(
                nix build
                --out-link .terraform/ami_nixos_${system}
                --print-out-paths
                .#packages.${system}.ami
              )/nix-support/image-info.json'
              | open
              | insert disk_root $in.disks.root.file
              | insert disk_boot $in.disks.boot.file
              | insert disk_root_basename ($in.disks.root.file | path basename)
              | insert disk_boot_basename ($in.disks.boot.file | path basename)
              | reject disks
              | to json
            ''
          ];

          aws_iam_policy_document = {
            kms_key-amis.statement = {
              effect = "Allow";
              actions = ["kms:*"];
              principals = {
                type = "AWS";
                identifiers = ["arn:aws:iam::${infra.aws.orgId}:root"];
              };
              resources = ["*"];
              sid = "Enable admin use and IAM user permissions";
            };

            s3_bucket_policy-amis.statement = bucketPolicyStatementSecureTransport "\${aws_s3_bucket.amis.arn}";

            iam_role-vmimport.statement = {
              effect = "Allow";
              actions = ["sts:AssumeRole"];
              principals = {
                type = "Service";
                identifiers = ["vmie.amazonaws.com"];
              };
              condition = {
                test = "StringEquals";
                variable = "sts:ExternalId";
                values = ["vmimport"];
              };
            };

            iam_role_policy-vmimport.statement = [
              {
                effect = "Allow";
                actions = [
                  "s3:GetBucketLocation"
                  "s3:GetObject"
                  "s3:ListBucket"
                ];
                resources = [
                  "\${aws_s3_bucket.amis.arn}"
                  "\${aws_s3_bucket.amis.arn}/*"
                ];
              }
              {
                effect = "Allow";
                actions = [
                  "ec2:ModifySnapshotAttribute"
                  "ec2:CopySnapshot"
                  "ec2:RegisterImage"
                  "ec2:Describe*"
                ];
                resources = ["*"];
              }
              {
                effect = "Allow";
                actions = [
                  "kms:CreateGrant"
                  "kms:Decrypt"
                  "kms:DescribeKey"
                  "kms:Encrypt"
                  "kms:GenerateDataKey*"
                  "kms:ReEncrypt*"
                ];
                resources = ["*"];
              }
            ];
          };
        };

        resource = {
          # KMS keys for AMI encryption in all regions
          aws_kms_key =
            {
              amis = {
                provider = awsProviderFor infra.aws.region;
                description = "Key to encrypt AMIs with";
                enable_key_rotation = true;
                policy = "\${data.aws_iam_policy_document.kms_key-amis.minified_json}";
              };
            }
            // lib.listToAttrs (
              lib.forEach
              (lib.filter (r: r != infra.aws.region) (lib.attrNames infra.aws.regions))
              (region:
                lib.nameValuePair "amis_${dashToSnake region}" {
                  provider = awsProviderFor region;
                  description = "Key to encrypt AMIs with in ${region}";
                  enable_key_rotation = true;
                  policy = "\${data.aws_iam_policy_document.kms_key-amis.minified_json}";
                })
            );

          aws_kms_alias =
            {
              amis = {
                provider = awsProviderFor infra.aws.region;
                name = "alias/amis";
                target_key_id = "\${aws_kms_key.amis.id}";
              };
            }
            // lib.listToAttrs (
              lib.forEach
              (lib.filter (r: r != infra.aws.region) (lib.attrNames infra.aws.regions))
              (region:
                lib.nameValuePair "amis_${dashToSnake region}" {
                  provider = awsProviderFor region;
                  name = "alias/amis";
                  target_key_id = "\${aws_kms_key.amis_${dashToSnake region}.id}";
                })
            );

          aws_ami."nixos_${system}" = rec {
            provider = awsProviderFor infra.aws.region;
            name = "NixOS/${tags.system}/${tags.version}";
            virtualization_type = "hvm";
            architecture = lib.trim ''
              ''${
                {
                  "i386" = "i386",
                  "x86_64" = "x86_64",
                  "aarch64" = "arm64",
                }[one(slice(split("-", "${tags.system}"), 0, 1))]
              }''${
                lookup(
                  {"darwin" = "_mac"},
                  one(slice(reverse(split("-", "${tags.system}")), 0, 1)),
                  ""
                )
              }
            '';
            boot_mode = "\${data.external.ami_nixos_${system}.result.boot_mode}";
            root_device_name = "/dev/xvda";
            ena_support = true;
            imds_support = "v2.0";
            ebs_block_device = [
              {
                device_name = "/dev/xvda";
                snapshot_id = "\${aws_ebs_snapshot_import.ami_nixos_${system}_root.id}";
              }
              {
                device_name = "/dev/xvdb";
                snapshot_id = "\${aws_ebs_snapshot_import.ami_nixos_${system}_boot.id}";
              }
            ];
            tags = {
              system = "\${data.external.ami_nixos_${system}.result.system}";
              version = "\${data.external.ami_nixos_${system}.result.label}";
            };
          };

          # Copy AMI to all other regions
          aws_ami_copy = lib.listToAttrs (
            lib.forEach
            (lib.filter (r: r != infra.aws.region) (lib.attrNames infra.aws.regions))
            (region:
              lib.nameValuePair "nixos_${system}_${dashToSnake region}" {
                provider = awsProviderFor region;
                name = "NixOS/\${aws_ami.nixos_${system}.tags.system}/\${aws_ami.nixos_${system}.tags.version}";
                source_ami_id = "\${aws_ami.nixos_${system}.id}";
                source_ami_region = infra.aws.region;
                encrypted = true;
                kms_key_id = "\${aws_kms_key.amis_${dashToSnake region}.arn}";
                tags = {
                  system = "\${aws_ami.nixos_${system}.tags.system}";
                  version = "\${aws_ami.nixos_${system}.tags.version}";
                  source_region = infra.aws.region;
                };
              })
          );

          aws_ebs_snapshot_import = lib.listToAttrs (
            lib.forEach ["root" "boot"] (
              name:
                lib.nameValuePair "ami_nixos_${system}_${name}" {
                  provider = awsProviderFor infra.aws.region;
                  disk_container = {
                    format = "VHD";
                    user_bucket = {
                      s3_bucket = "\${aws_s3_bucket.amis.id}";
                      s3_key = "\${aws_s3_object.ami_nixos_${system}_${name}.key}";
                    };
                  };
                  role_name = "\${aws_iam_role.vmimport.name}";
                  encrypted = true;
                  kms_key_id = "\${aws_kms_key.amis.arn}";
                  tags = {
                    Name = "ami_nixos_${system}_${name}";
                    inherit system;
                    disk = name;
                  };

                  lifecycle.replace_triggered_by = [
                    "aws_s3_object.ami_nixos_${system}_${name}.source"
                  ];
                }
            )
          );

          aws_s3_bucket.amis = {
            provider = awsProviderFor infra.aws.region;
            bucket = "${infra.aws.profile}-amis";
            force_destroy = true;
          };

          aws_s3_bucket_server_side_encryption_configuration.amis = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.amis.id}";
            rule.apply_server_side_encryption_by_default = {
              sse_algorithm = "aws:kms";
              kms_master_key_id = "\${aws_kms_key.amis.id}";
            };
          };

          aws_s3_bucket_policy.amis = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.amis.id}";
            policy = "\${data.aws_iam_policy_document.s3_bucket_policy-amis.minified_json}";
          };

          aws_s3_object = lib.listToAttrs (
            lib.forEach ["root" "boot"] (
              name:
                lib.nameValuePair "ami_nixos_${system}_${name}" {
                  provider = awsProviderFor infra.aws.region;
                  bucket = "\${aws_s3_bucket.amis.id}";
                  key = "\${data.external.ami_nixos_${system}.result.disk_${name}_basename}";
                  source = "\${data.external.ami_nixos_${system}.result.disk_${name}}";
                }
            )
          );

          aws_s3_bucket_logging =
            {
              amis = {
                provider = awsProviderFor infra.aws.region;
                bucket = "\${aws_s3_bucket.amis.id}";
                target_bucket = with infra.aws; "s3-server-access-logs-${orgId}-${region}";
                target_prefix = "logs/";
                target_object_key_format.partitioned_prefix.partition_date_source = "EventTime";
              };
            }
            // lib.listToAttrs (
              lib.forEach unmanagedBuckets (
                name:
                  lib.nameValuePair name {
                    provider = awsProviderFor infra.aws.region;
                    bucket = "\${local.aws_s3_bucket-${name}-id}";
                    target_bucket = with infra.aws; "s3-server-access-logs-${orgId}-${region}";
                    target_prefix = "logs/";
                    target_object_key_format.partitioned_prefix.partition_date_source = "EventTime";
                  }
              )
            );

          aws_s3_bucket_versioning.amis = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.amis.id}";
            versioning_configuration.status = "Enabled";
          };

          aws_iam_role.vmimport = rec {
            provider = awsProviderFor infra.aws.region;
            name = "vmimport";
            assume_role_policy = "\${data.aws_iam_policy_document.iam_role-${name}.minified_json}";
          };

          # https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html
          aws_iam_role_policy.vmimport = rec {
            provider = awsProviderFor infra.aws.region;
            name = "vmimport";
            role = "\${aws_iam_role.${name}.id}";
            policy = "\${data.aws_iam_policy_document.iam_role_policy-${name}.minified_json}";
          };
        };
      }

      # The metsuke submission archive and the identity that writes to it.
      #
      # An IAM user rather than a role on ec2Profile: metsuke-server takes its
      # credentials from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in its
      # process environment and makes no instance-metadata call, so it cannot
      # assume the instance role. Beads metsuke-4zo.125 in the metsuke repo is
      # the change that would let this become a role.
      {
        data.aws_iam_policy_document = {
          s3_bucket_policy-metsuke.statement =
            bucketPolicyStatementSecureTransport "\${aws_s3_bucket.metsuke.arn}";

          # The server only ever adds an object and reads it back. It never
          # creates a bucket and never deletes an object, so neither appears
          # here.
          iam_user_policy-metsuke.statement = [
            {
              effect = "Allow";
              actions = [
                "s3:GetObject"
                "s3:PutObject"
              ];
              resources = ["\${aws_s3_bucket.metsuke.arn}/*"];
            }
            {
              effect = "Allow";
              actions = ["s3:ListBucket"];
              resources = ["\${aws_s3_bucket.metsuke.arn}"];
            }
            {
              effect = "Allow";
              actions = [
                "kms:Decrypt"
                "kms:DescribeKey"
                "kms:GenerateDataKey"
              ];

              # Scoped the way aws_iam_policy.kms_user in the cluster workspace
              # scopes it: any key the shared alias currently points at.
              resources = ["arn:aws:kms:*:${infra.aws.orgId}:key/*"];
              condition = {
                test = "ForAnyValue:StringLike";
                variable = "kms:ResourceAliases";
                values = ["alias/kmsKey"];
              };
            }
          ];
        };

        resource = {
          # No force_destroy: the archive is the only copy of a submission.
          #
          # Tagged to the leios cost center, overriding the workspace
          # default_tags for this key only. The archive grows with every SPO
          # submission and is the one resource here whose spend is attributable
          # to leios; the AMI and rain buckets are shared by every environment,
          # so they keep the generic cost center. leios1-metsuke-a-1 itself
          # already gets this tag from the group helper in flake/colmena.nix.
          aws_s3_bucket.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "${infra.aws.profile}-metsuke";
            tags.costCenter = "\${var.tag_costCenterLeios}";
          };

          aws_s3_bucket_server_side_encryption_configuration.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.metsuke.id}";
            rule.apply_server_side_encryption_by_default = {
              sse_algorithm = "aws:kms";
              kms_master_key_id = "alias/kmsKey";
            };
          };

          aws_s3_bucket_policy.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.metsuke.id}";
            policy = "\${data.aws_iam_policy_document.s3_bucket_policy-metsuke.minified_json}";
          };

          aws_s3_bucket_versioning.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.metsuke.id}";
            versioning_configuration.status = "Enabled";
          };

          aws_s3_bucket_logging.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.metsuke.id}";
            target_bucket = with infra.aws; "s3-server-access-logs-${orgId}-${region}";
            target_prefix = "logs/";
            target_object_key_format.partitioned_prefix.partition_date_source = "EventTime";
          };

          aws_s3_bucket_public_access_block.metsuke = {
            provider = awsProviderFor infra.aws.region;
            bucket = "\${aws_s3_bucket.metsuke.id}";
            block_public_acls = true;
            block_public_policy = true;
            ignore_public_acls = true;
            restrict_public_buckets = true;
          };

          # No spend of its own, tagged so the identity is attributed with the
          # bucket it writes to.
          aws_iam_user.metsuke = {
            provider = awsProviderFor infra.aws.region;
            name = "metsuke";
            tags.costCenter = "\${var.tag_costCenterLeios}";
          };

          aws_iam_user_policy.metsuke = {
            provider = awsProviderFor infra.aws.region;
            name = "metsuke";
            user = "\${aws_iam_user.metsuke.name}";
            policy = "\${data.aws_iam_policy_document.iam_user_policy-metsuke.minified_json}";
          };

          # Read out with `just tofu bootstrap output -raw <name>` and put both
          # into the sops EnvironmentFile the metsuke-server module is handed.
          aws_iam_access_key.metsuke = {
            provider = awsProviderFor infra.aws.region;
            user = "\${aws_iam_user.metsuke.name}";
          };
        };

        output = {
          metsuke_access_key_id.value = "\${aws_iam_access_key.metsuke.id}";

          metsuke_secret_access_key = {
            value = "\${aws_iam_access_key.metsuke.secret}";
            sensitive = true;
          };
        };
      }
    ];
  };
}
