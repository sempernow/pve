#!/usr/bin/env bash

curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install kubectl /usr/local/bin/kubectl
rm kubectl

which kubectl &&
    kubectl ||
        echo "⚠️  ERR $? : kubectl is NOT installed."