This project installs a k0s cluster on a NAT network bridged to lan in a Proxmox VE version 8.4.1 environment.
The cluster and pve networking are declared in files of folder ./k0s-lab . 

Your task:

1. Use IaC methods to  install network appliance OPNsense on a pve VM having 2CPU/2GB (vCPU/Memory).
2. Use IaC methods configure that appliance to provide DNS, DHCP, firewall and such as apropos to provide 2-way comms between the k0s cluster and the LAN.
3. Create the necessary files in ./opnsense-lab folder.
4. Do not modify files of ./k0s-lab 


