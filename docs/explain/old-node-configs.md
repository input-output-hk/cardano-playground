# Obtaining old node configurations
* Generally, the [Cardano Operations Book](https://book.play.dev.cardano.org)
  will only contain the current release and next pre-release cardano-node
  configurations.

* To obtain an old set of node configuration files, the official node release
  binary of the desired version may already contain the configuration for the
  environment being sought.

* As a first alternative, configs for old node versions can be built from the
  cardano-node repository and the desired version tag using nix with the
  following command where the configs will then be located in the result/
  directory:
  ```bash
  nix build github:IntersectMBO/cardano-node/$VERSION_TAG#hydraJobs.x86_64-linux.cardano-deployment
  ```

* As a second alternative, the configs can be found through hydra if nix isn't
  available, although it requires following the path from the hydra CI required
  job:
  1) Using the URL of the cardano-node tag commit that follows, find the
  `ci/hydra-build:required` GHA job and select `View more details on IOG
  Hydra`:
      ```bash
      https://github.com/IntersectMBO/cardano-node/commits/$VERSION_TAG
      ```

  2) On the hydra navigate to the `cardano-deployment` hydra build:
      ```
      constituents -> x86_64-linux.required -> constituents -> x86.64_linux.cardano-deployment
      ```

  3) This provides a link to `https://ci.iog.io/build/$BUILD_NUM` which has a
  report that provides a download page that configs may be downloaded from:
      ```bash
      https://ci.iog.io/build/$BUILD_NUM/download/1/index.html
      ```

* As a third alternative, node configuration may be generated from the
  cardano-playground repository by running the given command and finding the
  appropriate files at the indicated path.

  * Note that `nix >= 2.17.0` with the following experimental features is
    required:
    ```
    experimental-features = nix-command flakes fetch-closure
    ```

## Version Reference:

* Node `9.2.0`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-9.2.0-config#job-gen-env-config

* Node `9.1.1`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-9.1.1-config#job-gen-env-config
    ```

* Node `9.1.0`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-9.1.0-config#job-gen-env-config
    ```

* Node `9.0.0`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-9.0.0-config#job-gen-env-config
    ```

* Node `8.12.2`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.12.2-config#job-gen-env-config
    ```

* Node `8.11.0-pre`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.11.0-pre-config#job-gen-env-config
    ```

* Node `8.10.1-pre`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.10.1-pre-config#job-gen-env-config
    ```

* Node `8.10.0-pre`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.10.0-pre-config#job-gen-env-config
    ```

* Node `8.9.2`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.9.2-config#job-gen-env-config
    ```

* Node `8.9.1`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.9.1-config#job-gen-env-config
    ```

* Node `8.9.0`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.9.0-config#job-gen-env-config
    ```

* Node `8.8.1-pre`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.8.1-pre-config#job-gen-env-config
    ```

* Node `8.8.0-pre`
  * Environment configs can be found in `result/environments-pre/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.8.0-pre-config#job-gen-env-config
    ```

* Node `8.7.3`
  * Environment configs can be found in `result/environments/config/` after running:
    ```bash
    nix run github:input-output-hk/cardano-playground/node-8.7.3-config#job-gen-env-config
    ```
