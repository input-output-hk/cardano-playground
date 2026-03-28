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

  # convert repository names to Terraform resource IDs
  repoToId = repoName: replaceStrings ["/"] ["_"] repoName;

  ecrConfig = {
    region = "eu-central-1";
    # To add a new container image repo: add to this list and run `just tofu ecr apply`
    repositories = [
      # "playground/example-app"
      "argocd"
    ];
  };

  sensitiveString = {
    type = "string";
    sensitive = true;
    nullable = false;
  };

  # Tags for ECR resources
  defaultTags = {
    inherit (infra.generic) organization owner project repo;
    costCenter = "\${var.${infra.generic.costCenter}}";
    environment = "playground";
    function = "container-registry";
    tribe = "sre";
  };
in {
  flake.opentofu.ecr = inputs.cardano-parts.inputs.terranix.lib.terranixConfiguration {
    inherit system;
    modules = [
      {
        terraform = {
          required_providers = {
            aws.source = "opentofu/aws";
          };

          backend = {
            s3 = {
              inherit (cluster) region;
              bucket = cluster.bucketName;
              key = "terraform-ecr";
              dynamodb_table = "terraform";
            };
          };
        };

        variable = {
          "${infra.generic.costCenter}" = sensitiveString;
        };

        provider.aws = {
          inherit (ecrConfig) region;
          alias = replaceStrings ["-"] ["_"] ecrConfig.region;
          default_tags.tags = defaultTags;
        };

        resource = {
          # Create ECR repositories
          aws_ecr_repository = listToAttrs (map (repoName: {
              name = repoToId repoName;
              value = {
                name = repoName;
                image_tag_mutability = "MUTABLE";
                image_scanning_configuration.scan_on_push = false;
                encryption_configuration.encryption_type = "AES256";
                tags = defaultTags;
              };
            })
            ecrConfig.repositories);

          # Lifecycle policy to cleanup old images
          aws_ecr_lifecycle_policy = listToAttrs (map (repoName: {
              name = repoToId repoName;
              value = {
                repository = repoName;
                policy = toJSON {
                  rules = [
                    {
                      rulePriority = 1;
                      description = "Delete untagged images after 7 days";
                      selection = {
                        tagStatus = "untagged";
                        countType = "sinceImagePushed";
                        countUnit = "days";
                        countNumber = 7;
                      };
                      action = {
                        type = "expire";
                      };
                    }
                  ];
                };
                depends_on = ["aws_ecr_repository.${repoToId repoName}"];
              };
            })
            ecrConfig.repositories);
        };

        output =
          # Generate individual outputs for each repository
          (listToAttrs (map (repoName: {
              name = "${repoToId repoName}_url";
              value = {
                description = "ECR repository URL for ${repoName}";
                value = "\${aws_ecr_repository.${repoToId repoName}.repository_url}";
              };
            })
            ecrConfig.repositories))
          // {
            repository_urls = {
              description = "All ECR repository URLs";
              value = "{${concatStringsSep ", " (map (repoName: "${repoName} = \${aws_ecr_repository.${repoToId repoName}.repository_url}") ecrConfig.repositories)}}";
            };

            registry_id = {
              description = "ECR registry ID (AWS account ID)";
              value = "\${aws_ecr_repository.${repoToId (head ecrConfig.repositories)}.registry_id}";
            };
          };
      }
    ];
  };
}
