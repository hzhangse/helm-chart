# helm-chart
helm 

helm package kube-prometheus-stack/
helm package strimzi-kafka-operator/
kyligence$ helm package spark-api/
helm repo index --url https://hzhangse.github.io/helm-chart/ .

helm repo add hzhangse-helmrepo https://hzhangse.github.io/helm-chart
helm search repo kube-prometheus-stack
helm search repo strimzi-kafka-operator 
# try to install kube-prometheus-stack
helm install --dry-run --debug -n monitor  --create-namespace  kube-prometheus hzhangse-helmrepo/kube-prometheus-stack >kube-prometheus-stack-debug.yaml 
helm install  --debug -n monitor --create-namespace  kube-prometheus hzhangse-helmrepo/kube-prometheus-stack  

# disable nodeExporter
helm install  --debug -n monitor --create-namespace --set nodeExporter.enabled=false  kube-prometheus hzhangse-helmrepo/kube-prometheus-stack 

# update value in subchart
helm install  --debug -n monitor --create-namespace --set prometheus-node-exporter.service.port=9102  --set prometheus-node-exporter.service.targetPort=9102 kube-prometheus hzhangse-helmrepo/kube-prometheus-stack 

# install with customer value.yaml
helm install  --debug -n monitor --create-namespace -f ./kube-prometheus-stack/values-prometheus.yaml kube-prometheus ./kube-prometheus-stack > prom-debug.yaml

# uninstall kube-prometheus
helm uninstall   -n monitor kube-prometheus
# install thanos of myself
awk 'FNR==1 && NR!=1  {print "---"}{print}' manifests/*.yaml | helmify thanos
helm package thanos/
helm install --dry-run --debug -n thanos --create-namespace thanos ./thanos >thanos-debug.yaml
helm install --debug -n thanos --create-namespace thanos ./thanos >thanos-debug.yaml
helm uninstall   -n thanos thanos
# install thanos of Bitnami
## https://github.com/thanos-io/thanos/blob/release-0.22/docs/proposals-accepted/202012-receive-split.md
helm install --debug -n thanos --create-namespace thanos ./thanos-bitnami >thanos-debug.yaml

helm install --debug  -n thanos --create-namespace thanos -f  ./thanos-bitnami/values-self.yaml ./thanos-bitnami 

helm uninstall --debug -n thanos  thanos             
# try to install strimzi-kafka-operator 

helm install --dry-run --debug -n kafka-operator --set watchAnyNamespace=true --create-namespace kafka-operator ./strimzi-kafka-operator >kafka-debug.yaml

helm install --dry-run --debug -n kafka-operator --set watchAnyNamespace=true --create-namespace kafka-operator hzhangse-helmrepo/strimzi-kafka-operator >kafka-debug.yaml

helm install  --debug -n kafka-operator --set watchAnyNamespace=true  --create-namespace kafka-operator hzhangse-helmrepo/strimzi-kafka-operator
helm uninstall   -n kafka-operator kafka-operator 

# install kafka cluster cr in kafka namespace
kubectl apply -f ./CR/kafka-persistent-local.yaml -n kafka

# install spark-api
helm package spark-api/
helm install --dry-run --debug -n spark --create-namespace spark-api hzhangse-helmrepo/spark-api >sparkapi-debug.yaml
helm install --dry-run --debug -n spark --create-namespace spark-api ./spark-api >sparkapi-debug.yaml
helm install --debug -n spark --create-namespace spark-api hzhangse-helmrepo/spark-api 
helm install  --debug -n spark --create-namespace  spark-metrics-collector ./spark-api >sparkapi-debug.yaml
helm uninstall  -n spark metric

helm install --debug -n spark --create-namespace my ./spark/helm