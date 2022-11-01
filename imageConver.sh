#!/bin/bash
IFS=''
private_registry='429636537981.dkr.ecr.us-west-2.amazonaws.com'
private_repo='kyligence'
original_value_file=./kube-prometheus-stack/values-prometheus.yaml
convert_value_file=private-values.yaml

read_parse() {
    filename=$1
    flag=0
    registry=''
    repository=''
    tag=''
    # read content line by line
    cat $filename | while read -r OLINE || [[ -n ${OLINE} ]]; do

        LINE=$(echo "$OLINE" | sed 's/^[ ]*//g')
        if [ $flag == 0 ]; then
            # if line is start with 'image:'
            if [ "$(echo "$LINE" | grep "image:")" != "" ]; then
                image=''
                flag=1
                registry=''
                repository=''
                tag=''
                imageValue=$(echo "$LINE" | awk -F " " '{print $2}')

                if [ ! -z "$imageValue" ]; then

                    tagsplit=":"
                    #containtag=$(echo $imageValue | grep ':')
                    if [[ $imageValue == *$tagsplit* ]]; then
                        flag=0
                        image=$imageValue
                        replaceVar=$(convertImageRepoUrl $imageValue '')
                        # remove original line text value start with 'image:' and connact with replace image repo url
                        OLINE=$(echo ${OLINE/image*/}'image: '$replaceVar) 
                        dealImage $image
                    else
                        repository=$imageValue
                        replaceVar=$(convertImageRepoUrl $imageValue '')
                        OLINE=$(echo ${OLINE/image*/}'image: '$replaceVar)
                    fi
                fi

            fi
        elif [ $flag == 1 ]; then

            if [ "$(echo "$LINE" | grep -E "^registry:")" != "" ]; then
                registry=$(echo "$LINE" | awk -F " " '{print $2}')
                OLINE=$(echo ${OLINE/registry*/registry: $private_registry})

            elif [ "$(echo "$LINE" | grep -E "^repository:")" != "" ]; then
                repository=$(echo "$LINE" | awk -F " " '{print $2}')

                replaceVar=$(convertImageRepoUrl $repository $registry)

                OLINE=$(echo ${OLINE/repository*/}'repository: '$replaceVar)

            elif [ "$(echo "$LINE" | grep -E "^tag:")" != "" ]; then
                tag=$(echo "$LINE" | awk -F " " '{print $2}')

            else
                flag=0
                if [ ! -z "$registry" ] && [ ! -z "$repository" ]; then
                    repository="$registry/$repository"
                fi
                if [ ! -z "$repository" ] && [ ! -z "$tag" ]; then
                    image="$repository:$tag"
                    dealImage $image
                fi

            fi
        fi
        echo "$OLINE" >> ${convert_value_file}
    done
}

#can do any aciton with related image
dealImage() {
    image=$1

    imageNameTag=$(echo ${image##*/})
    imageTag=$(echo ${imageNameTag##*:})
    imageName=$(echo ${imageNameTag%:*})

    imageRepoUrl=''
    imageRepo=''
    if [[ $image == */* ]]; then
        imageRepoUrl=$(echo ${image%/*})
        imageRepo=$(echo ${imageRepoUrl##*/})
    fi

    if [ "$imageRepo" != "" ] && [ "$imageRepo" != "$imageName" ]; then
        imageNameTag="$imageRepo-$imageName:$imageTag"
    fi
    # echo $imageNameTag
    echo 'docker pull '$image
    #$('docker pull '$image)
    echo "docker tag  $image $private_registry/$private_repo/$imageNameTag"
    #$("docker tag  $image $private_registry/$private_repo/$imageNameTag")
    echo "docker push   $private_registry/$private_repo/$imageNameTag"
    #$("docker push  $private_registry/$private_repo/$imageNameTag")
    #echo 'docker save -o '$imageName-$imageTag'.tar ' $image
}

convertImageRepoUrl() {
    # echo $1
    image=$1
    registry=$2

    imageName=$(echo ${image##*/})
    imageRepoUrl=$(echo ${image%/*})
    imageRepo=$(echo ${imageRepoUrl##*/})

    if [ "$imageRepo" != "$imageName" ]; then
        imageName="$imageRepo-$imageName"
    fi
    imageRepoUrl="$private_registry/$private_repo/$imageName"
    if [ "$registry" != "" ]; then
        imageRepoUrl="$private_repo/$imageName"
    fi

    echo $imageRepoUrl
    return $?
}


read_parse $original_value_file
