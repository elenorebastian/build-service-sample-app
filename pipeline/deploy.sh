#!/bin/sh

set -e -u -

mkdir $HOME/.kube/
echo $KUBECONFIG > $HOME/.kube/config

image=$(cat build-service-sample-app/image)

cat <<\EOF > values.yml
#@data/values
---
image:
EOF

ytt -v image="${image}" -f values.yml -f source-code/resources/deployment.yml | kubectl apply -f