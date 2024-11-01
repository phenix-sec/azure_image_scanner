#!/bin/bash

#MUST CHANGE
imagesfile="images_marketplace.txt"
containerurl="https://myblobname.blob.core.windows.net/containername"   #Storage account container for data storage
sastoken="?sp=racwlmeo&st=2024-04-09T08:16:43Z&se=2024-07-09T16:16:43Z&spr=https&sv=2022-11-02&sr=c&sig=ge9lF1NC3vOl1XbY%2FgkYWPq7yuHINywBMWKHks7pcFs%3D"   #Required to access the container

#install requirements
apt-get -qq update
apt-get install jq -y
wget https://aka.ms/downloadazcopy-v10-linux
tar -xvf downloadazcopy-v10-linux
mv ./azcopy_linux_amd64_*/azcopy .
chmod 755 azcopy
rm -f downloadazcopy-v10-linux
rm -rf ./azcopy_linux_amd64_*/

#other variables
resourcegroup=`curl -s -H Metadata:True http://169.254.169.254/metadata/instance?api-version=2021-02-01 | jq -r '"\(.compute.resourceGroupName)"'`
vmname=`hostname`
datadisk="/tmp/storage" #temp location to store data on VM
skip_mount=0
starting_line=1 #change only if you want to start from a different line in imagesfile; default value of 1 starts from the beginning of imagesfile
urn_column=5 #URN column number from images file (default 5)
publisher_column=3 #provider column number from images file (default 3)

#initial disks on VM
init_disks=`lsblk -rno "NAME,TYPE" | grep disk | wc -l`

#parse images file to get URNs
marketplace_images=`cat $imagesfile | cut -d " " -f $urn_column`
#get the number of images from imagesfile
size=`echo "$marketplace_images" | wc -l`



