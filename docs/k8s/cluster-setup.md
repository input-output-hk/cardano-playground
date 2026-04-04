# Bootstrap the cluster

1. Create and connect to the cluster
    * `just tofu k8s apply`
    * `aws eks update-kubeconfig --region eu-central-1 --name playground-1 --alias playground-1`
1. Setup Elastic Container Registry
    * `just tofu ecr apply`
1. Build and push images
    * `just release-image argocd` - and other images
1. Deploy ArgoCD
    * Server-Side apply is required here because otherwise kubectl tries to add the `last-applied-configuration` annotation, and for the AppProject CRD it exceeds the annotation size limit.
    * `kustomize build k8s/overlays/playground/argocd/ | kubectl --context playground-1 apply --server-side -f -`
    * After ArgoCD is up and running, have it start managing itself
    * `kubectl apply -f k8s/overlays/playground/application.argocd.yaml`
1. Deploy Cert Manager
    * `kubectl apply -f k8s/overlays/playground/application.cert-manager.yaml`
1. Deploy ALB Controller
    * `kubectl apply -f k8s/overlays/playground/application.aws-lbc.yaml`
1. Deploy External DNS
    * `kubectl apply -f k8s/overlays/playground/application.external-dns.yaml`
1. Deploy any remaining apps
    * `kubectl apply -f k8s/overlays/playground/application.<name>.yaml`
