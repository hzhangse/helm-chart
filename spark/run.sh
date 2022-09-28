#!/bin/bash
_HOME=$(pwd)
SPARK_HOME=/opt/spark
namespace='spark'
profile="local"
##  /opt/spark/work-dir/run.sh -Enative -ntestfree -C2 -c2 -M6 -m2  -i1 -x2 -d1 -a2000 -tfree -ucluster
tenent="free"
cpu=4
memory=8G
reclaimable=false
weight=1

jobname=spark-test-free
k8s_api_server=https://172.21.101.102:6443
spark_image=default.registry.tke.com/kyligence/spark:v3.1.1
mainApplicationFile=local:///opt/spark/examples/jars/spark-examples_2.12-3.1.1.jar
spark_operator=spark-operator

sa_secret=
spark_operator_clusterrole=""
#sa_secret_mount_path=/opt/spark/serviceaccount
sa_secret_mount_path=/var/run/secrets/kubernetes.io/serviceaccount
submit_mode=cluster
submitInDriver=true
driver_core=2
driver_mem=4096m
executor_core=2
executor_mem=4096m
minExecutors=1
maxExecutors=5
index=2
sleepTime=1s
arg=10000
queue=queue-free

mem_unit="M"

deploy_run_script=

volcano_image=
spark_imagePullPolicy="IfNotPresent"
#########################################################################
install_volcano_queue() {
  cat >volcano_queue_for_${tenent}.yaml <<EOF
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: ${queue}
spec:  
  reclaimable: ${reclaimable}
  weight: ${weight}
  capability:
    cpu: "${cpu}"
    memory: "${memory}"  
  guarantee: 
    resource:
      cpu: "${cpu}"
      memory: "${memory}"         
EOF
  kubectl apply -f volcano_queue_for_${tenent}.yaml -n ${namespace}
}
#########################################################################

choseTenentQueue() {
  tenent=$1
  if test $tenent = 'free'; then
    queue=queue-free
  elif test $tenent = 'share'; then
    queue=queue-share
  else
    queue=default
  fi
}

#########################################################################
test_spark_application() {
  jobname="spark-application-"${jobname}

  for ((i = 0; i < ${index}; i++)); do
    let "arg=arg*(i+1)"
    cat >${jobname}-${i}.yaml <<EOF
apiVersion: "sparkoperator.k8s.io/v1beta2"
kind: SparkApplication
metadata:
  name: ${jobname}-${i}
  namespace: ${namespace}
spec:
  type: Scala
  sparkConf:
    "spark.kubernetes.driver.master": "${k8s_api_server}"
    "spark.master": "k8s://${k8s_api_server}"
    "spark.kubernetes.authenticate.driver.mounted.oauthTokenFile": "${sa_secret_mount_path}/token"
    "spark.kubernetes.authenticate.driver.caCertFile": "${sa_secret_mount_path}/ca.crt"
    "spark.kubernetes.executor.scheduler.name": "volcano"
    "spark.app.name": "${jobname}-${i}"
    "spark.kubernetes.submitInDriver": "${submitInDriver}" 
    "spark.kubernetes.authenticate.driver.serviceAccountName": "${spark_sa}"
    "spark.kubernetes.executor.podNamePrefix": "${jobname}-${i}"
  mode: ${submit_mode}
  image: "${spark_image}"
  imagePullPolicy: IfNotPresent
  mainClass: org.apache.spark.examples.SparkPi
  mainApplicationFile: "${mainApplicationFile}"
  arguments:
    - "${arg}"
  sparkVersion: "3.1.1"
  batchScheduler: "volcano"
  batchSchedulerOptions:
    queue: "${queue}"
  dynamicAllocation:
    enabled: true
    initialExecutors: ${minExecutors}
    minExecutors: ${minExecutors}
    maxExecutors: ${maxExecutors}
  driver:
    terminationGracePeriodSeconds: 60
    memory: "${driver_mem}${mem_unit}"
    coreRequest: "${driver_core}"
    cores: ${driver_core}
    coreLimit: "${driver_core}"
    labels:
      version: 3.1.1
    secrets:
      - name: ${sa_secret}
        path: ${sa_secret_mount_path}
        secretType: Opaque
  executor:
    memory: "${executor_mem}${mem_unit}"
    cores: ${executor_core}
    coreRequest: "${executor_core}"
    coreLimit: "${driver_core}"
    labels:
      version: 3.1.1
  restartPolicy:
    type: OnFailure
    onFailureRetries: 3
    onFailureRetryInterval: 5
    onSubmissionFailureRetries: 5
    onSubmissionFailureRetryInterval: 5
EOF
    kubectl delete -f ${jobname}-${i}.yaml -n ${namespace}
    kubectl apply -f ${jobname}-${i}.yaml -n ${namespace}
    sleep ${sleepTime}
  done
}

