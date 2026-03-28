# Kubernetes Cheetsheet

_IMPORTANT: Always be sure you are connected to the right Kubeconfig context! Put it in your prompt, or run `kubectl config get-contexts`._

_HINT: Nearly all `kubectl` subcommands, flags, and even object names tab-complete. Take advantage of this for learning and discovery, as well as ease._

## Cluster Usage
* ArgoCD watches this repo and Continuously Delivers the objects in `k8s/overlays/playground/<app>/*` as configured in the `application.<name>.yaml` files.
    * [argocd.play.dev.cardano.org](https://argocd.play.dev.cardano.org)
    * We purposely do not configure ArgoCD to watch/deliver the `application.<name>.yaml` files themselves.
* SDLC
    * [Pause ArgoCD auto delivery](#pause-argocd-auto-delivery)
    * First diff it to see what you'll be changing:
        * `kustomize build --enable-alpha-plugins k8s/overlays/playground/<app> | kubectl diff -f -`
    * Apply the changes:
        * `kustomize build --enable-alpha-plugins k8s/overlays/playground/<app> | kubectl apply -f -`
    * Commit/push your changes, merge to `main`
    * Reenable ArgoCD auto delivery

## Terminology
* The persistent entities we manipulate in Kubernetes are called Objects. The YAML files we manipulate typically represent one object each.
* GVK + Name and Namespace:
    * These are the five things that make an Object unique in the cluster. - Together they are functionally equivalent to a UUID.
        * The GroupVersionKind
            * The Group + Version is also called the APIVersion. E.G. `rbac.authorization.k8s.io/v1`, or `v1`, or even `""` for core resource types.
            * The Kind == the object's Kind. E.G. `Service`, `Deployment`, etc.
        * The metadata Name + Namespace

## File naming, Object naming, and other conventions
* A common mistake is to name objects with their Kind in the name, but it's unnecessary and redundant. We never see objects without knowing their Kind.
    * For example, instead of `mdbook-service` and `mdbook-deployment`, simply use `mdbook` for both.
* The file naming convention we've chosen is `<object_kind>.<object_name>.yaml`.
    * Each file should contain one and only one Object.
* It's very helpful over time to see Object keys in the same order across objects.
    * For example putting `name` first in the list of keys that define a `container` in the `containers` list in a `Deployment`.
    * TODO: To this end we use `predictable-yaml` as a linter and fixer.
        * Recommend `git add`ing your changes first
        * `predictable-yaml fix k8s`
        * Check the results for TODOs
            * Use `# predictable-yaml: ignore-requireds` at the top of patch files.

## Cluster and ECR Administration
* `just tofu k8s apply`
* `just tofu ecr apply`
* Get the Kubeconfig credentials to connect to the cluster with Kubectl and other tools:
    * `aws eks update-kubeconfig --region eu-central-1 --name playground-1 --alias playground-1`
        * The tofu output also displays this command.

## Pause ArgoCD Auto Delivery
* You can either:
    * Go to the UI, uncheck TODO
    * Comment out the entire `syncPolicy` section in the `application.<name>.yaml` file and kubectl apply it.

## General notes
* There exists an ArgoCD CLI but we have no use for it as we don't use ArgoCD imperatively.
* Why use ArgoCD if in practice we first pause it, apply changes manually, then have it deliver nothing?
    * We benefit from knowing applications are currently synced. A colleague could have deployed changes from their own unmerged branch.
        * It's a central point of coordination.
    * We can fully automate delivery using CI for some applications, even though we don't have that yet.
        * Imagine: CI builds a new container image for something, then bumps the tags for it right in the `main` branch or in an auto merged PR. ArgoCD then delivers it.
