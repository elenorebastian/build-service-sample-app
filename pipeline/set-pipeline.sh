
kubeconfig=$(cat pipeline/kubeconfig.yaml)
service_account_key=$(lpass show --notes "Shared-Build Service/gcp-concourse-service-account-json-key")

fly -t sample set-pipeline -p sample-app -c pipeline/pipeline.yml \
    --var service-account-key="$service_account_key" \
    --var kubeconfig="$kubeconfig"