##############################################################################
sparkJob_pg_apply() {
  cat >${sparkJobName}-pg.yaml <<EOF
apiVersion: scheduling.volcano.sh/v1beta1
kind: PodGroup
metadata:
  name: ${sparkJobName}-podgroup
  namespace: ${namespace}
  # ownerReferences:
  # - apiVersion: v1
  #   controller: true
  #   kind: Pod
  #   name: ${drivername}
  #   uid: ${driveruid}
spec:
  minMember: 1
  minResources:
    cpu: "${min_core}"
    memory: "${min_mem}${mem_unit}"
  queue: ${queue}
EOF
  kubectl delete -f ${sparkJobName}-pg.yaml -n ${namespace}
  kubectl apply -f ${sparkJobName}-pg.yaml -n ${namespace}
}

##############################################################################
sparkJob_pg_patch() {
  cat >${sparkJobName}-pg-patch.yaml <<EOF
metadata:
  ownerReferences:
  - apiVersion: v1
    controller: true
    kind: Pod
    name: ${drivername}
    uid: ${driveruid}
EOF
  kubectl patch podgroup ${sparkJobName}-podgroup --type='merge' --patch-file ${sparkJobName}-pg-patch.yaml -n ${namespace}

}

##############################################################################
test_spark_native() {
  for ((i = 0; i < ${index}; i++)); do
    if test $action = 'native31'; then
      let "arg=arg*(i+1)"
      let "min_core=executor_core*minExecutors+driver_core"
      let "min_mem=executor_mem*minExecutors+driver_mem"
      sparkJobName="spark31-native-"${jobname}-${i}
      drivername=${sparkJobName}-driver
      kubectl delete pod ${drivername} -n ${namespace}
      sparkJob_pg_apply
      podname='spark-deploy31'
    elif test $action = 'native33'; then
      sparkJobName="spark33-native-"${jobname}-${i}
      drivername=${sparkJobName}-driver

      podname='spark-deploy33'
    fi
    pod=$(kubectl get pods -n ${namespace} | grep ${podname} | awk '{print $1, $3}' | grep Running | awk '{print $1}')
    if [ $pod ]; then
      remote_action=remote_${action}
      _call="/opt/spark/work-dir/run.sh -E${remote_action} -n${jobname} -C${driver_core} -c${executor_core} -M${driver_mem} -m${executor_mem}  -i${minExecutors} -x${maxExecutors} -d${i} -a${arg} -t${tenent} -p${profile} 1>${sparkJobName}.log 2>&1 & "
      echo kubectl exec  $pod -n ${namespace} -- sh -c "$_call"
      kubectl exec $pod -n ${namespace} -- sh -c "$_call"

     
    fi

  done
  monitor_native_spark_jobs
}
##############################################################################
monitor_native_spark_jobs() {

  for ((i = 0; i < ${index}; i++)); do
    jobstatus[$i]=false
    pg_patched[$i]=false
  done

  while :; do
    for ((i = 0; i < ${index}; i++)); do

      if [ ${jobstatus[$i]} = false ]; then

        if test $action = 'native31'; then
          sparkJobName="spark31-native-"${jobname}-${i}
          drivername=${sparkJobName}-driver
        elif test $action = 'native33'; then
          sparkJobName="spark33-native-"${jobname}-${i}
          drivername=${sparkJobName}-driver
        fi

        driverpod=$(kubectl get pod ${drivername} -n ${namespace} -o custom-columns=uid:metadata.uid,status:status.phase | awk ' NR==2 {print $1, $2}')
        if [ "$driverpod" != "" ]; then
          driverstatus=$(echo ${driverpod} | awk '{print $2}')
          driveruid=$(echo ${driverpod} | awk '{print $1}')
          if [ $action = 'native31' -a ${pg_patched[$i]} = false ]; then
            sparkJob_pg_patch
            pg_patched[$i]=true
          elif [ $driverstatus = 'Succeeded' ]; then
            jobstatus[i]=true
            podgroup=$(kubectl get podgroups -n ${namespace} -o custom-columns=name:metadata.name,refername:.metadata.ownerReferences[0].name,status:status.phase,succeeded:status.succeeded | grep ${drivername} | awk ' NR==1 {print $1, $2, $3, $4} ')

            if [ "$podgroup" != "" ]; then
              pgname=$(echo ${podgroup} | awk '{print $1}')
              refername=$(echo ${podgroup} | awk '{print $2}')
              status=$(echo ${podgroup} | awk '{print $3}')
              succeeded=$(echo ${podgroup} | awk '{print $4}')
              if [ $status = 'Running' ]; then
                kubectl delete podgroup $pgname -n ${namespace}
                kubectl delete pod ${drivername} -n ${namespace}
              fi
            fi
          fi

        fi
      fi
    done

    finish=true
    for ((i = 0; i < ${index}; i++)); do
      if [ ${jobstatus[$i]} = false ]; then
        finish=false
        break
      fi
    done

    if [ $finish = true ]; then
      break
    fi
    sleep 5s
  done

  # for ((i = 0; i < ${index}; i++)); do
  #   if test $action = 'native31'; then
  #     sparkJobName="spark31-native-"${jobname}-${i}
  #     drivername=${sparkJobName}-driver
  #   elif test $action = 'native33'; then
  #     sparkJobName="spark33-native-"${jobname}-${i}
  #     drivername=${sparkJobName}-driver
  #   fi
  #   podgroup=$(kubectl get podgroups -o custom-columns=name:metadata.name,refername:.metadata.ownerReferences[0].name,status:status.phase,succeeded:status.succeeded | grep ${drivername} | awk ' NR==1 {print $1, $2, $3, $4} ')

  #   if [ "$podgroup" != "" ]; then
  #     pgname=$(echo ${podgroup} | awk '{print $1}')
  #     refername=$(echo ${podgroup} | awk '{print $2}')
  #     status=$(echo ${podgroup} | awk '{print $3}')
  #     succeeded=$(echo ${podgroup} | awk '{print $4}')
  #     if [ $status = 'Running' ]; then
  #       kubectl delete podgroup $pgname
  #     fi
  #   fi
  # done

}

