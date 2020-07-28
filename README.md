# Sample CI/CD Pipeline using Build Service and Concourse

First, let's walk through kpack - what it is and how to use it. 
Then we can implement a CI/CD pipeline and see how to utilize kpack.

What you will need:
 - a kubernetes cluster (I set mine up on GKE)
 - a concourse environment (I just ran Concourse locally)
 - a sample app (you can use this repo or the [Pet Clinic example](https://github.com/spring-projects/spring-petclinic) )

### kpack

Let's start with kpack! You can find the kpack source code [here](https://github.com/pivotal/kpack).

kpack is a tool that provides a declarative image type that builds an image and schedules image rebuilds on relevant Buildpack and source changes.
That might sound intimidating so let's break it down.

1. First, lets install kpack. 
I followed the directions found [here](https://github.com/pivotal/build-service).
Because I am using GKE, my install process looked something like this:
```
# target cluster
gcloud auth configure-docker

docker login dev.registry.pivotal.io

file="$(gsutil ls -l gs://build-service/install | sort -k 2 | tail -n 2 | head -1 | awk '{print $3}' | cut -d '/' -f5)"
gsutil cp "gs://build-service/install/$file" /tmp/

tar xvf "/tmp/$file" -C /tmp

sed 's/newImage: registry/newImage: dev.registry/g' /tmp/images.lock > /tmp/dev-images.lock

kbld relocate -f /tmp/dev-images.lock \
    --repository gcr.io/cf-build-service-dev-219913/test/install \
    --lock-output /tmp/images-relocated.lock

ytt -f /tmp/values.yaml \
    -f /tmp/manifests/ \
    -v docker_repository="gcr.io/cf-build-service-dev-219913/test/install" \
    -v docker_username="_json_key" \
    -v docker_password="$(lpass show --notes "Shared-Build Service/gcp-concourse-service-account-json-key")" \
    | kbld -f /tmp/images-relocated.lock -f- \
    | kapp deploy -a build-service -f- -y```
```

Dont forget we need to supply our own `docker_repository`, `docker_username` and `docker_password`. 

2. Next we have to create a kubernetes Secret. 
This Secret will contain push credentials for the docker registry that we plan on publishing images to with kpack.

```
apiVersion: v1
kind: Secret
metadata:
 name: registry-credentials
 annotations:
   build.pivotal.io/docker: <registry-prefix>
type: kubernetes.io/basic-auth
stringData:
 username: <username>
 password: <password>
```

My secret looks like this:
```
apiVersion: v1
kind: Secret
metadata:
  name: docker-registry-credentials
  annotations:
    build.pivotal.io/docker: https://index.docker.io/v1/
type: kubernetes.io/basic-auth
stringData:
  username: elenorevmware
  password: ((mysecret))
```

If you are using GCR, the registry prefix should be `gcr.io`, and the username can be `_json_key` and the password can be the JSON credentials you get from the GCP UI. 
You can find those under IAM -> Service Accounts, create an account or edit an existing one and create a key with type JSON.

3. Apply the secret to the cluster! 

```
kubectl apply -f secret.yml
```

or, in my case I typed:

```
kubectl apply -f ./resources/dockerRegistryCredentials.yml
```

4. Next we have to create a ServiceAccount that uses our Secret. 

```
apiVersion: v1
kind: ServiceAccount
metadata:
 name: service-account
secrets:
 - name: registry-credentials

```

Make sure to swap out `registry-credentials` for the name defined in the Secret. 
For me, that was `docker-registry-credentials`.
Apply that to the cluster.

```
kubectl apply -f serviceaccount.yml
```

5. Next, we need to create a ClusterBuilder. 
A ClusterBuilder is a reference to a Cloud Native Buildpack builder image. The Builder image contains the Buildpacks used to build images! 
We recommend starting with the `gcr.io/paketo-buildpacks/builder:base` image which has support for Java, Node, and Go.

My Cluster Builder looks like this: 

```
apiVersion: build.pivotal.io/v1alpha1
kind: ClusterBuilder
metadata:
  name: default
spec:
  image: gcr.io/paketo-buildpacks/builder:base
```

And we need to apply it to the cluster.

```
kubectl apply -f clusterBuilder.yml
```

6. Now we need to create an Image.
Here we are getting into the kpack specific stuff. An Image resource tells kpack what to build and manage!
Let's take a look.

My Image configuration looks like this:

```
apiVersion: build.pivotal.io/v1alpha1
kind: Image
metadata:
  name: build-service-sample-app
spec:
  tag: elenorevmware/build-service-sample-app
  serviceAccount: sample-app-service-account
  builder:
    name: default
    kind: ClusterBuilder
  source:
    git:
      url: https://github.com/elenorebastian/build-service-sample-app.git
      revision: ffe4347b511ed7969daf481fa4d16171fe35301d
```
Dont forget to replace the `tag` with the registry tag you specified when creating the registry secret.
This will look like: `your-name/app` or `gcr.io/your-project/app`.

Now apply that image to the cluster!

```
kubectl apply -f image.yml
```
 
This Image is pretty magical. The image gets built using the Builder resource. 
_kpack will automatically rebuild the sample app Image when there are any Builder updates_! 
So the next time `gcr.io/paketo-buildpacks/builder:base` gets updated, kpack will detect if there are any updates that need to be pushed out to the images, and rebuild those images accordingly. 
Pretty neat!

You can now check the status of the image!

```
kubectl get image build-service-sample-app
```

Once the image has been built you should see it pushed to your registry! 
I was able to verify that by running a quick `docker pull elenorevmware/build-service-sample-app`.


## CI/CD

Now lets talk about how to incorporate these tools into a CI/CD pipeline. I will be using Concourse to set up my pipeline. 
You can find all my pipeline jobs, tasks, and scripts in the `pipeline/` directory.

1. First, lets create a tasks that runs our app's unit tests.

Mine looks like this:
```
resources:
  - name: source-code
    type: git
    source:
      uri: https://github.com/elenorebastian/build-service-sample-app.git
      branch: master

jobs:
  - name: unit-test
    plan:
      - get: source-code
        trigger: true
      - task: run unit tests
        file: source-code/pipeline/unit-test.yml
      - put: build-service-sample-app
        params:
          commitish: source-code/.git/ref
```

This is pretty straight forward job - I am pulling down my `source-code` and running my unit tests.
  
2. Now that our app has passed its strenuous testing, lets use the [kpack concourse resource](https://github.com/pivotal/concourse-kpack-resource) to deploy our image to a cluster!

Let's update the pipeline to add a deploy job. My pipeline looks like this: 

```
resource_types:
  - name: kpack-image
    type: registry-image
    source:
      repository: gcr.io/cf-build-service-public/concourse-kpack-resource

resources:
  - name: source-code
    type: git
    source:
      uri: https://github.com/elenorebastian/build-service-sample-app.git
      branch: master

  - name: build-service-sample-app
    type: kpack-image
    source:
      image: "build-service-sample-app"
      namespace: default
      gke:
        json_key: ((service-account-key))
        kubeconfig: ((kubeconfig))

jobs:
  - name: unit-test
    plan:
      - get: source-code
        trigger: true
      - task: run unit tests
        file: source-code/pipeline/unit-test.yml
      - put: build-service-sample-app
        params:
          commitish: source-code/.git/ref

  - name: deploy image to cluster
    plan:
      - get: build-service-sample-app
        trigger: true
      - get: source-code
      - task: build kubenetes Deployment and apply to cluster
        file: source-code/pipeline/deploy-image.yml
        params:
          KUBECONFIG: ((kubeconfig))
```

Notice I have added a `kpack-image` resource type and defined that resource and named it `build-service-sample app`. 
This resource corresponds to the kpack image resource in my kubernetes cluster.
I also added my GKE credetials. You should have a `service-account-key` you used in the install steps. 
The `kubeconfig` I generated following these [instructions](https://ahmet.im/blog/authenticating-to-gke-without-gcloud/).

**Important**
Notice that `deploy-image-to-cluster` is NOT dependent on unit tests. This is not a mistake - it is intentional and by design!   

kpack will automatically rebuild images on Stack and Buildpack updates thus the `deploy-image-to-cluster` job will be triggered on all newly built images! 
A passed constraint on `unit-test` would exclude deploying images that were built from Builder or Stack updates. 
(meaning your app could miss out on those sweet sweet CVE updates 😭)

Please take a look at the deploy task and script found in the `pipeline/` directory!



