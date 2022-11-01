#!groovy
pipeline {
    agent {
        kubernetes {
      yaml '''
spec:
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  containers:
  - name: "mytest-monitor"
    command:
    - "cat"
    image: "${image_registry_url}/jenkinsslave/mytest:alpine"
    imagePullPolicy: "Always"
    resources:
      limits:
        memory: "4096Mi"
        cpu: "4000m"
      requests:
        memory: "4096Mi"
        cpu: "4000m"
    tty: true
    volumeMounts:
    - mountPath: "/jenkins-common"
      name: "volume-0"
      readOnly: false
    - mountPath: "/var/run/docker.sock"
      name: "dockersock"
  - name: "jnlp"
    image: "jenkins/inbound-agent:4.3-4"
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
    volumeMounts:
    - mountPath: "/jenkins-common"
      name: "volume-0"
      readOnly: false
  volumes:
  - name: "volume-0"
    persistentVolumeClaim:
      claimName: "jenkins-common"
      readOnly: false
  - name: "dockersock"
    hostPath:
      path: "/var/run/docker.sock"
'''
        }
    }
    stages {
        stage('checkout mytest-monitor helm charts ') {
          steps {
          container('mytest-monitor') {
          timestamps {
            checkout([$class: 'GitSCM', branches: [[name: "${mytest_charts_branch}"]], doGenerateSubmoduleConfigurations: false, extensions: [], submoduleCfg: [], userRemoteConfigs: [[credentialsId: "${credential}", url: 'https://github.com/mytest/mytest-charts.git']]])

            script {
              withCredentials([file(credentialsId: 'mytesteks-awsuser', variable: 'aws')]) {
                sh 'mkdir -p ~/.aws'
                sh 'cat $aws > ~/.aws/credentials'
              }

              sh 'aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${image_registry_url}'
            }
          }
          }
          }
        }

        stage('push helm charts and images') {
          when { expression { return params.helm_charts_upload_stage_enabled } }
          steps {
        container('mytest-monitor') {
          timestamps {
            script {
              helmCharts = "${helm_charts}".split('\n')
              for (String helmchart in helmCharts) {
                println(helmchart)
                def _helm_package = 'helm package ./mytest-monitor/' + helmchart + " --app-version=${chart_version} --version=${chart_version}"
                sh returnStdout: true ,script: _helm_package
                def helmchartpackage = helmchart + "-${chart_version}.tgz"
                def awscp = [:]
                awscp['global_template'] = {
                  withAWS(region:'us-east-1', credentials:'aws_global_s3_cp') {
                    s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:helmchartpackage, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/charts/", acl:'PublicRead')
                  }
                }
                awscp['cn_template'] = {
                  withAWS(region:'cn-north-1', credentials:'aws_cn_s3_cp') {
                    s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:helmchartpackage, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/charts/", acl:'PublicRead')
                  }
                }
                parallel awscp
                withCredentials([[$class: 'UsernamePasswordMultiBinding', credentialsId: '${helm-credential}', usernameVariable: 'USERNAME', passwordVariable: 'PASSWORD']]) {
                  def _curl = 'curl -v -F file=@' + helmchart + "-${chart_version}.tgz -u ${env.USERNAME}:${env.PASSWORD} http://devops-nexus:8081/service/rest/v1/components?repository=mytest-helm"
                  sh returnStdout: true ,script: _curl
                }

                // sh 'aws ecr get-login-password --region us-weimage_registry_urlst-2 | docker login --username AWS --password-stdin ${image_registry_url}'
               // withDockerRegistry(credentialsId: 'registry-mytest-io', url: 'https://${image_registry_url}') {
                  sh 'aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${image_registry_url}'
                  def _helm_template = 'helm template  --debug --dry-run  --create-namespace -n default -f ./mytest-monitor/' + helmchart + '/values-'+ helmchart + '.yaml ' + helmchart + ' ./mytest-monitor/' + helmchart + ' >' + helmchart + '-debug.yaml'
                  sh returnStdout: true ,script: _helm_template
                  //def cat_debug= "cat ./" + helmchart + "-debug.yaml"
                  //def debug_yaml = sh returnStdout: true ,script: cat_debug
                  
                  def run_command = "/bin/bash -c \"cat ./" + helmchart + "-debug.yaml|grep 'image:'|sed 's/image://g'|sed 's/^[ \\t]*//g'|sed 's/\\\"//g'|sort|uniq\""

                  def filelist = sh returnStdout: true ,script: run_command
                  imagesUrl = filelist.split('\n')
                  println(filelist)
                  for (String imageUrl in imagesUrl) {
                    String imageName = imageUrl.substring(imageUrl.lastIndexOf('/') + 1)
                    String image = imageName
                    String noTagImage = image.substring(0, image.lastIndexOf(':'))
                    String imagePrefix = ''
                    String imageNs = "${image_registry_ns}"
                    if (imageUrl.lastIndexOf('/') > 0) {
                      imagePrefix = imageUrl.substring(0, imageUrl.lastIndexOf('/'))
                      if (imagePrefix.lastIndexOf('/') > 0) {
                        imagePrefix =  imagePrefix.substring(imagePrefix.lastIndexOf('/') + 1)
                      }
                    }
                    String imageTar =  imageName + '.tar'
                    String imageRepo = imageNs + '/' + noTagImage
                    if (imagePrefix.length() > 0 && imagePrefix != noTagImage) {
                      image = imageNs + '/' + imagePrefix + '-' + imageName
                      imageTar =  imagePrefix + '-' + imageName + '.tar'
                      imageRepo = imageNs + '/' + imagePrefix + '-' + noTagImage
                    }else {
                      image = imageNs + '/' + imageName
                      imageTar = imageName + '.tar'
                      imageRepo = imageNs + '/' + noTagImage
                    }

                    def _pull = 'docker pull ' + imageUrl
                    sh returnStdout: true ,script: _pull

                    def _tag = 'docker tag ' + imageUrl + " ${image_registry_url}/" + image
                    sh returnStdout: true ,script: _tag
                    

                    def _create_repo = "aws ecr create-repository --repository-name " + imageRepo
                    sh returnStatus: true ,script: _create_repo
                    
                    def _push = "docker push ${image_registry_url}/" + image
                    sh returnStdout: true ,script: _push

                    def _save = 'docker save -o ' + imageTar + " ${image_registry_url}/" + image
                    sh returnStdout: true ,script: _save

                    awscp['global_template'] = {
                      withAWS(region:'us-east-1', credentials:'aws_global_s3_cp') {
                        s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:imageTar, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/images/", acl:'PublicRead')
                      }
                    }
                    awscp['cn_template'] = {
                      withAWS(region:'cn-north-1', credentials:'aws_cn_s3_cp') {
                        s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:imageTar, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/images/", acl:'PublicRead')
                      }
                    }
                    parallel awscp
                } // for  (String imageUrl in imagesUrl) end
              //}  //withDockerRegistry end
              }
              } //script end
          }// timestamps end
        }  //container end
          }  // steps end
        } // stage end

        stage('push add-on images') {
          when { expression { return params.helm_charts_upload_stage_enabled } }
          steps {
        container('mytest-monitor') {
          timestamps {
            script {
              //  withDockerRegistry(credentialsId: 'registry-mytest-io', url: 'https://${image_registry_url}') {
                  sh 'aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${image_registry_url}'
                  images = "${add_on_images}".split('\n')
                  for (String imageUrl in images) {
                  String imageName = imageUrl.substring(imageUrl.lastIndexOf('/') + 1)
                  String image = imageName
                  String noTagImage = image.substring(0, image.lastIndexOf(':'))
                  String imagePrefix = ''
                  String imageNs = "${image_registry_ns}"
                  if (imageUrl.lastIndexOf('/') > 0) {
                    imagePrefix = imageUrl.substring(0, imageUrl.lastIndexOf('/'))
                    if (imagePrefix.lastIndexOf('/') > 0) {
                      imagePrefix =  imagePrefix.substring(imagePrefix.lastIndexOf('/') + 1)
                    }
                  }
                    String imageRepo = imageNs + '/' + noTagImage
                    if (imagePrefix.length() > 0 && imagePrefix != noTagImage) {
                      image = imageNs + '/' + imagePrefix + '-' + imageName
                      imageTar =  imagePrefix + '-' + imageName + '.tar'
                      imageRepo = imageNs + '/' + imagePrefix + '-' + noTagImage
                    }else {
                      image = imageNs + '/' + imageName
                      imageTar = imageName + '.tar'
                      imageRepo = imageNs + '/' + noTagImage
                    }

                  def _pull = 'docker pull ' + imageUrl
                  sh returnStdout: true ,script: _pull

                  def _tag = 'docker tag ' + imageUrl + " ${image_registry_url}/" + image
                  sh returnStdout: true ,script: _tag
                  
                  def _create_repo = "aws ecr create-repository --repository-name " + imageRepo
                  sh returnStatus: true ,script: _create_repo

                  def _push = "docker push ${image_registry_url}/" + image
                  sh returnStdout: true ,script: _push
                      
                
                  def _save = 'docker save -o ' + imageTar + " ${image_registry_url}/" + image
                  sh returnStdout: true ,script: _save
                  def awscp = [:]
                  awscp['global_template'] = {
                    withAWS(region:'us-east-1', credentials:'aws_global_s3_cp') {
                        s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:imageTar, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/images/", acl:'PublicRead')
                    }
                  }
                  awscp['cn_template'] = {
                    withAWS(region:'cn-north-1', credentials:'aws_cn_s3_cp') {
                        s3Upload(pathStyleAccessEnabled: true, payloadSigningEnabled: true, file:imageTar, bucket:'public.mytest.io', path:"mytest/$release_type/$tag/images/", acl:'PublicRead')
                    }
                  }
                  parallel awscp
                } // for  (String imageUrl in imagesUrl) end
             // }  //withDockerRegistry end
              } //script end
          }// timestamps end
        }  //container end
          }  // steps end
        } // stage end
        stage('build and push spark-api image') {
          steps {
          container('mytest-monitor') {
          timestamps {
            checkout([$class: 'GitSCM', branches: [[name: "${branch}"]], doGenerateSubmoduleConfigurations: false, extensions: [], submoduleCfg: [], userRemoteConfigs: [[credentialsId: "${credential}", url: 'https://github.com/mytest/spark-measure.git']]])
            script {
              sh "cd measure-exporter && docker build -t ${image_registry_url}/${image_registry_ns}/sparkapi:${tag_sparkapi} ."
              //withDockerRegistry(credentialsId: 'registry-mytest-io', url: 'https://${image_registry_url}') {
              sh 'aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${image_registry_url}'
            
              def _create_repo = "aws ecr create-repository --repository-name ${image_registry_ns}/sparkapi"
              sh returnStatus: true ,script: _create_repo
              sh "docker push ${image_registry_url}/${image_registry_ns}/sparkapi:${tag_sparkapi}"
             // }
            }
          }
          }
          }
        }
    }  //stages end
}  //pipeline end