##############################################################################
create_pod_template() {
  cat >${jobname}_${i}_pod_template.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  annotations:
    scheduling.k8s.io/group-name: "${sparkJobName}-podgroup"
spec:
  automountServiceAccountToken: false
  schedulerName: volcano

EOF
}
##############################################################################

test_native_in_pod() {

  #for ((i = 0; i < ${index}; i++)); do
  i=${index}
  let "arg=arg*(i+1)"
  let "min_core=executor_core*minExecutors+driver_core"
  let "min_mem=executor_mem*minExecutors+driver_mem"

  if test $action = 'native31'; then
    sparkJobName="spark31-native-"${jobname}-${i}
    drivername=${sparkJobName}-driver
    create_pod_template
    test_spark31_native
  elif test $action = 'native33'; then
    sparkJobName="spark33-native-"${jobname}-${i}
    drivername=${sparkJobName}-driver
    create_pod_template
    test_spark33_native
  else
    echo "没有符合的条件"
  fi
  #done

}
# --conf "spark.kubernetes.driver.annotation.'scheduling.k8s.io/group-name'=${sparkJobName}-podgroup" \
##############################################################################
test_spark31_native() {
  cat >${sparkJobName}.sh <<EOF
$SPARK_HOME/bin/spark-submit \
    --master k8s://${k8s_api_server} \
    --deploy-mode ${submit_mode} \
    --name ${sparkJobName} \
    --class "org.apache.spark.examples.SparkPi" \
    --driver-memory="${driver_mem}${mem_unit}"   \
    --executor-memory="${executor_mem}${mem_unit}"  \
    --conf "spark.kubernetes.submitInDriver=${submitInDriver}" \
    --conf "spark.master=k8s://${k8s_api_server}" \
    --conf "spark.app.name=${sparkJobName}" \
    --conf "spark.driver.memory=${driver_mem}${mem_unit}" \
    --conf "spark.driver.memoryOverhead=512M" \
    --conf "spark.executor.memory=${executor_mem}${mem_unit}" \
    --conf "spark.executor.memoryOverhead=512M" \
    --conf "spark.eventLog.enabled=false"  \
    --conf "spark.kubernetes.namespace=${namespace}"  \
    --conf "spark.kubernetes.scheduler.name=volcano"  \
    --conf "spark.kubernetes.authenticate.driver.mounted.oauthTokenFile=${sa_secret_mount_path}/token" \
    --conf "spark.kubernetes.authenticate.driver.caCertFile=${sa_secret_mount_path}/ca.crt"  \
    --conf "spark.kubernetes.driver.pod.name=${drivername}" \
    --conf "spark.kubernetes.driver.secrets.${sa_secret}=${sa_secret_mount_path}" \
    --conf "spark.kubernetes.driver.master=${k8s_api_server}" \
    --conf "spark.kubernetes.driver.label.app=${sparkJobName}" \
    --conf "spark.kubernetes.driver.request.cores=${driver_core}" \
    --conf "spark.kubernetes.driver.limit.cores=${driver_core}" \
    --conf "spark.kubernetes.driver.scheduler.name=volcano"  \
    --conf "spark.kubernetes.executor.scheduler.name=volcano" \
    --conf "spark.kubernetes.executor.deleteOnTermination=true" \
    --conf "spark.kubernetes.executor.request.cores=${executor_core}" \
    --conf "spark.kubernetes.executor.limit.cores=${executor_core}" \
    --conf "spark.kubernetes.executor.podNamePrefix=${sparkJobName}"  \
    --conf "spark.dynamicAllocation.executorIdleTimeout=10s" \
    --conf "spark.dynamicAllocation.cachedExecutorIdleTimeout=200s" \
    --conf "spark.dynamicAllocation.minExecutors=$minExecutors" \
    --conf "spark.dynamicAllocation.initialExecutors=$minExecutors" \
    --conf "spark.dynamicAllocation.maxExecutors=$maxExecutors"  \
    --conf "spark.dynamicAllocation.executorAllocationRatio=0.5" \
    --conf "spark.dynamicAllocation.enabled=true" \
    --conf "spark.dynamicAllocation.shuffleTracking.enabled=true" \
    --conf "spark.kubernetes.container.image=${spark_image}" \
    --conf "spark.kubernetes.driver.podTemplateFile=${jobname}_${i}_pod_template.yaml" \
    --conf "spark.kubernetes.executor.podTemplateFile=${jobname}_${i}_pod_template.yaml"  \
    ${mainApplicationFile} ${arg} 

  while true 
  do
	  monitor=\`cat ${sparkJobName}.log |grep 'failed to create pod <default/${sparkJobName}'| grep -v grep | wc -l \`
	  if [ \$monitor -eq 1 ] 
    then
        ./${sparkJobName}.sh 1> ${sparkJobName}.log 2>&1 &
	  else
		   break
	  fi
  done   
EOF

  chmod a+x ${sparkJobName}.sh && ./${sparkJobName}.sh
}




#############################################################################
test_spark33_native() {

  cat >${sparkJobName}-pg.yaml <<EOF
apiVersion: scheduling.volcano.sh/v1beta1
kind: PodGroup
spec:
  minMember: 1
  minResources:
    cpu: "${min_core}"
    memory: "${min_mem}${mem_unit}"
  queue: ${queue}
EOF

  cat >${sparkJobName}.sh <<EOF

$SPARK_HOME/bin/spark-submit \
    --master k8s://${k8s_api_server} \
    --deploy-mode ${submit_mode} \
    --name ${sparkJobName} \
    --class "org.apache.spark.examples.SparkPi" \
    --driver-memory="${driver_mem}${mem_unit}"   \
    --executor-memory="${executor_mem}${mem_unit}"  \
    --conf "spark.kubernetes.submitInDriver=${submitInDriver}" \
    --conf "spark.master=k8s://${k8s_api_server}" \
    --conf "spark.app.name=${sparkJobName}" \
    --conf "spark.driver.memory=${driver_mem}${mem_unit}" \
    --conf "spark.driver.memoryOverhead=512M" \
    --conf "spark.executor.memory=${executor_mem}${mem_unit}" \
    --conf "spark.executor.memoryOverhead=512M" \
    --conf "spark.eventLog.enabled=false"  \
    --conf "spark.kubernetes.namespace=${namespace}"  \
    --conf "spark.kubernetes.scheduler.name=volcano"  \
    --conf "spark.kubernetes.authenticate.driver.mounted.oauthTokenFile=${sa_secret_mount_path}/token" \
    --conf "spark.kubernetes.authenticate.driver.caCertFile=${sa_secret_mount_path}/ca.crt"  \
    --conf "spark.kubernetes.driver.pod.name=${drivername}" \
    --conf "spark.kubernetes.driver.secrets.${sa_secret}=${sa_secret_mount_path}" \
    --conf "spark.kubernetes.driver.master=${k8s_api_server}" \
    --conf "spark.kubernetes.driver.label.app=${sparkJobName}" \
    --conf "spark.kubernetes.driver.request.cores=${driver_core}" \
    --conf "spark.kubernetes.driver.limit.cores=${driver_core}" \
    --conf "spark.kubernetes.scheduler.volcano.podGroupTemplateFile=${sparkJobName}-pg.yaml" \
    --conf "spark.kubernetes.driver.pod.featureSteps=org.apache.spark.deploy.k8s.features.VolcanoFeatureStep"  \
    --conf "spark.kubernetes.executor.pod.featureSteps=org.apache.spark.deploy.k8s.features.VolcanoFeatureStep" \
    --conf "spark.kubernetes.executor.scheduler.name=volcano" \
    --conf "spark.kubernetes.executor.deleteOnTermination=true" \
    --conf "spark.kubernetes.executor.request.cores=${executor_core}" \
    --conf "spark.kubernetes.executor.limit.cores=${executor_core}" \
    --conf "spark.kubernetes.executor.podNamePrefix=${sparkJobName}"  \
    --conf "spark.dynamicAllocation.executorIdleTimeout=10s" \
    --conf "spark.dynamicAllocation.cachedExecutorIdleTimeout=200s" \
    --conf "spark.dynamicAllocation.minExecutors=$minExecutors" \
    --conf "spark.dynamicAllocation.initialExecutors=$minExecutors" \
    --conf "spark.dynamicAllocation.maxExecutors=$maxExecutors"  \
    --conf "spark.dynamicAllocation.executorAllocationRatio=0.5" \
    --conf "spark.dynamicAllocation.enabled=true" \
    --conf "spark.dynamicAllocation.shuffleTracking.enabled=true" \
    --conf "spark.kubernetes.container.image=${spark_image}" \
    --conf "spark.kubernetes.driver.podTemplateFile=${jobname}_${i}_pod_template.yaml" \
    --conf "spark.kubernetes.executor.podTemplateFile=${jobname}_${i}_pod_template.yaml"  \
    --conf "spark.plugins=ch.cern.CgroupMetrics"     \
    --conf "spark.cernSparkPlugin.registerOnDriver=true"     \
    --conf "spark.extraListeners=ch.cern.sparkmeasure.KafkaSinkExtended,ch.cern.sparkmeasure.InfluxDBSink" \
    --conf spark.sparkmeasure.influxdbURL="http://spark-dashboard-influx.spark-dashboard.svc.cluster.local:8086" \
    --conf spark.sparkmeasure.influxdbStagemetrics=true \
    --conf "spark.sparkmeasure.kafkaBroker=spark-metrics-collector-kafka-brokers.spark.svc.cluster.local:9092" \
    --conf "spark.sparkmeasure.kafkaTopic=sparkmeasure" \
    --conf "spark.driver.extraClassPath=/opt/spark/plugins/*:/opt/spark/listeners/*:/opt/spark/listeners/lib/*"  \
    --conf "spark.executor.extraClassPath=/opt/spark/plugins/*"  \
    --conf "spark.ui.prometheus.enabled=true" \
    --conf "spark.kubernetes.driver.annotation.prometheus.io/scrape=true" \
    --conf "spark.kubernetes.driver.annotation.prometheus.io/path=/metrics/executors/prometheus" \
    --conf "spark.kubernetes.driver.annotation.prometheus.io/port=4040" \
    --conf "spark.kubernetes.driver.annotation.prometheus.io/jmxpath=/metrics" \
    --conf "spark.kubernetes.driver.annotation.prometheus.io/jmxport=8080" \
    --conf "spark.kubernetes.executor.annotation.prometheus.io/scrape=true" \
    --conf "spark.kubernetes.executor.annotation.prometheus.io/jmxpath=/metrics" \
    --conf "spark.kubernetes.executor.annotation.prometheus.io/jmxport=8080"  \
    --conf "spark.metrics.conf.*.sink.prometheusServlet.class=org.apache.spark.metrics.sink.PrometheusServlet" \
    --conf "spark.metrics.conf.*.sink.prometheusServlet.path=/metrics/prometheus" \
    --conf "spark.metrics.conf.applications.sink.prometheusServlet.path=/metrics/applications/prometheus" \
    --conf "spark.metrics.conf.*.sink.servlet.class=org.apache.spark.metrics.sink.MetricsServlet" \
    --conf "spark.metrics.conf.*.sink.servlet.path=/metrics/json" \
    --conf "spark.metrics.conf.master.sink.servlet.path=/metrics/master/json" \
    --conf "spark.metrics.conf.applications.sink.servlet.path=/metrics/applications/json" \
    --conf "spark.metrics.conf.*.sink.jmx.class=org.apache.spark.metrics.sink.JmxSink" \
    --conf "spark.metrics.conf.*.sink.graphite.class"="org.apache.spark.metrics.sink.GraphiteSink" \
    --conf "spark.metrics.conf.*.sink.graphite.host"="spark-dashboard-influx.spark-dashboard.svc.cluster.local" \
    --conf "spark.metrics.conf.*.sink.graphite.port"=2003 \
    --conf "spark.metrics.conf.*.sink.graphite.period"=10 \
    --conf "spark.metrics.conf.*.sink.graphite.unit"=seconds \
    --conf "spark.metrics.conf.*.sink.graphite.prefix"="kyligence" \
    --conf "spark.metrics.conf.*.source.jvm.class"="org.apache.spark.metrics.source.JvmSource" \
    --conf spark.metrics.appStatusSource.enabled=true \
    --conf "spark.eventLog.enabled=false"      --conf "spark.kubernetes.container.image.pullPolicy=${spark_imagePullPolicy}"     \
    --conf "spark.executor.extraJavaOptions=-javaagent:/opt/spark/listeners/lib/jmx_prometheus_javaagent-0.17.0.jar=8080:/opt/spark/listeners/lib/spark-jmx.yml"  \
    --conf "spark.driver.extraJavaOptions=-javaagent:/opt/spark/listeners/lib/jmx_prometheus_javaagent-0.17.0.jar=8080:/opt/spark/listeners/lib/spark-jmx.yml"  \
    ${mainApplicationFile} ${arg} 

  while true 
  do
	  monitor=\`cat ${sparkJobName}.log |grep 'failed to create pod <default/${sparkJobName}'| grep -v grep | wc -l \`
	  if [ \$monitor -eq 1 ] 
    then
        ./${sparkJobName}.sh 1> ${sparkJobName}.log 2>&1 &
	  else
		   break
	  fi
  done
EOF

  chmod a+x ${sparkJobName}.sh && ./${sparkJobName}.sh
  ###--conf "spark.sparkmeasure.prometheusURL=http://10.1.2.63:30003/api/v1/write"   \
  ###--conf "spark.sparkmeasure.prometheusStagemetrics=true"  \
}
##############################################################################

deploy_sa_spark_rbac() {
    cat >spark-sa-rbac.yaml <<EOF
kind: ServiceAccount
apiVersion: v1
metadata:
  name: my-release-spark
  namespace: ${namespace}
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spark
  namespace: ${namespace}
subjects:
  - kind: ServiceAccount
    name: my-release-spark
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: spark-role
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: spark-role
  namespace: ${namespace}
rules:
  - verbs:
      - '*'
    apiGroups:
      - ''
    resources:
      - pods
  - verbs:
      - '*'
    apiGroups:
      - ''
    resources:
      - services
  - verbs:
      - '*'
    apiGroups:
      - ''
    resources:
      - configmaps
  - verbs:
      - '*'
    apiGroups:
      - ''
    resources:
      - persistentvolumeclaims
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-release-spark-cluster-rb
subjects:
  - kind: ServiceAccount
    name: my-release-spark
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: my-release-spark-operator
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: my-release-spark-operator
  labels:
    app.kubernetes.io/instance: my-release
rules:
  - verbs:
      - '*'
    apiGroups:
      - ''
    resources:
      - pods
  - verbs:
      - create
      - get
      - delete
      - update
    apiGroups:
      - ''
    resources:
      - services
      - configmaps
      - secrets
  - verbs:
      - create
      - get
      - delete
    apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
  - verbs:
      - get
    apiGroups:
      - ''
    resources:
      - nodes
  - verbs:
      - create
      - update
      - patch
    apiGroups:
      - ''
    resources:
      - events
  - verbs:
      - get
      - list
      - watch
    apiGroups:
      - ''
    resources:
      - resourcequotas
  - verbs:
      - create
      - get
      - update
      - delete
    apiGroups:
      - apiextensions.k8s.io
    resources:
      - customresourcedefinitions
  - verbs:
      - create
      - get
      - update
      - delete
    apiGroups:
      - admissionregistration.k8s.io
    resources:
      - mutatingwebhookconfigurations
      - validatingwebhookconfigurations
  - verbs:
      - '*'
    apiGroups:
      - sparkoperator.k8s.io
    resources:
      - sparkapplications
      - sparkapplications/status
      - scheduledsparkapplications
      - scheduledsparkapplications/status
  - verbs:
      - '*'
    apiGroups:
      - scheduling.incubator.k8s.io
      - scheduling.sigs.dev
      - scheduling.volcano.sh
    resources:
      - podgroups
  - verbs:
      - delete
    apiGroups:
      - batch
    resources:
      - jobs

EOF
    kubectl apply -f spark-sa-rbac.yaml -n ${namespace}

}
#########################################################################
deploy_spark() {
 # content=$(cat $0 | base64 -)
  spark_operator_clusterrole=$(kubectl get clusterrole | grep ${spark_operator} | awk '{print $1}')
#   cat >testsecret.yaml <<EOF
# kind: Secret
# apiVersion: v1
# metadata:
#   name: testscript
#   namespace: default
# data:
#   run.sh: >-
#     ${content}
# type: Opaque
# EOF
  
kubectl -n ${namespace} delete secret  testscript
kubectl -n ${namespace} create secret generic testscript --from-file=run.sh=$0
  cat >spark_deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spark-${action}
  labels:
    app: spark-${action}  
spec:
  replicas: 1
  selector:
    matchLabels:
      app: spark-${action}  
  template:
    metadata:
      labels:
        app: spark-${action}
    spec:
      volumes:
        - name: sa-secret-volume
          secret:
            secretName: ${sa_secret}
            defaultMode: 420    
        - name: test-volume
          secret:
            secretName: testscript
            defaultMode: 420                
      containers:
      - name: spark
        image: ${spark_image}
        env:
          - name: v_sa_secret
            value: ${sa_secret}
        #### && /opt/spark/work-dir/run.sh -Enative -ntestfree -C2 -c2 -M6 -m2  -i1 -x7 -d1 -a10000 -tfree
        command: ['sh', '-c', 'cp /opt/spark/work-dir/test/run.sh /opt/spark/work-dir && chmod a+x /opt/spark/work-dir/run.sh  && tail -f /opt/entrypoint.sh']
        volumeMounts:
          - name: sa-secret-volume
            mountPath: ${sa_secret_mount_path}
          - name: test-volume
            mountPath: /opt/spark/work-dir/test     
        securityContext:
          runAsUser: 0
      serviceAccountName: ${spark_sa}       
      affinity: 
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/role
                operator: NotIn
                values:
                - agent       
EOF

  cat >spark_sa_clusterrolebindings.yaml <<EOF
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: ${spark_sa}
subjects:
  - kind: ServiceAccount
    name: ${spark_sa}
    namespace: ${namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${spark_operator_clusterrole}
EOF
  kubectl apply -f spark_sa_clusterrolebindings.yaml -n ${namespace}
  #kubectl apply -f testsecret.yaml
  kubectl delete -f spark_deployment.yaml -n ${namespace}
  kubectl apply -f spark_deployment.yaml -n ${namespace}

}

#########################################################################
install_volcano() {
  if test $profile = 'local'; then
    vc_scheduler_image="registry.cn-shanghai.aliyuncs.com/kyligence/vc-scheduler:9698fbbcfca446b3d4a6cbaaf01677e48efaafd9"
    vc_controller_manager_image="volcanosh/vc-controller-manager:latest"
    vc_webhook_manager_image="volcanosh/vc-webhook-manager:latest"
  elif test $profile = 'yinlian'; then
    vc_scheduler_image="default.registry.tke.com/kyligence/vc-scheduler:latest"
    vc_controller_manager_image="default.registry.tke.com/kyligence/vc-controller-manager:latest"
    vc_webhook_manager_image="default.registry.tke.com/kyligence/vc-webhook-manager:latest"

  else
    echo "没有符合的条件"
  fi
  if [ $profile ]; then
    source ./volcano-deploy.sh
  fi
}
#########################################################################
install_virtual_node() {
  if test $profile = 'local'; then
    virtual_node_image="registry.cn-shanghai.aliyuncs.com/kyligence/virtual-node:v0.1.1-28-gacf54270970cb7"
  elif test $profile = 'yinlian'; then
    virtual_node_image="default.registry.tke.com/kyligence/virtual-node:v0.1.1-28-gacf54270970cb7"
  else
    echo "没有符合的条件"
  fi
  if [ $profile ]; then
    vritual_node_name="vkcluster"
    client_kube_config=$(/.kube/config)
    source ./virtual-node-deploy.sh
  fi
}
#########################################################################
install_spark_operator() {

  if test $profile = 'local'; then
    spark_operator_image="ghcr.io/googlecloudplatform/spark-operator"
    spark_operator_image_tag="v1beta2-1.3.3-3.1.1"
  elif test $profile = 'yinlian'; then
    spark_operator_image="default.registry.tke.com/kyligence/spark-operator"
    spark_operator_image_tag="v1beta2-1.3.3-3.1.1"
  else
    echo "没有符合的条件"
  fi
  if [ $profile ]; then

    source ./spark-operator-deploy.sh
  fi
}

#########################################################################
isRemote=
init_env() {
  isRemote=$(echo $action | grep 'remote')
  if [ $isRemote ]; then
    action=$(echo $action | awk -F "_" '{print $2}')
  fi

  if test $profile = 'local'; then
    k8s_api_server=https://10.1.2.63:6443
    spark_operator=my-release-spark-operator
    spark_sa=my-release-spark
    spark_image=registry.cn-shanghai.aliyuncs.com/kyligence/spark
    
  elif
    test $profile = 'yinlian'
  then
    k8s_api_server=https://172.21.101.102:6443
    # by opperator `helm install sparkoperator ./ --namespace spark-operator --create-namespace -f spark-operator-values.yaml`
    spark_operator=sparkoperator-spark-operator
    spark_sa=sparkoperator-spark
    spark_image=default.registry.tke.com/kyligence/spark
  else
    echo "没有符合的条件"
  fi

  if test $action = 'operator' -o $action = 'deploy31' -o $action = 'deploy33'; then
    deploy_sa_spark_rbac
    sa_secret=$(kubectl get secret -n ${namespace} | grep ${spark_sa} | awk '{print $1}')
    #sa_secret="apiserver"
  elif test $action = 'native31' -o $action = 'native33'; then
    sa_secret=${v_sa_secret}
  fi

  if test $action = 'operator' -o $action = 'native31' -o $action = 'deploy31'; then
    spark_image=${spark_image}":v3.1.1"
    mainApplicationFile=local:///opt/spark/examples/jars/spark-examples_2.12-3.1.1.jar

    deploy_run_script='/opt/spark/work-dir/run.sh -Enative31 -ntestfree -C2 -c2 -M6 -m2  -i1 -x7 -d1 -a10000 -tfree'
  elif test $action = 'native33' -o $action = 'deploy33'; then
    spark_image=${spark_image}":v3.3-prom"
    mainApplicationFile=local:///opt/spark/examples/jars/spark-examples_2.12-3.3.0-SNAPSHOT.jar
    deploy_run_script='/opt/spark/work-dir/run.sh -Enative33 -ntestfree -C2 -c2 -M6 -m2  -i1 -x7 -d1 -a10000 -tfree'
  else
    echo "没有符合的条件"
  fi

}

##############################################################################

exec_() {

  if test $action = 'operator'; then
    test_spark_application
  elif test $action = 'native31' -o $action = 'native33'; then
    if [ $isRemote ]; then
      test_native_in_pod
    else
      test_spark_native
    fi
  elif test $action = 'buildQ'; then
    install_volcano_queue
  elif test $action = 'deployvc'; then
    install_volcano
  elif test $action = 'deployoperator'; then
    install_spark_operator
  elif test $action = 'deployvk'; then
    install_virtual_node
  elif test $action = 'deploy33' -o $action = 'deploy31'; then
    deploy_spark
  else
    echo "没有符合的条件"
  fi
}
###########################################################################
action=""
while getopts ":n:c:m:C:M:i:x:d:r:s:w:t:a:p:E:u:" opt; do
  case $opt in
  n)
    jobname=$OPTARG
    ;;
  E)
    action=$OPTARG
    ;;
  c)
    cpu=$OPTARG
    executor_core=$cpu
    ;;
  C)
    driver_core=$OPTARG
    ;;
  m)
    memory=$OPTARG
    executor_mem=$memory
    ;;
  M)
    driver_mem=$OPTARG
    ;;
  i)
    minExecutors=$OPTARG
    ;;
  x)
    maxExecutors=$OPTARG
    ;;
  d)
    index=$OPTARG
    ;;
  s)
    sleepTime="$OPTARG"
    ;;
  r)
    reclaimable=$OPTARG
    ;;
  w)
    weight=$OPTARG
    ;;
  t)
    choseTenentQueue $OPTARG
    ;;
  a)
    arg=$OPTARG
    ;;
  p)
    profile=$OPTARG
    ;;
  u)
    submit_mode=$OPTARG
    if test $submit_mode = 'cluster'; then
      submitInDriver=true
    elif test $submit_mode = 'client'; then
      submitInDriver=false
    else
      echo "Unknown parameter"
    fi

    ;;
  ?)
    echo "Unknown parameter"
    exit 1
    ;;
  esac
done

init_env
exec_