for ((line=$starting_line;line<=$size;line++)); do
	line_last2=$(( ${line} - 2 ))
	line_last1=$(( ${line} - 1 ))
	line_next1=$(( ${line} + 1 ))
	line_next2=$(( ${line} + 2 ))
	image_current=`echo "$marketplace_images" | sed -n ${line}p`
	image_next1=`echo "$marketplace_images" | sed -n ${line_next1}p`
	image_next2=`echo "$marketplace_images" | sed -n ${line_next2}p`

	echo ""
	echo "NR. "$line
	echo "IMAGE $image_current"

	#initial create disk and attach, only runs once
	if [ $line -eq $(($starting_line)) ]; then
		echo -e "\nINITIAL CREATE and ATTACH !!!!!!!!!!"
		az disk create -g $resourcegroup -n disk${vmname}$line --image-reference $image_current --zone 1 --security-type Standard --only-show-errors &> /dev/null
		echo -e "Created Disk $line"
		az disk create -g $resourcegroup -n disk${vmname}$line_next1 --image-reference $image_next1 --zone 1 --security-type Standard --only-show-errors &> /dev/null
		echo -e "Created Disk $line_next1"
		sleep 2
		diskId=$(az disk show -g $resourcegroup -n disk${vmname}$line --query 'id' -o tsv)
		az vm disk attach -g $resourcegroup --vm-name $vmname --name $diskId &> /dev/null
		echo -e "Attached Disk $line"
	fi


	#delete line_last2
	if [ $line -ge $(($starting_line+2)) ]; then
		#wait for disk to be detached before deleting
		while [[ `az disk show -n disk${vmname}$line_last2 -g $resourcegroup | jq -r '"\(.diskState)"'` = "Attached" ]]; do sleep 5; echo "WAITING DISK DETACHMENT"; done
		echo -e "\nDELETE disk $line_last2 !!!!!!!!!!"
		az disk delete --name disk${vmname}$line_last2 --resource-group $resourcegroup -y --no-wait true
	fi


	#create line_next2
	echo -e "\nCREATE disk $line_next2 !!!!!!!!!!"
	az disk create -g $resourcegroup -n disk${vmname}$line_next2 --image-reference $image_next2 --zone 1 --security-type Standard --no-wait --only-show-errors


	#mount and scan
	if [ $skip_mount -eq 0 ]; then
		#mount line
		echo -e "\nMOUNT disk $line !!!!!!!!!!"
		#check if current disk attached
		az disk show -n disk${vmname}$line -g $resourcegroup | jq -r '"\(.diskState)"'
		while [[ `az disk show -n disk${vmname}$line -g $resourcegroup | jq -r '"\(.diskState)"'` != "Attached" ]]; do 
			sleep 5; echo "DISK NOT YET ATTACHED"; 
			if [[ `az disk show -n disk${vmname}$line -g $resourcegroup | jq -r '"\(.diskState)"'` != "Attached" ]];then 
				diskId=$(az disk show -g $resourcegroup -n disk${vmname}$line --query 'id' -o tsv); 
				az vm disk attach -g $resourcegroup --vm-name $vmname --name $diskId; 
				echo "DISK ATTACHED"; 
			fi; 
		done
		publisher=`cat $imagesfile | cut -d " " -f $publisher_column | sed -n ${line}p`
		echo -e "\nPUBLISHER name: $publisher"
		#check if previous disk detached
		if [ $line -ge $(($starting_line+1)) ]; then
			while [[ `az disk show -n disk${vmname}$line_last1 -g $resourcegroup | jq -r '"\(.diskState)"'` = "Attached" ]]; do sleep 5; echo "MULTIPLE DISKS ATTACHED"; done
		fi
		#check if current disk partitions appear
		counter=10
		while [ `lsblk -rno "NAME,TYPE" | grep disk | wc -l` -le $init_disks ] && [ $counter -ge 1 ]; do sleep 3; echo "DISK NOT YET ATTACHED"; ((counter-=1)); done
		az disk show -n disk${vmname}$line -g $resourcegroup | jq -r '"\(.diskState)"'
		
		#search gigabit size volumes
		echo -e "\nATTACHED DISKS:"
		lsblk -o "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"
		part=`lsblk | grep "\─sd" | grep G | grep -v "/" | cut -d " " -f 1 | sed "s/^.\{2\}//"`
		echo ""
		echo GIGABIT PARTITIONS: $part

		#mount only if bigger than 1.8GB and smaller than 260GB
		if [ `lsblk | grep "\─sd" | grep G | grep -v "/" | cut -d " " -f 1 | sed "s/^.\{2\}//" | wc -l` -ge 1 ]; then
			while read -r volume <&3; do
				if [ "$(echo "`lsblk -rno "NAME,SIZE" | grep "${volume} " | cut -d " " -f 2 | grep G | cut -d "G" -f 1` > 1.8" | bc)" -eq 1 ] && [ "$(echo "`lsblk -rno "NAME,SIZE" | grep "${volume} " | cut -d " " -f 2 | grep G | cut -d "G" -f 1` < 260" | bc)" -eq 1 ]; then
					echo ""
					echo Attempting mount of "$volume" size "`lsblk -rno "NAME,SIZE" | grep "${volume} " | cut -d " " -f 2 | grep G | cut -d "G" -f 1`"G

					#mount LVM Volume
					if [ "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`" = "LVM2_member" ];then 
						echo ""
						echo FILESYSTEM TYPE: "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`"
						vgchange --refresh
						vgchange -ay
						lvscan
						partitions=`lvscan | grep ACTIVE | grep -i -v "swap\|crashlv" | cut -d "'" -f 2`;
						echo "" | tee -a partitions.txt
						echo PAARTITIONS: | tee -a partitions.txt
						echo "$partitions" | tee -a partitions.txt
						echo "" | tee -a partitions.txt
						mount_point=/mnt/$publisher/image${line}_$volume
						storage=$datadisk/OUTPUT/$publisher/image${line}_$volume
						for i in $(eval echo "{1..`echo "$partitions" | wc -l`}"); do
							mkdir -p $mount_point/$i
							mkdir -p $storage/$i

							if mount `echo "$partitions" | sed -n ${i}p` $mount_point/$i; then echo MOUNT_SUCCESSFUL; else echo MOUNT_NOT_SUCCESSFUL;fi

							#log data
							echo "`echo "$partitions" | sed -n ${i}p`" | tee -a partitions.txt
							ls -la $mount_point/$i | tee -a partitions.txt
						done;
						echo $image_current > $storage/azure_image_id.txt

						#SCAN MOUNTED FILESYSTEM
						echo -e "\nSCANNING FOR SENSITIVE FILES (takes a while)"
						find $mount_point \( ! -path "$mount_point/*/proc/*" -a ! -path "$mount_point/*/Windows/*" -a ! -path "$mount_point/*/usr/*" -a ! -path "$mount_point/*/sys/*" -a \
								! -path "$mount_point/*/mnt/*" -a ! -path "$mount_point/*/dev/*" -a ! -path "$mount_point/*/tmp/*" -a ! -path "$mount_point/*/sbin/*" -a \
								! -path "$mount_point/*/bin/*" -a ! -path "$mount_point/*/lib*" -a ! -path "$mount_point/*/boot/*" -a ! -path "$mount_point/*/Program Files/*" -a \
								! -path "$mount_point/*/Program Files \(x86\)/*" \) \
								-not -empty >> $storage/all_files_cloud_quarry.txt
						for item in $(find $mount_point \( ! -path "$mount_point/*/Windows/*" -a ! -path "$mount_point/*/Program Files/*" -a ! -path "$mount_point/*/Program Files \(x86\)/*" \) -size -25M \
							\( -name ".aws" -o -name ".ssh" -o -name "credentials.xml" -o -path "*secrets/master.key" -o -ipath "*secrets/hudson.util.Secret" \
							-o -name "secrets.yml" -o -name "config.php" -o -name "_history" -o -ipath "*.azure/accessToken.json" -o -name ".kube" -o -iwholename "/var/run/secrets/kubernetes.io/serviceaccount/token" \
							-o -name "autologin.conf" -o -iname "web.config" -o -name ".env" \
							-o -name ".git" \) -not -empty)
						do
							echo "[+] Found $item. Copying to output..."
							save_name_item=${item:1}
							save_name_item=${save_name_item////\\}
							cp -r $item $storage/${save_name_item}
						done

						#copy files to azure storage
						echo "NR. "$line &>> azurecopy.txt
						./azcopy copy --recursive $storage ${containerurl}/${vmname}/${publisher}${sastoken} &>> azurecopy.txt
						rm -R $storage &>> /dev/null

						echo -e "SCAN FINISHED"
						for i in $(eval echo "{1..`echo "$partitions" | wc -l`}"); do
							umount $mount_point/$i
						done;
						vgchange -an
						lvscan
					
					#mount UFS Volume
					elif [ "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`" = "ufs" ]; then 
						echo ""
						echo FILESYSTEM TYPE: "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`"
						partitions="/dev/$volume"
						echo "" | tee -a partitions.txt
						echo PAARTITIONS: | tee -a partitions.txt
						echo "$partitions" | tee -a partitions.txt
						echo "" | tee -a partitions.txt
						mount_point=/mnt/$publisher/image${line}_$volume
						storage=$datadisk/OUTPUT/$publisher/image${line}_$volume
						mkdir -p $mount_point
						mkdir -p $storage
						echo $image_current > $storage/azure_image_id.txt
						
						if mount -r -t ufs -o ufstype=ufs2 $partitions $mount_point; then echo MOUNT_SUCCESSFUL; else echo MOUNT_NOT_SUCCESSFUL;fi
					
						#log data
						ls -la $mount_point | tee -a partitions.txt

						#SCAN MOUNTED FILESYSTEM
						echo -e "\nSCANNING FOR SENSITIVE FILES (takes a while)"
						find $mount_point \( ! -path "$mount_point/proc/*" -a ! -path "$mount_point/Windows/*" -a ! -path "$mount_point/usr/*" -a ! -path "$mount_point/sys/*" -a \
								! -path "$mount_point/mnt/*" -a ! -path "$mount_point/dev/*" -a ! -path "$mount_point/tmp/*" -a ! -path "$mount_point/sbin/*" -a \
								! -path "$mount_point/bin/*" -a ! -path "$mount_point/lib*" -a ! -path "$mount_point/boot/*" -a ! -path "$mount_point/Program Files/*" -a \
								! -path "$mount_point/Program Files \(x86\)/*" \) \
								-not -empty >> $storage/all_files_cloud_quarry.txt
						for item in $(find $mount_point \( ! -path "$mount_point/Windows/*" -a ! -path "$mount_point/Program Files/*" -a ! -path "$mount_point/Program Files \(x86\)/*" \) -size -25M \
							\( -name ".aws" -o -name ".ssh" -o -name "credentials.xml" -o -path "*secrets/master.key" -o -ipath "*secrets/hudson.util.Secret" \
							-o -name "secrets.yml" -o -name "config.php" -o -name "_history" -o -ipath "*.azure/accessToken.json" -o -name ".kube" -o -iwholename "/var/run/secrets/kubernetes.io/serviceaccount/token" \
							-o -name "autologin.conf" -o -iname "web.config" -o -name ".env" \
							-o -name ".git" \) -not -empty)
						do
							echo "[+] Found $item. Copying to output..."
							save_name_item=${item:1}
							save_name_item=${save_name_item////\\}
							cp -r $item $storage/${save_name_item}
						done

						#copy files to azure storage
						echo "NR. "$line &>> azurecopy.txt
						./azcopy copy --recursive $storage ${containerurl}/${vmname}/${publisher}${sastoken} &>> azurecopy.txt
						rm -R $storage &>> /dev/null

						echo -e "SCAN FINISHED"
						umount -r -t ufs $mount_point
					
					#if SWAP then skip
					elif [ "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`" = "swap" ]; then 
						echo "PARTITION IS PROBABLY SWAP"
					
					#if UNKNOWN then skip
					elif [ "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`" = "" ]; then 
						echo "UNKNOWN PARTITION FSTYPE"
					
					#mount other Volume types (eg. ext, ntfs, efs)
					else
						echo ""
						echo FILESYSTEM TYPE: "`lsblk -rno NAME,FSTYPE | grep "${volume} " | cut -d " " -f 2`"
						partitions="/dev/$volume"
						echo "" | tee -a partitions.txt
						echo PAARTITIONS: | tee -a partitions.txt
						echo "$partitions" | tee -a partitions.txt
						echo "" | tee -a partitions.txt
						mount_point=/mnt/$publisher/image${line}_$volume
						storage=$datadisk/OUTPUT/$publisher/image${line}_$volume
						mkdir -p $mount_point
						mkdir -p $storage
						echo $image_current > $storage/azure_image_id.txt

						if mount $partitions $mount_point; then echo "MOUNT_SUCCESSFUL"; else echo "MOUNT_NOT_SUCCESSFUL";fi

						#log data
						ls -la $mount_point | tee -a partitions.txt

						#SCAN MOUNTED FILESYSTEM
						echo -e "\nSCANNING FOR SENSITIVE FILES (takes a while)"
						find $mount_point \( ! -path "$mount_point/proc/*" -a ! -path "$mount_point/Windows/*" -a ! -path "$mount_point/usr/*" -a ! -path "$mount_point/sys/*" -a \
								! -path "$mount_point/mnt/*" -a ! -path "$mount_point/dev/*" -a ! -path "$mount_point/tmp/*" -a ! -path "$mount_point/sbin/*" -a \
								! -path "$mount_point/bin/*" -a ! -path "$mount_point/lib*" -a ! -path "$mount_point/boot/*" -a ! -path "$mount_point/Program Files/*" -a \
								! -path "$mount_point/Program Files \(x86\)/*" \) \
								-not -empty >> $storage/all_files_cloud_quarry.txt
						for item in $(find $mount_point \( ! -path "$mount_point/Windows/*" -a ! -path "$mount_point/Program Files/*" -a ! -path "$mount_point/Program Files \(x86\)/*" \) -size -25M \
							\( -name ".aws" -o -name ".ssh" -o -name "credentials.xml" -o -path "*secrets/master.key" -o -ipath "*secrets/hudson.util.Secret" \
							-o -name "secrets.yml" -o -name "config.php" -o -name "_history" -o -ipath "*.azure/accessToken.json" -o -name ".kube" -o -iwholename "/var/run/secrets/kubernetes.io/serviceaccount/token" \
							-o -name "autologin.conf" -o -iname "web.config" -o -name ".env" \
							-o -name ".git" \) -not -empty)
						do
							echo "[+] Found $item. Copying to output..."
							save_name_item=${item:1}
							save_name_item=${save_name_item////\\}
							cp -r $item $storage/${save_name_item}
						done
						
						#copy files to azure storage
						echo "NR. "$line &>> azurecopy.txt
						./azcopy copy --recursive $storage ${containerurl}/${vmname}/${publisher}${sastoken} &>> azurecopy.txt
						rm -R $storage &>> /dev/null
						
						echo -e "SCAN FINISHED"
						umount $mount_point
					fi;
				else
					echo ""
					echo "PARTITION SIZE OUTSIDE LIMITS: $volume"
				fi; 
			done 3< <(echo "$part")
		else
			echo -e "\nNO GIGABIT PARTITIONS"
		fi;
		
		#detach line
		if [ $line -ge $(($starting_line)) ]; then
			echo -e "\nDETACH disk $line !!!!!!!!!!"
			#while [[ `az disk show -n disk$line -g $resourcegroup | jq -r '"\(.diskState)"'` != "Attached" ]]; do sleep 5; echo "DISK NOT ATTACHED"; done
			az vm disk detach -g $resourcegroup --vm-name $vmname -n disk${vmname}$line --force-detach >>logs.txt
		fi
	else
		echo "MOUNT SKIPPED";
	fi

	skip_mount=0

	#attach line_next1
	echo -e "\nATTACH disk $line_next1 !!!!!!!!!!"
	if az vm image show --urn $image_next1 &>/dev/null; then 
		echo "IMAGE ACTIVE"; 
		counter=10
		#wait for disk to be created before attaching, otherwise skip after 30s
		while [[ `az disk show -n disk${vmname}$line_next1 -g $resourcegroup | jq -r '"\(.diskState)"'` != "Unattached" ]] && [ $counter -ge 1 ]; do sleep 3; echo "WAITING DISK CREATION";if [ $counter -eq 1 ]; then skip_mount=1; fi; ((counter-=1)); done
		diskId=$(az disk show -g $resourcegroup -n disk${vmname}$line_next1 --query 'id' -o tsv)
		az vm disk attach -g $resourcegroup --vm-name $vmname --name $diskId >>logs.txt &
	else 
		echo "IMAGE DEPRECATED NR $line_next1"; 
		echo "Skipping image $line_next1"; 
		skip_mount=1
	fi

done