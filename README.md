# Install Vault High Availability mode in AKS

First thing I like to do is put this in a namespace by itself. create a new namespace and change context to it.

``` bash
kubectl create namespace vault
kubectl config set-context --current --namespace=vault
```

We are going to run vault high available backed by consul, and installing consul takes like `15 minutes`, so we can start that now using helm

``` bash
helm install consul ./consul-helm
```

Next we need to make sure a service account and azure key vault are setup to enable auto unseal.

## Pre-work setup for auto-unseal

First create a service principal that can be used for this. az ad sp will [create a service principal with a secret](https://www.terraform.io/docs/providers/azurerm/guides/service_principal_client_secret.html)

``` bash
az ad sp create-for-rbac --role="Contributor" --scopes="/subscriptions/$ARM_SUBSCRIPTION_ID"
```

app id is client id
password is client secret

now populate those in the cli
and update the auto-unseal-terraform/terraform.tfvars
and export them to your shell 

``` bash
export ARM_TENANT_ID="<tenant id>"
export ARM_CLIENT_ID="<subscription id>"
export ARM_CLIENT_SECRET="<appId>"
export ARM_SUBSCRIPTION_ID="<password>"
```

Next we are going to use terraform to create the key vault and auto-unseal secret. Before we run this, change the resource group in vars.tf to be the MC_ resource group created by the cluster.

``` t
variable "resource_group" {
  description = "the MC_ resource group created by the aks cluster"
  default = "MC_dev_dev-aks_westus"
}
```

run terraform init/plan/apply in auto-unseal-terraform

``` bash
cd auto-unseal-terraform
terraform init
terraform plan
terraform apply
```

after that update the vault-helm/values.yaml to have the keyvault content

The only thing that should change is the config block for keyvault, but this is where it is in the chart

``` yaml
  ha:
    enabled: false
    replicas: 2

    # config is a raw string of default configuration when using a Stateful
    # deployment. Default is to use a Consul for its HA storage backend.
    # This should be HCL.
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }
      storage "consul" {
        path = "vault"
        address = "HOST_IP:8500"
      }

      # Example configuration for using auto-unseal, using Google Cloud KMS. The
      # GKMS keys must already exist, and the cluster must have a service account
      # that is authorized to access GCP KMS.
      #seal "gcpckms" {
      #   project     = "vault-helm-dev-246514"
      #   region      = "global"
      #   key_ring    = "vault-helm-unseal-kr"
      #   crypto_key  = "vault-helm-unseal-key"
      #}
      seal "azurekeyvault" {
        client_id      = "29fa5293-1b16-4d4f-99f0-edb62d543f05"
        client_secret  = "6a77265d-a0a7-4651-9746-38d87a8dcd44"
        tenant_id      = "9ca75128-a244-4596-877b-f24828e476e2"
        vault_name     = "learn-vault-00e8b23a"
        key_name       = "generated-key"
      }
```

The vault name is outputted from the terraform apply, and the key name is set in the terraform variable defaults.

Next it is time to install Helm

## Installing vault and initializing

to install the chart back out of the terraform directory and run helm install with this parameter added

``` bash
cd ..
helm install vault ./vault-helm --set='server.ha.enabled=true'
```

check for the pods by using

``` bash
kubectl get pods
```

It will take probably around 30 seconds, but you should get all of them running soon.

``` bash
NAME                                    READY   STATUS    RESTARTS   AGE
consul-consul-9w95p                     1/1     Running   0          11h
consul-consul-dxq69                     1/1     Running   0          11h
consul-consul-grcbt                     1/1     Running   0          11h
consul-consul-server-0                  1/1     Running   0          11h
consul-consul-server-1                  1/1     Running   0          11h
consul-consul-server-2                  1/1     Running   0          11h
vault-0                                 0/1     Running   0          35s
vault-1                                 0/1     Running   0          35s
vault-agent-injector-79ff7746cc-ltmgv   1/1     Running   0          35s
```

Next you can check the status of the vault deployment.

``` bash
kubectl exec -it vault-0 -- vault status
```

it should look something like this:

``` bash
Key                      Value
---                      -----
Recovery Seal Type       azurekeyvault
Initialized              false
Sealed                   true
Total Recovery Shares    0
Threshold                0
Unseal Progress          0/0
Unseal Nonce             n/a
Version                  n/a
HA Enabled               true
command terminated with exit code 2
```

Next initialize the vault

``` bash
kubectl exec -it vault-0 -- vault operator init -n 1 -t 1
```

It will output 5 recovery keys, and a root token. Make sure to keep all 6 of those things safe. You won't get them again.

``` bash
Recovery Key 1: Q5BnTLQEfmsCQnkIn7DPeRF522wv8WEpHRo6b4QZdKBc
Recovery Key 2: BhaDhqDUgzfUoxr+GWd2DZwPaL+YY3RlzjsId30sJvML
Recovery Key 3: evvEmE0XGvvbEik6Vp+diFYM0EHo6bOqyRQhg4P9ujoM
Recovery Key 4: R83l+4GxEtx+NqcRpZByiMSFxt6Kpbo4Jrvhb18V2TZC
Recovery Key 5: +londViQiYgylC/QhbHkhtr9ui6imjSEC+Q9YUcs6N1g

Initial Root Token: s.Efn0BeHPNDQgb1gyxWiUB3NU

Success! Vault is initialized

Recovery key initialized with 5 key shares and a key threshold of 3. Please
securely distribute the key shares printed above.

WARNING! -key-shares and -key-threshold is ignored when Auto Unseal is used.
Use -recovery-shares and -recovery-threshold instead.
```

now if you check the pods again they should be running with no need to unseal!

``` bash
NAME                                    READY   STATUS    RESTARTS   AGE
consul-consul-9w95p                     1/1     Running   0          11h
consul-consul-dxq69                     1/1     Running   0          11h
consul-consul-grcbt                     1/1     Running   0          11h
consul-consul-server-0                  1/1     Running   0          11h
consul-consul-server-1                  1/1     Running   0          11h
consul-consul-server-2                  1/1     Running   0          11h
vault-0                                 1/1     Running   0          5m54s
vault-1                                 1/1     Running   0          5m54s
vault-agent-injector-79ff7746cc-ltmgv   1/1     Running   0          5m54s
```

So now vault is installed, and you can start adding policies and secrets to vault.

## Creating the first policy and sample secret

