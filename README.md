# Azure Image Scanner (AIS)

**Azure Image Scanner** can be used to scan **Community** and **Marketplace** images on Azure in order to extract files with potential secrets. More info in the blogpost:
- https://securitycafe.ro/2024/10/27/azure-cloudquarry-searching-for-secrets-in-public-vm-images/

## Features

Some of the functionalities and constraints of the tool:
- First of all, the process for deploying and attaching Managed Disks is different between marketplace and community images. That is why there are two different AIS scripts.
- A Managed Disk created from a community image can only be used and attached to a VM within the same region as the community image. This Azure restriction means that you need to deploy a VM in each region to scan all community images. This restriction only applies to community images, it does not apply to marketplace images.
- It only scans volumes that are bigger than 1.8 GB and smaller than 260 GB in order to avoid wasting time and costs.
- It supports attaching and scanning multiple types of volumes including LVM, EXT, NTFS, UFS, XFS, BTRFS. This was one of the trickiest parts and required extensive troubleshooting.
- The sensitive files extracted from images are stored on a Storage Accounts container using a SAS token.
- It extracts sensitive files with potential secrets: configuration files, SSH keys, Jenkins secrets, Kubernetes tokens, environment variables, AWS/Azure keys, and Git repositories.
- Cost: It cost us about 90 EUR to scan 15.000 images
- Speed: It took us about 9 days to scan 15.000 images with 5 VMs concurrently running AIS.

## Prereq.

An Azure Storage Account container is required in order to store the extracted data. A SAS token must be generated for AIS to access the container.

## Generate Images File

Generating the **Community Images** file is easy as the Azure Portal allows "Export to CSV" and the exported file can be used with AIS. Link to Azure Community Images:
- https://portal.azure.com/#browse/Microsoft.Compute%2Flocations%2FcommunityGalleries%2Fimages

The following command generates the list of **Marketplace Images** ready to be used when running AIS
```sh
#export marketplace images to file (removes multiple spaces and table headers)
az vm image list --all -o table | sed 's/  */ /g' | tail -n +3 > images_marketplace.txt
```

## Usage

Initiating a scan with AIS is a rather simple process that includes the following steps.

1. Deploy a Debian/Ubuntu based VM in Azure. The AIS script should run on any size VM that is Debian/Ubuntu based.

2. Copy the AIS script along with the exported images file to any location on the VM.

3. Edit the following variables inside the AIS script. You will need to create an Azure Storage Account container and a SAS token, so that AIS can store the extracted data.

```sh
#MUST CHANGE
imagesfile="images.txt"
containerurl=""   #Storage account container for data storage
sastoken=""   #Required to access the container
```

4. Using the root user, install Azure CLI on the VM and log into your Azure account.

```sh
sudo su
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login
```

5. Run Azure Image Scanner as root. (Optional: use "screen" command to run the script in a background session)

```sh
sudo su   #root access required to execute elevated commands
screen -L   #run screen session and log data to file
bash AIS.sh
```

## License

MIT
**It's free!**
