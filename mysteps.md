connecting to my vault aks cluster

``` bash
az aks get-credentials --resource-group vault --name vault
```

then creating a namespace and installing vault into that namespace

``` bash
kubectl create namespace demo
kubectl config set-context --current --namespace=demo

helm install vault \
       --set='server.dev.enabled=true' \
       ./vault-helm
```

Now that we have an install of vault running in the cluster it is time to [test out the sidecar pattern of secrets injection](https://www.hashicorp.com/blog/injecting-vault-secrets-into-kubernetes-pods-via-a-sidecar/)

next connect to vault and configure a policy in it

``` bash
kubectl exec -ti vault-0 /bin/sh
```

### Inside the vault container command line

now inside the container make the policy

``` bash
cat <<EOF > /home/vault/app-policy.hcl
path "secret*" {
  capabilities = ["read"]
}
EOF

vault policy write app /home/vault/app-policy.hcl
```

should get `Success! Uploaded policy: app`

Next enable the kubernetes plugin

``` bash
vault auth enable kubernetes

vault write auth/kubernetes/config \
   token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
   kubernetes_host=https://${KUBERNETES_PORT_443_TCP_ADDR}:443 \
   kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault write auth/kubernetes/role/myapp \
   bound_service_account_names=app \
   bound_service_account_namespaces=demo \
   policies=app \
   ttl=1h
```

Should get 1 success messages after each command resulting in a total of 3.

Next create a secret we will extract later

``` bash
vault kv put secret/helloworld username=foobaruser password=foobarbazpass
```

exit the container

``` bash
exit

```

### Back on your local console

Create a sample app and service account that can access the vault secret.

``` bash
kubectl create -f app.yaml
```

Then test to make sure the secrets aren't mounted

``` bash
kubectl exec -ti app-668b8bcdb9-kjw6x -c app -- ls -l /vault/secrets
```

you should get
```
ls: /vault/secrets: No such file or directory
command terminated with exit code 1
```

Next we apply the annotation patch

``` bash
kubectl patch deployment app --patch "$(cat patch-basic-annotations.yaml)"
kubectl exec -ti app-7c8b7df457-6pptd -c app -- cat /vault/secrets/helloworld
```

Now you can see the secrets! it works!

### Installing standalone mode vault

With no params it will install in standalone mode. Can't have another vault install in the cluster or else the injection part will cause an issue.

``` bash
kubectl create namespace standalone
kubectl config set-context --current --namespace=standalone

helm install vault \
       ./vault-helm
```

`This step took 15 or so minutes on my 1 node cluster to go from container creating to running.`

Check the status of vault by running vault status in the pod

``` bash
kubectl exec -it vault-0 -- vault status
```

It should say that it is not initialized, and is sealed. To unseal it manually.

``` bash
kubectl exec -it vault-0 -- vault operator init -n 1 -t 1
```

should pop up with an unseal key. if it doesn't then vault might be in auto unseal mode. in the values.yaml you can update it to false to redo this.

``` bash
kubectl exec -it vault-0 -- vault operator unseal <unseal key>
```

### Trying for highly available

Using arthur's cluster for size

``` bash
az aks get-credentials --resource-group awdresourcegroup --name awdakscluster
```

adding a namespace and changing a setting
``` bash
kubectl create namespace vault
kubectl config set-context --current --namespace=vault
```

For highly available you need a backend for data and for that we can use consul

``` bash
helm install consul ./consul-helm
```

Then wait for the server- pods to be running. it took 5 mins for all the volumes to mount correctly for me.

Now install vault in high availability mode

``` bash
helm install vault ./vault-helm --set='server.ha.enabled=true'
```

now check vault status

``` bash
kubectl exec -it vault-0 -- vault status
```

you can then initialize it

``` bash
kubectl exec -it vault-0 -- vault operator init -n 1 -t 1
```

you can then unseal it

``` bash
kubectl exec -it vault-0 -- vault operator unseal dYQFtB2DaPGR05oPujEdQMDBVlaSn//SDULOYfnAGbA=
```

Then it should be unsealed, but that will just initalize and unseal that one instance. Not very practical. wolud have to unseal all manually, and then unseal if they die.

let's try again with auto-unseal

[delete all the data in consul](https://dev.to/v6/how-to-reset-a-hashicorp-vault-back-to-zero-state-using-consul-ae) and then delete the releases for consul and vault.

``` bash
kubectl exec -it consul-consul-<oneoftheids> -- consul kv delete -recurse vault/
helm delete consul
helm delete vault
```
##### Setting up auto unseal

Auto unseal is a nice feature that [makes all the vault pods auto unseal](https://www.hashicorp.com/resources/azure-friday-azure-key-vault-auto-unseal-and-dynamic) as pods restart and are recreated you don't have to manually unseal each one.

adding a namespace and changing a setting
``` bash
kubectl create namespace vaultha
kubectl config set-context --current --namespace=vaultha
```

start creating consul cause that can take a while (15 mins was normal for me)

``` bash
helm install consul ./consul-helm
```

first we need an account that will have permissions, this will [create a service principal with a secret](https://www.terraform.io/docs/providers/azurerm/guides/service_principal_client_secret.html)

``` bash
az ad sp create-for-rbac --role="Contributor" --scopes="/subscriptions/$ARM_SUBSCRIPTION_ID"
```

take that:

``` bash
{
  "appId": "29fa5293-1b16-4d4f-99f0-edb62d543f05",
  "displayName": "azure-cli-2020-02-09-05-01-15",
  "name": "http://azure-cli-2020-02-09-05-01-15",
  "password": "6a77265d-a0a7-4651-9746-38d87a8dcd44",
  "tenant": "9ca75128-a244-4596-877b-f24828e476e2"
}
```

app id is client id
password is client secret

now populate those in the cli
and update the auto-unseal-terraform/terraform.tfvars
and export them to your shell 

``` bash
export ARM_TENANT_ID="9ca75128-a244-4596-877b-f24828e476e2"
export ARM_CLIENT_ID="29fa5293-1b16-4d4f-99f0-edb62d543f05"
export ARM_CLIENT_SECRET="6a77265d-a0a7-4651-9746-38d87a8dcd44"
export ARM_SUBSCRIPTION_ID="9d893f69-37bd-4f82-9058-3edfd9af9796"
```

I think it actually uses the shell and not the vars...

Next thing is to update the resource group in the terraform code to be the resource group created by your aks cluster, it should start wth 'MC_'

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

Then you need to initalize the vault since it is brand new.

``` bash
helm install vault ./vault-helm --set='server.ha.enabled=true'
```

get status again

``` bash
kubectl exec -it vault-0 -- vault status
```

should say initialized is false again

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
```

you can then initialize it

``` bash
kubectl exec -it vault-0 -- vault operator init -n 1 -t 1
```

you should then get this output instead

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

Which means you don't have to unseal it! 

and the pods should all say ready now! 1/1 and you didn't have to unseal each one individually!

``` bash
consul-consul-jf6p4                     1/1     Running   0          9h
consul-consul-server-0                  1/1     Running   0          9h
consul-consul-server-1                  1/1     Running   0          9h
consul-consul-server-2                  1/1     Running   0          9h
consul-consul-tmjrc                     1/1     Running   0          9h
consul-consul-xd92b                     1/1     Running   0          9h
vault-0                                 1/1     Running   0          2m52s
vault-1                                 1/1     Running   0          2m52s
vault-agent-injector-5959ccc54d-4ktwq   1/1     Running   0          2m52s
```

now we can configure vault again and test it out! 
First thing since this isn't dev mode you have to pass a token. The simplist way is to tkae the initial root token from the init part of the vault setup process and export it to the VAULT_TOKEN env var.

``` bash
kubectl exec -ti vault-0 /bin/sh
```

### Inside the vault container command line

``` bash
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU
```

now make the policy

``` bash
cat <<EOF > /home/vault/app-policy.hcl
path "secret*" {
  capabilities = ["read"]
}
EOF

vault policy write app /home/vault/app-policy.hcl
```

and you should get `Success! Uploaded policy: app`

`note` if you get an error for authentication, make sure your token is in the **VAULT_TOKEN** step from above.

Next enable the kubernetes plugin

``` bash
vault auth enable kubernetes

vault write auth/kubernetes/config \
   token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
   kubernetes_host=https://${KUBERNETES_PORT_443_TCP_ADDR}:443 \
   kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault write auth/kubernetes/role/myapp \
   bound_service_account_names=app \
   bound_service_account_namespaces=vaultha \
   policies=app \
   ttl=1h
```

Should get 1 success messages after each command resulting in a total of 3.

Next create a secret we will extract later

``` bash
vault kv put secret/helloworld username=foobaruser password=foobarbazpass
```

if you get a 403, then you might [not have the secret path setup](https://stackoverflow.com/questions/54312213/hashicorp-vault-cli-return-403-when-trying-to-use-kv) then set up the secret engine and try again

to fix that enable the secret path for secret

``` bash
vault secrets enable -path=secret -version=2 kv
```

exit the pod

``` bash
exit
```

### Back on your local console

Create a sample app and service account that can access the vault secret.

``` bash
kubectl create -f app.yaml
```

Then test to make sure the secrets aren't mounted

``` bash
kubectl exec -ti app-668b8bcdb9-kd9zg -c app -- ls -l /vault/secrets
```

you should get
```
ls: /vault/secrets: No such file or directory
command terminated with exit code 1
```

Next we apply the annotation patch

``` bash
kubectl patch deployment app --patch "$(cat patch-basic-annotations.yaml)"
```

After that find the pods name again, should be 2/2

``` bash
kubectl exec -ti app-7c8b7df457-6pptd -c app -- cat /vault/secrets/helloworld
```

Now you can see the secrets! it works!

`note` if you get a 0/2 init that won't go to running, check the namespace of the policy in vault. If it isn't correct then re-create the policy.

```bash
kubectl exec -ti vault-0 /bin/sh
```

in the container:

``` bash
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU

vault write auth/kubernetes/role/myapp \
   bound_service_account_names=app \
   bound_service_account_namespaces=vaultha \
   policies=app \
   ttl=1h
```

Then retry deploying the app and patching it.

``` bash
kubectl delete -f app.yaml
kubectl create -f app.yaml
kubectl patch deployment app --patch "$(cat patch-basic-annotations.yaml)"
```

Now you can read the secrets.

Now if you want to deploy a container pod with secrets injecteded the first time, you can deploy the basic-app.yaml

``` bash
kubectl apply -f basic-app.yaml
```

and you should see it instantly start with 2/2 and have the secrets attached.

### Apply a template and output as file

you can add a go template to the secret pattern to create things like connection strings.

``` bash
kubectl apply -f template-inject-app.yaml
```

then to get the secret do

``` bash
kubectl exec app-844d7fb675-f6nbx --container app -- ls -alr
kubectl exec app-844d7fb675-f6nbx --container app -- cat /vault/secrets/database-config.txt

kubectl exec -ti app-5d66dd97f8-77n77 -c app -- ls -l /vault/secrets
kubectl exec -ti app-5d66dd97f8-77n77 -c app -- cat /vault/secrets/helloworld
```

`note` if this doesn't work, and you can't read the secret and it says it doesn't exist. The vault key vaule engine might be version 1, but for this to work it needs to be version 2.

To [upgrade to version two](https://www.vaultproject.io/docs/secrets/kv/kv-v2/) connect to the vault pod and update the engine

``` bash
kubectl exec -ti vault-0 /bin/sh
```

### Inside the vault container command line

``` bash
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU

vault kv enable-versioning secret/
```

you should be able to set a secret and get some metadata around it as a return.

``` bash
$ vault kv put secret/my-secret my-value=s3cr3t
Key              Value
---              -----
created_time     2019-06-19T17:20:22.985303Z
deletion_time    n/a
destroyed        false
version          1
```

Then when you read it, instead of just the key vaule pairs, you will get the metadata as well.

``` bash
$ vault kv get secret/my-secret
====== Metadata ======
Key              Value
---              -----
created_time     2019-06-19T17:20:22.985303Z
deletion_time    n/a
destroyed        false
version          1

====== Data ======
Key         Value
---         -----
my-value    s3cr3t
```

now if you try to get the secret for the helloworld entry we are going for, you will get the metadata as well.

``` bash
$ vault kv get secret/helloworld
====== Metadata ======
Key              Value
---              -----
created_time     2020-02-09T17:27:51.575351178Z
deletion_time    n/a
destroyed        false
version          1

====== Data ======
Key         Value
---         -----
password    foobarbazpass
username    foobaruser
```

exit the container, and let's try again.

``` bash
exit
```

### outside again

Now delete any apps that you have deplopyed

``` bash
kubectl delete -f app.yaml
```

and recreate the basic annotations version.

``` bash
kubectl apply -f basic-app.yaml
```

now once it is ready, read the secrets again

``` bash
kubectl exec -ti app-7c8b7df457-fnrzs -c app -- cat /vault/secrets/helloworld

data: map[password:foobarbazpass username:foobaruser]
metadata: map[created_time:2020-02-09T17:27:51.575351178Z deletion_time: destroyed:false version:1]
```

it should now return a data and metadata set of golang maps. NOW we can actually get the template to work.

``` bash
kubectl patch deployment app --patch "$(cat patch-template-annotations.yaml)"


kubectl exec -ti app-5d66dd97f8-67bgv -c app -- cat /vault/secrets/helloworld
```

Now we should finally get the url we want based on the template!

``` bash
postgresql://foobaruser:foobarbazpass@postgres:5432/wizard
```

### Creating the secret at a specific filepath

Now we can create the secret at a particular filepath.

delete what we had before

``` bash
kubectl delete -f app.yaml
```

now create the new file template inject deployment

``` bash
kubectl apply -f file-template-app.yaml
```

find the new pod and look for the secrets

``` bash
kubectl exec -it app-844d7fb675-9k589 -c app -- cat /vault/secrets/database-config.txt
```

and you should get a nice conenction string from that config file.

`postgresql://foobaruser:foobarbazpass@postgres:5432/wizard`

Now that container can read that file for the creds it needs.

### Create a app outside the namespace

Secrets are bound to roles and namespaces. If the pod service account role is not linked to the pod and in the correct namespace it won't work. Lets move that app to a different namespace and see what we have to do to get a new secret.

create a new namespace

``` bash
kubectl create namespace offsite
kubectl config set-context --current --namespace offsite
```

we can test that the cross namespace won't work by applying the old template.

``` bash
kubectl apply -f file-template-app.yaml
```

now if you look at the pods it will never start, and always be in init:0/1

```
NAME                   READY   STATUS     RESTARTS   AGE
app-844d7fb675-2h2pm   0/2     Init:0/1   0          5s
```

you can check the logs of the vault secret grabbing container to see what is going on.

``` bash
kubectl logs app-844d7fb675-2h2pm --container vault-agent-init
```

with this error message

``` bash
URL: PUT http://vault.vaultha.svc:8200/v1/auth/kubernetes/login
Code: 500. Errors:

* namespace not authorized" backoff=2.67051515
2020-02-09T17:58:22.639Z [INFO]  auth.handler: authenticating
2020-02-09T17:58:22.646Z [ERROR] auth.handler: error authenticating: error="Error making API request.
```

so, lets add a role for this namespace so that the secret is authorized to be grabbed here.

```bash
kubectl exec --namespace vaultha -ti vault-0 /bin/sh
```
`note` you have to include the namespace of the vault installation to exec into it this time, so make sure that `vaultha` (vault highly available is why i named it that) is correct for where vault is installed.

then similar to before we are going to do some commands in the container to create a new access namespace:

``` bash
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU

vault write auth/kubernetes/role/myapp \
   bound_service_account_names=app \
   bound_service_account_namespaces=offsite \
   policies=app \
   ttl=1h
```

This is similar to when we created the pod in the first place, but take note we are creating it with a different namespace called `offisite` to match our new namespace.

now exit the vault container
``` bash
exit
```

if you check the pods we now see it is read 2/2

``` bash
kubectl get pods
```

``` bash
NAME                   READY   STATUS    RESTARTS   AGE
app-844d7fb675-2h2pm   2/2     Running   0          7m45s
```

and we can read the secret again

``` bash
kubectl exec -it app-844d7fb675-2h2pm -c app -- cat /vault/secrets/database-config.txt

postgresql://foobaruser:foobarbazpass@postgres:5432/wizard
```

there is no newline at the end of the secret so it may display funny in your terminal, and have your username/path at the end, but that is just a visual thing with the terminal.


### Creating a new secret and new app

now we have used the same secret and app, so lets change things up a bit. First we can create the secret in vault. Lets stay in the new `offsite` namespace just to keep things interesting.

``` bash
kubectl exec --namespace vaultha -ti vault-0 /bin/sh
```

#### inside the vault container
in the container add the root token so we have access to make changes

``` bash
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU
``` 

then we will [create a new policy](https://www.vaultproject.io/docs/commands/policy/write/) that has access to just our app's path for dev environment

``` bash
cat <<EOF > /home/vault/app2dev-policy.hcl
path "secret/app2/dev*" {
  capabilities = ["read"]
}
EOF

vault policy write app2dev /home/vault/app2dev-policy.hcl
```

this will create a file called app2-dev-policy.hcl which gives the rights to read any secret under `secret/app2/dev` path and the policy is named `app2dev`

Now we need to create an auth role for that policy. we will use the kubernetes service account called `svcapp2dev` in the `offisite` kubernetes namespace and map it to the `app2dev` policy we just created with a time to live of 1 hour. We will call this role in vault `vapp2dev`

``` bash
vault write auth/kubernetes/role/vapp2dev \
   bound_service_account_names=svcapp2dev \
   bound_service_account_namespaces=demo \
   policies=app2dev \
   ttl=1h
```

Now we can create the new secret that would be the postgres creds for the dev postgres instance.

``` bash
vault kv put secret/app2/dev/helloapp2 username=postuser password=postpass
```

Now we should have permissions setup, and a secret to retrieve, so exit the vault container

``` bash
exit
```

So it is easier to see the changes I will create a deployment for app2 with the app information, so the next ref will show what has to change much easier.

Now deploy file-template-app2.yaml

if something goes wrong and it won't init you can check what is going on with

``` bash
kubectl logs app2-788dffc98-nkznd --container vault-agent-init
```
and can see:

``` bash
URL: PUT http://vault.vaultha.svc:8200/v1/auth/kubernetes/login
Code: 500. Errors:

* namespace not authorized" backoff=1.6315050869999999
```

because in the original policy I created the namespace was still `demo`

Now to fix that back to the vault pod

``` bash
kubectl exec --namespace vaultha -ti vault-0 /bin/sh

# in the container
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU

vault write auth/kubernetes/role/vapp2dev \
   bound_service_account_names=svcapp2dev \
   bound_service_account_namespaces=offsite \
   policies=app2dev \
   ttl=1h

# back out of the container
exit
```

still not working?

``` bash
2020/02/09 18:32:52.012491 [WARN] (view) vault.read(secret/app2/dev/helloapp2): vault.read(secret/app2/dev/helloapp2): Error making API request.

URL: GET http://vault.vaultha.svc:8200/v1/secret/data/app2/dev/helloapp2
Code: 403. Errors:

* 1 error occurred:
        * permission denied
```

so it is not getting permissions to the secret we need. Maybe I made the policy wrong.

And I did. because in [vault v2](https://www.vaultproject.io/docs/secrets/kv/kv-v2/) you have to append that data part to the path.

Back to vaultha!

``` bash
kubectl exec --namespace vaultha -ti vault-0 /bin/sh

# in the container
export VAULT_TOKEN=s.Efn0BeHPNDQgb1gyxWiUB3NU

cat <<EOF > /home/vault/app2dev-policy.hcl
path "secret/data/app2/dev*" {
  capabilities = ["read"]
}
EOF

vault policy write app2dev /home/vault/app2dev-policy.hcl

exit
```

now we get the 2/2! 

``` bash
kubectl get pods
```

``` bash
NAME                   READY   STATUS    RESTARTS   AGE
app-844d7fb675-2h2pm   2/2     Running   0          43m
app2-788dffc98-nkznd   2/2     Running   0          11m
```

and let's see if we get the secret still!

``` bash
kubectl exec -it app2-788dffc98-nkznd -c app2 -- cat /vault/secrets/postgres-database-config.txt
```

note updating to the app2 deployment, and updating the container name, as well as the secret file name.

not getting anything, checking for just any secrets.

``` bash
kubectl exec -ti app2-788dffc98-nkznd -c app2 -- ls -l /vault/secrets
```

I forgot to change the correct part of the file path, so template got changed but not the text file location. so this is probably empty or something.

``` bash
kubectl exec -it app2-788dffc98-nkznd -c app2 -- cat /vault/secrets/database-config.txt
```

nope it has the map actually, and the other one doesn't exist. So fixing it so the inject-secret and inject-template are the same.

``` bash
kubectl exec -ti app2-5566569d8b-j6ffw -c app2 -- ls -l /vault/secrets
```

Now the secret exists with the right name.
``` bash
total 4
-rw-r--r--    1 100      1000            51 Feb  9 18:46 postgres-database-config.tx
```

and we can hopefully get hte string correctly?

``` bash
kubectl exec -it app2-5566569d8b-j6ffw -c app2 -- cat /vault/secrets/postgres-database-config.txt
```

and we get the correctly templated secret with the correct information for our new secret!
``` bash
postgresql://postuser:postpass@postgres:5432/wizardrussellboley:vault-scratch russell.boley$
```

That is how to use vault high availaibility in a cluster with different namespaces and add a new secret and auth with service account.