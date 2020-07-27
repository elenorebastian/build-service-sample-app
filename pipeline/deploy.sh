#!/bin/sh

set -e -u -

mkdir $HOME/.kube/
echo $KUBECONFIG > $HOME/.kube/config

image=$(cat build-service-sample-app/image)

echo $image

cat << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: build-service-sample-app
  labels:
    app: build-service-sample-app
spec:
  selector:
    matchLabels:
      app: build-service-sample-app
  template:
    metadata:
      labels:
        app: build-service-sample-app
    spec:
      containers:
      - name: build-service-sample-app
        image: $image
        ports:
        - containerPort: 80
EOF