#!/bin/bash
set -e

export CLUSTER=mycluster
export HTTPPORT=8080
export GRAFANA_PASS=operator

#
# remove existing cluster
if [[ ! -z $(k3d cluster list | grep "^${CLUSTER}") ]]; then
  echo
  echo "==== remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete ${CLUSTER}
fi  

echo
echo "==== install app packages"
npm install
export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json
export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json

echo "==== create new cluster ${CLUSTER} for app ${APP}:${VERSION}"
cat k3d-config.yaml.template | envsubst > /tmp/k3d-config.yaml
k3d cluster create --config /tmp/k3d-config.yaml
export KUBECONFIG=$(k3d kubeconfig write mycluster)
echo "export KUBECONFIG=${KUBECONFIG}"
rm /tmp/k3d-config.yaml

echo
echo "==== running helm for ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl create namespace ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx

echo
echo "==== waiting for ingress-nginx-controller deployment to be ready"
kubectl rollout status deployment.apps ingress-nginx-controller -n ingress-nginx --request-timeout 5m
kubectl rollout status daemonset.apps svclb-ingress-nginx-controller -n ingress-nginx --request-timeout 5m
x="0"
echo -n "Waiting for ingress-nginx-controller to get an IP address.."
while [ true ]; do
  LBIP=$(kubectl get svc ingress-nginx-controller --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}" -n ingress-nginx)
  [ ! -z "${LBIP}" ] && break
  echo -n "."
  x=$(( ${x} + 2 ))
  [ $x -gt "100" ] && echo "ingress-nginx-controller not ready after ${x} seconds. Exit" && exit 1
  sleep 2
done
echo

echo
echo "==== show info about the cluster ${CLUSTER}"
kubectl cluster-info
echo
kubectl get all -A

echo "==== Showing ingress-nginx-controller info in the namespace \"ingress-nginx\""
NGINXCONTROLLERPOD=$(kubectl get pods -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.name}' -n ingress-nginx)
kubectl exec -it ${NGINXCONTROLLERPOD} -n ingress-nginx -- /nginx-ingress-controller --version

echo
echo "==== install prometheus-community stack (this may show warnings related to beta APIs)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
cat prom-values.yaml.template | envsubst | helm install --values - prom prometheus-community/kube-prometheus-stack -n monitoring
kubectl rollout status deployment.apps prom-grafana -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps prom-kube-state-metrics -n monitoring --request-timeout 5m
kubectl rollout status deployment.apps prom-kube-prometheus-stack-operator -n monitoring --request-timeout 5m

echo
echo "==== build app image ${APP}:${VERSION}"
docker build -t ${APP}:${VERSION} .

echo
echo "==== import new image ${APP}:${VERSION} to k3d ${CLUSTER} (this may take a while)"
k3d image import ${APP}:${VERSION} -c ${CLUSTER} --keep-tools 

echo
echo "==== deploy application (namespace, pods, service, ingress, dashboard)"
cat app.yaml.template | envsubst | kubectl create -f - --save-config
cat static-info-dashboard.json.template | envsubst > /tmp/static-info-dashboard.json
kubectl create configmap static-metric-dashboard-configmap -n monitoring --from-file="/tmp/static-info-dashboard.json"
kubectl patch configmap static-metric-dashboard-configmap -p '{"metadata":{"labels":{"grafana_dashboard":"1"}}}' -n monitoring
rm /tmp/static-info-dashboard.json

echo
echo "==== wait for ${app} deployment to finish"
kubectl rollout status deployment.apps ${APP}-deploy -n ${APP} --request-timeout 5m

echo
echo "==== Show Ingresses:"
kubectl get ing -A

echo 
echo "==== Various entrypoints"
echo "export KUBECONFIG=${KUBECONFIG}"
echo "Lens: monitoring/prom-kube-prometheus-stack-prometheus:9090/prom"
echo "${APP} info API: http://localhost:${HTTPPORT}/service/info"
echo "${APP} random API: http://localhost:${HTTPPORT}/service/random"
echo "${APP} metrics API: http://localhost:${HTTPPORT}/service/metrics"
echo "prometheus: http://localhost:${HTTPPORT}/prom"
echo "alertmanager: http://localhost:${HTTPPORT}/alert"
echo "grafana: http://localhost:${HTTPPORT}  (use admin/${GRAFANA_PASS} to login)"
