def proc = ['/bin/bash', '-c', "cat prom-debug.yaml|grep  'image:' |sed 's/image://g'|sed 's/^[ \t]*//g'|sed 's/\"//g'|sort|uniq"].execute()

// def run_command = "/bin/bash -c \"cat prom-debug.yaml|grep 'image:'|sed 's/image://g'|sed 's/^[ \\t]*//g'|sed 's/\\\"//g'|sort|uniq\""      
// println run_command
def result = proc.text
 imagesUrl = result.split("\n")
for (String imageUrl in imagesUrl) {
   
                   String imageName = imageUrl.substring(imageUrl.lastIndexOf("/")+1)
                   String image = imageName
                   String imagePrefix = ""
                   if (imageUrl.lastIndexOf("/") >0){
                      imagePrefix = imageUrl.substring(0,imageUrl.lastIndexOf("/"))
                      if (imagePrefix.lastIndexOf("/") >0){
                         imagePrefix =  imagePrefix.substring(imagePrefix.lastIndexOf("/")+1 )
                      }
                   }
                    if (imagePrefix.length() >0) {
                      image = imagePrefix + "/"+imageName
                    }
  println(imageName)
  println(image)

}

